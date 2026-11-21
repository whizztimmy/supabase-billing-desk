-- 0003: the invoice engine.
--
-- quote_invoice() turns "this plan, these projects, this usage" into the lines
-- of a Supabase invoice, each with a sentence a customer could read. It is the
-- single place the billing rules live. Three things use it:
--
--   1. the public invoice explainer, which calls it with whatever a visitor
--      types in;
--   2. expected_invoice(), which rebuilds an issued invoice from the usage
--      records, so explain_invoice() can put the two side by side. A line that
--      differs is a billing bug reproduced, with the numbers attached;
--   3. the tests in tests/, which pin the rules to worked examples from
--      Supabase's documentation.

begin;

create function quote_invoice(
  p_plan      text,                    -- the plan the usage happened on
  p_spend_cap boolean,
  p_projects  jsonb,                   -- [{"name","size","hours","disk_gb","addons":{"ipv4":744}}]
  p_usage     jsonb   default '{}',    -- {"egress": 300, "mau": 120000}
  p_tax_rate  numeric default 0,
  p_fee_plan  text    default null,    -- the plan for the cycle that is starting, when it differs
  p_credits   numeric default 0        -- credit balance available before this invoice
)
returns table (
  line_no integer, kind text, project text, name text,
  quantity numeric, unit text, included numeric, billable numeric,
  unit_price numeric, amount numeric(12,2), explanation text
)
language sql stable security invoker set search_path = public, pg_catalog as $$
  with up as (select * from plans where id = p_plan),
  fp as (select * from plans where id = coalesce(p_fee_plan, p_plan)),
  -- The spend cap only exists on Pro, whatever the caller passes.
  ctx as (
    select up.id <> 'free' as paid,
           coalesce(p_spend_cap, false) and up.spend_cap_available as cap_on,
           up.name as plan_name, up.compute_credits
    from up
  ),
  proj as (
    select ord::integer as n,
           coalesce(nullif(x->>'name', ''), 'Project ' || ord) as name,
           lower(coalesce(x->>'size', 'micro')) as size,
           coalesce((x->>'hours')::numeric, 744) as hours,
           (x->>'disk_gb')::numeric as disk_gb,
           coalesce(x->'addons', '{}'::jsonb) as addons
    from jsonb_array_elements(coalesce(p_projects, '[]'::jsonb)) with ordinality as t(x, ord)
  ),
  plan_line as (
    select 100 as sort, 'plan'::text as kind, null::text as project, fp.name,
           1::numeric as quantity, 'month'::text as unit, null::numeric as included, null::numeric as billable,
           fp.monthly_fee::numeric as unit_price, fp.monthly_fee::numeric as amount,
           case when fp.id = 'free' then 'The Free Plan has no monthly fee.'
                else format('The fixed fee for the %s, charged in advance for the billing cycle that is starting.', fp.name)
           end as explanation
    from fp
  ),
  compute_lines (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 200 + p.n, 'compute', p.name, 'Compute Hours ' || bs.name,
           p.hours, 'hours', null::numeric, p.hours,
           bs.hourly_price::numeric,
           case when ctx.paid then round(p.hours * bs.hourly_price, 2) else 0 end,
           case when not ctx.paid then 'Compute is not charged on the Free Plan.'
                else format('%s ran on %s compute for %s hours at $%s an hour. Every project is its own server, billed for each hour it runs, however little it is used.',
                            p.name, bs.name, qty(p.hours), qty(bs.hourly_price))
                     || case when p.size = 'nano' then ' A Nano project is billed at the Micro price on a paid plan.' else '' end
           end
    from proj p
    cross join ctx
    join compute_sizes bs on bs.id = case when ctx.paid and p.size = 'nano' then 'micro' else p.size end
  ),
  addon_lines (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 300 + p.n * 10 + a.sort, 'addon', p.name, a.line_name,
           e.value::numeric, 'hours', null::numeric, e.value::numeric,
           a.hourly_price::numeric,
           case when ctx.paid then round(e.value::numeric * a.hourly_price, 2) else 0 end,
           format('%s had this add-on switched on for %s hours at $%s an hour. Add-ons are things you opt into, so they are billed whether or not the spend cap is on.',
                  p.name, qty(e.value::numeric), qty(a.hourly_price))
    from proj p
    cross join ctx
    cross join lateral jsonb_each_text(p.addons) e
    join addons a on a.id = e.key
  ),
  usage_in as (
    select m.*, null::text as project, (p_usage->>m.id)::numeric as used, 0 as n
    from usage_metrics m
    where m.scope = 'org' and p_usage ? m.id
    union all
    select m.*, p.name, p.disk_gb, p.n
    from usage_metrics m
    join proj p on m.scope = 'project' and m.id = 'disk_size' and p.disk_gb is not null
  ),
  usage_calc as (
    select u.*, ctx.paid, ctx.cap_on,
           case when ctx.paid then u.paid_quota else u.free_quota end as quota,
           greatest(u.used - coalesce(case when ctx.paid then u.paid_quota else u.free_quota end, 0), 0) as over_quota,
           '$' || qty(u.overage_price) || ' per ' ||
             case when u.price_per = 1 then case when u.unit = 'GB' then 'GB' else rtrim(u.unit, 's') end
                  else qty(u.price_per) || ' ' || u.unit end as price_text
    from usage_in u cross join ctx
  ),
  usage_lines (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 400 + c.sort * 20 + c.n, 'usage', c.project, c.line_name,
           c.used, c.unit, c.quota,
           case when c.paid and not (c.cap_on and c.covered_by_spend_cap) then c.over_quota else 0 end,
           c.overage_price / c.price_per,
           case when c.paid and not (c.cap_on and c.covered_by_spend_cap)
                then round(c.over_quota * c.overage_price / c.price_per, 2) else 0 end,
           case
             when c.quota is null then 'Not available on the Free Plan.'
             when c.over_quota = 0 then
               format('%s %s used, within the %s included with the plan. Nothing is charged.', qty(c.used), c.unit, qty(c.quota))
             when not c.paid then
               format('%s %s used against the %s included. The Free Plan is never billed for going over; staying over a quota leads to usage restrictions instead.',
                      qty(c.used), c.unit, qty(c.quota))
             when c.cap_on and c.covered_by_spend_cap then
               format('%s %s used, %s over the %s included. The spend cap is on, so the extra usage was not billed. Staying over a quota with the cap on leads to usage restrictions.',
                      qty(c.used), c.unit, qty(c.over_quota), qty(c.quota))
             else
               format('%s %s used, %s over the %s included, at %s.', qty(c.used), c.unit, qty(c.over_quota), qty(c.quota), c.price_text)
           end
    from usage_calc c
  ),
  -- Compute credits offset compute and nothing else, and never exceed it.
  compute_credit_line (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 800, 'compute_credits', null::text, 'Compute Credits',
           null::numeric, null::text, null::numeric, null::numeric, null::numeric,
           -least(ctx.compute_credits, t.compute_total),
           format('The %s includes %s of compute credits each month. They offset compute only, which covers one project on Micro.',
                  ctx.plan_name, usd(ctx.compute_credits))
    from ctx
    cross join (select coalesce(sum(amount), 0) as compute_total from compute_lines) t
    where ctx.compute_credits > 0 and t.compute_total > 0
  ),
  before_tax as (
    select * from plan_line
    union all select * from compute_lines
    union all select * from addon_lines
    union all select * from usage_lines
    union all select * from compute_credit_line
  ),
  tax_line (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 900, 'tax', null::text, 'Tax',
           null::numeric, null::text, null::numeric, null::numeric, p_tax_rate,
           round(s.subtotal * p_tax_rate, 2),
           format('Tax at %s%% of the amount above, based on the billing address. A valid tax ID on the organization changes how tax is applied.',
                  qty(p_tax_rate * 100))
    from (select coalesce(sum(amount), 0) as subtotal from before_tax) s
    where coalesce(p_tax_rate, 0) > 0 and s.subtotal > 0
  ),
  after_tax as (
    select * from before_tax union all select * from tax_line
  ),
  -- Credit balance is used before the card is charged.
  credits_line (sort, kind, project, name, quantity, unit, included, billable, unit_price, amount, explanation) as (
    select 950, 'credits', null::text, 'Credits applied',
           null::numeric, null::text, null::numeric, null::numeric, null::numeric,
           -least(p_credits, s.total),
           format('The organization had %s of credits. Credits are used before the card is charged.', usd(p_credits))
    from (select coalesce(sum(amount), 0) as total from after_tax) s
    where coalesce(p_credits, 0) > 0 and s.total > 0
  ),
  all_lines as (
    select * from after_tax union all select * from credits_line
  )
  select row_number() over (order by sort)::integer, kind, project, name,
         quantity, unit, included, billable, unit_price, amount::numeric(12,2), explanation
  from all_lines
  order by sort;
$$;

comment on function quote_invoice(text, boolean, jsonb, jsonb, numeric, text, numeric) is
  'The lines of a Supabase invoice for a plan, a set of projects and a month of usage, each with a plain-language explanation.';

-- The usage records of one organization for one period, in the shape
-- quote_invoice() takes.
create function invoice_inputs(p_org text, p_period date)
returns table (projects jsonb, usage jsonb)
language sql stable security invoker set search_path = public, pg_catalog as $$
  select
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', p.name,
               'size', cu.compute_size,
               'hours', cu.hours,
               'disk_gb', (select u.quantity from usage u
                           where u.project_id = p.id and u.period_start = p_period and u.metric = 'disk_size'),
               'addons', coalesce((select jsonb_object_agg(a.addon, a.hours) from addon_usage a
                                   where a.project_id = p.id and a.period_start = p_period), '{}'::jsonb)
             ) order by p.id)
      from projects p
      join compute_usage cu on cu.project_id = p.id and cu.period_start = p_period
      where p.org_id = p_org
    ), '[]'::jsonb),
    coalesce((
      select jsonb_object_agg(u.metric, u.quantity)
      from usage u
      where u.org_id = p_org and u.project_id is null and u.period_start = p_period
    ), '{}'::jsonb);
$$;

-- What an issued invoice should contain, rebuilt from the usage records.
create function expected_invoice(p_invoice bigint)
returns table (
  line_no integer, kind text, project text, name text,
  quantity numeric, unit text, included numeric, billable numeric,
  unit_price numeric, amount numeric(12,2), explanation text
)
language sql stable security invoker set search_path = public, pg_catalog as $$
  select q.*
  from invoices i
  join orgs o on o.id = i.org_id
  cross join lateral invoice_inputs(i.org_id, i.usage_period_start) inp
  cross join lateral quote_invoice(
    i.usage_plan, i.spend_cap, inp.projects, inp.usage,
    -- A tax ID on the organization means reverse charge: no tax on the invoice.
    case when o.tax_id is null then o.tax_rate else 0 end,
    i.fee_plan,
    -- Credits available just before the invoice was issued.
    (select coalesce(sum(case l.entry_type when 'increment' then l.amount else -l.amount end), 0)
     from credit_ledger l where l.org_id = i.org_id and l.at < i.issued_at)
  ) q
  where i.id = p_invoice;
$$;

-- The issued invoice next to the expected one, line by line.
create function explain_invoice(p_invoice bigint)
returns table (
  line_no integer, kind text, project text, name text,
  quantity numeric, unit text, included numeric, billable numeric, unit_price numeric,
  amount numeric(12,2), expected_amount numeric(12,2), matches boolean, explanation text
)
language sql stable security invoker set search_path = public, pg_catalog as $$
  select coalesce(il.line_no, 1000 + e.line_no),
         coalesce(il.kind, e.kind), coalesce(il.project, e.project), coalesce(il.name, e.name),
         coalesce(il.quantity, e.quantity), coalesce(il.unit, e.unit),
         coalesce(il.included, e.included), coalesce(il.billable, e.billable),
         coalesce(il.unit_price, e.unit_price),
         il.amount, e.amount,
         il.amount is not distinct from e.amount,
         case
           when il.invoice_id is null then
             format('Missing from the invoice. The usage records call for this line at %s. ', usd(e.amount)) || e.explanation
           when e.kind is null then
             'On the invoice, but nothing in the usage records accounts for it.'
           when il.amount <> e.amount then
             format('The invoice says %s and the usage records give %s. ', usd(il.amount), usd(e.amount)) || e.explanation
           else e.explanation
         end
  from (select * from invoice_lines where invoice_id = p_invoice) il
  full join expected_invoice(p_invoice) e
    on e.kind = il.kind and e.name = il.name and coalesce(e.project, '') = coalesce(il.project, '')
  order by 1;
$$;

comment on function explain_invoice(bigint) is
  'An issued invoice line by line, each with its explanation and the amount the usage records call for.';

create function invoice_check(p_invoice bigint)
returns table (invoice_id bigint, issued_total numeric, expected_total numeric, difference numeric, matches boolean)
language sql stable security invoker set search_path = public, pg_catalog as $$
  select p_invoice,
         coalesce(sum(amount), 0),
         coalesce(sum(expected_amount), 0),
         coalesce(sum(amount), 0) - coalesce(sum(expected_amount), 0),
         coalesce(bool_and(matches), true)
  from explain_invoice(p_invoice);
$$;

-- One row per invoice with what a support person scans for first.
create view invoice_overview
with (security_invoker = true) as
select i.id, i.org_id, o.name as org_name, i.number, i.status,
       invoice_status_label(i.status) as status_label,
       i.usage_period_start, i.usage_period_end, i.usage_plan, i.fee_plan, i.spend_cap,
       i.issued_at, i.due_at, i.paid_at, i.total,
       case when i.status = 'open' then greatest(extract(day from demo_now() - i.due_at)::integer, 0) end as days_overdue,
       coalesce(pa.failed, 0) as failed_attempts,
       coalesce(pa.succeeded, 0) as succeeded_attempts,
       pa.last_decline_code,
       exists (select 1 from disputes d where d.invoice_id = i.id and d.status in ('needs_response', 'under_review')) as open_dispute
from invoices i
join orgs o on o.id = i.org_id
left join lateral (
  select count(*) filter (where a.status = 'failed')    as failed,
         count(*) filter (where a.status = 'succeeded') as succeeded,
         (array_agg(a.decline_code order by a.attempted_at desc) filter (where a.status = 'failed'))[1] as last_decline_code
  from payment_attempts a
  where a.invoice_id = i.id
) pa on true;

commit;
