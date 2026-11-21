-- 0004: the playbooks.
--
-- A billing ticket rarely says what is wrong. "My payment failed" can be an
-- expired card, a bank blocking a foreign charge, or an empty account, and
-- each has a different fix. A playbook is one small query that checks the
-- account for one cause. If the cause is there it returns a finding: what
-- happened, the evidence, the next step, and a first reply.
--
-- Each playbook is its own function on purpose. The console shows the SQL of
-- the playbook that fired (see playbook_source), so the reasoning behind a
-- diagnosis is the code that produced it, not a description of it.
--
-- The cause always comes from the account: the invoice, the card, the payment
-- attempts, the projects. Thirteen of the sixteen playbooks use nothing else.
-- Three also need to know what the customer is asking for, because the same
-- account can prompt different questions: pre_sales and refund_policy use the
-- category chosen on the support form, and tax_id_missing and pre_sales check
-- the wording for the subject. tests/03_playbooks.sql pins this list, so a
-- playbook cannot start reading the text without the test saying so.

begin;

-- A rough topic from the customer's words, for the inbox and for patterns.
create function ticket_topic(subject text, body text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when s ~ '(dispute|chargeback)'                          then 'dispute'
    when s ~ '(declin|fail)'                                 then 'failed payment'
    when s ~ '(twice|double|duplicate)'                      then 'duplicate charge'
    when s ~ '(refund|money back)'                           then 'refund'
    when s ~ '\m(vat|tax|gst)\M'                             then 'tax'
    when s ~ '(annual|yearly|bank transfer|purchase order|upfront)' then 'pre-sales'
    when s ~ '\mpause'                                       then 'paused project'
    when s ~ '(downgrad|cancel)'                             then 'plan change'
    when s ~ '(quota|limit|restrict|402|exceed)'             then 'usage limits'
    when s ~ '(invoice|charge|bill)'                         then 'invoice amount'
    else 'other'
  end
  from (select lower(subject || ' ' || body) as s) x;
$$;

-- Everything a playbook needs about a ticket, on one row: the customer, the
-- invoice in question (the one the ticket names, else the latest), how its
-- payment went, the card on file and the state of the projects.
create view ticket_context
with (security_invoker = true) as
select t.id as ticket_id, t.subject, t.body, t.category, t.severity, t.status as ticket_status, t.created_at,
       ticket_topic(t.subject, t.body) as topic,
       t.requester_name, split_part(t.requester_name, ' ', 1) as first_name,
       o.id as org_id, o.name as org_name, o.plan, o.spend_cap, o.country, o.tax_id, o.tax_rate,
       o.restriction_status, cb.balance as credit_balance,
       i.id as invoice_id, i.number as invoice_number, i.status as invoice_status, i.total as invoice_total,
       i.issued_at, i.due_at, i.usage_period_start, i.usage_period_end,
       i.usage_plan, i.fee_plan, i.spend_cap as invoice_spend_cap,
       case when i.status = 'open' then greatest(extract(day from demo_now() - i.due_at)::integer, 0) end as days_overdue,
       coalesce(pa.failed_attempts, 0) as failed_attempts,
       coalesce(pa.succeeded_attempts, 0) as succeeded_attempts,
       pa.last_decline_code,
       pm.brand as card_brand, pm.last4 as card_last4, pm.country as card_country,
       make_date(pm.exp_year, pm.exp_month, 1) as card_expires,
       (make_date(pm.exp_year, pm.exp_month, 1) + interval '1 month') <= demo_now() as card_expired,
       pr.project_count, pr.paused_projects, pr.pause_reason
from tickets t
join orgs o on o.id = t.org_id
join credit_balances cb on cb.org_id = o.id
left join invoices i on i.id = coalesce(
  t.invoice_id,
  (select l.id from invoices l where l.org_id = o.id order by l.issued_at desc limit 1))
left join lateral (
  select count(*) filter (where a.status = 'failed')    as failed_attempts,
         count(*) filter (where a.status = 'succeeded') as succeeded_attempts,
         (array_agg(a.decline_code order by a.attempted_at desc) filter (where a.status = 'failed'))[1] as last_decline_code
  from payment_attempts a where a.invoice_id = i.id
) pa on true
left join payment_methods pm on pm.org_id = o.id and pm.is_active
left join lateral (
  select count(*) as project_count,
         count(*) filter (where p.status = 'paused') as paused_projects,
         max(p.pause_reason) as pause_reason
  from projects p where p.org_id = o.id
) pr on true;

create type finding as (
  playbook    text,
  rank        integer,    -- lower is more specific, and is shown first
  cause       text,
  evidence    jsonb,      -- [{"label": ..., "value": ...}]
  next_step   text,
  escalate_to text,       -- null when support can settle it
  reply       text
);

create function ev(label text, value text) returns jsonb
language sql immutable set search_path = pg_catalog as $$
  select jsonb_build_object('label', label, 'value', coalesce(value, 'none'));
$$;

create table playbooks (
  id           text primary key,
  title        text    not null,
  applies_when text    not null,
  doc_url      text,
  sort         integer not null
);

insert into playbooks values
  ('duplicate_charge',   'Charged twice for one invoice',        'An invoice has more than one successful charge.', 'https://supabase.com/docs/guides/platform/your-monthly-invoice', 1),
  ('invoice_mismatch',   'Invoice does not match usage',         'Rebuilding the invoice from the usage records gives a different total.', 'https://supabase.com/docs/guides/platform/your-monthly-invoice', 2),
  ('dispute_open',       'Bank dispute open on the invoice',     'The cardholder''s bank has an open dispute for the invoice.', 'https://docs.stripe.com/disputes', 3),
  ('overdue_paused',     'Projects paused for an unpaid invoice','An invoice is outstanding and projects were paused because of it.', 'https://supabase.com/docs/guides/platform/billing-faq', 4),
  ('free_project_paused','Free project paused for inactivity',   'A Free Plan project was paused for low activity. Nothing is owed.', 'https://supabase.com/docs/guides/platform/free-project-pausing', 5),
  ('expired_card',       'Payment failed: card expired',         'The last charge failed and the card on file has expired.', 'https://supabase.com/docs/guides/platform/your-monthly-invoice', 6),
  ('bank_block',         'Payment failed: bank blocked the charge', 'The bank declined without a reason, usually a block on a US dollar charge from Singapore.', 'https://supabase.com/docs/guides/platform/billing-faq', 7),
  ('payment_declined',   'Payment failed: other decline',        'The last charge failed with another decline code, such as insufficient funds or 3D Secure.', 'https://docs.stripe.com/declines/codes', 8),
  ('quota_restriction',  'Over quota with the spend cap on',     'The organization is restricted or in a grace period after exceeding a quota.', 'https://supabase.com/docs/guides/platform/cost-control', 9),
  ('downgrade_charge',   'Charged after a downgrade',            'The invoice was issued by a plan change, and bills usage up to that day.', 'https://supabase.com/docs/guides/platform/manage-your-subscription', 10),
  ('tax_id_missing',     'Tax charged, no tax ID on file',       'The invoice carries tax and the organization has no tax ID.', 'https://supabase.com/docs/guides/platform/billing-faq', 11),
  ('extra_projects',     'More than one project',                'The invoice is above the plan fee because of compute for additional projects.', 'https://supabase.com/docs/guides/platform/manage-your-usage/compute', 12),
  ('usage_overage',      'Usage over quota, spend cap off',      'The invoice bills usage beyond the plan''s quota.', 'https://supabase.com/docs/guides/platform/cost-control', 13),
  ('addons_with_cap',    'Add-ons billed despite the spend cap', 'The spend cap is on and the invoice bills add-ons, which the cap does not cover.', 'https://supabase.com/docs/guides/platform/cost-control', 14),
  ('pre_sales',          'Pre-sales: how to pay',                'A sales enquiry about annual billing, bank transfer or paying upfront.', 'https://supabase.com/docs/guides/platform/credits', 15),
  ('refund_policy',      'Refund request on a correct invoice',  'A refund is requested and the invoice is correct and was paid once.', 'https://supabase.com/docs/guides/platform/manage-your-subscription', 16);

-- ---------------------------------------------------------------------------
-- Billing errors. These go to Billing Engineering.
-- ---------------------------------------------------------------------------

create function pb_duplicate_charge(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'duplicate_charge', 10,
    format('Invoice %s was collected %s times: %s successful charges of %s for one invoice.',
           c.invoice_number, c.succeeded_attempts, c.succeeded_attempts, usd(c.invoice_total)),
    jsonb_build_array(
      ev('Invoice', c.invoice_number || ', ' || usd(c.invoice_total)),
      ev('Successful charges', c.succeeded_attempts::text),
      ev('Charged on', d.dates),
      ev('Collected in total', usd(c.invoice_total * c.succeeded_attempts))),
    'Escalate to Billing Engineering to reverse the extra charge. This is a billing error, not a refund request, so the no-refund policy does not apply.',
    'Billing Engineering',
    format(E'Hi %s,\n\nYou are right, and thank you for flagging it. Invoice %s for %s was charged to your card %s times, on %s. That is our error.\n\nI have passed it to our billing engineers to reverse the extra %s. You do not need to do anything, and I will confirm here once it is done. Please hold off raising it with your bank in the meantime: a dispute freezes the charge and would slow the reversal down.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(c.invoice_total), c.succeeded_attempts, d.dates,
           usd(c.invoice_total * (c.succeeded_attempts - 1)))
  from ticket_context c
  cross join lateral (
    select string_agg(to_char(a.attempted_at at time zone 'UTC', 'FMDD Mon "at" HH24:MI'), ' and ' order by a.attempted_at) || ' UTC' as dates
    from payment_attempts a where a.invoice_id = c.invoice_id and a.status = 'succeeded'
  ) d
  where c.ticket_id = p_ticket and c.succeeded_attempts > 1;
$$;

create function pb_invoice_mismatch(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'invoice_mismatch', 12,
    format('Rebuilding invoice %s from the usage records gives %s, but the invoice says %s.',
           c.invoice_number, usd(k.expected_total), usd(k.issued_total)),
    jsonb_build_array(
      ev('Invoice total', usd(k.issued_total)),
      ev('Total from usage records', usd(k.expected_total)),
      ev('Difference', usd(k.difference)),
      ev('Lines that differ', l.lines)),
    'Escalate to Billing Engineering with the differing lines. Do not explain the invoice as correct, and do not promise an amount until the invoice has been reissued.',
    'Billing Engineering',
    format(E'Hi %s,\n\nThank you for asking, because this invoice is not right. I rebuilt invoice %s from your usage and it should come to %s, not %s. What went wrong: %s.\n\nI have sent this to our billing engineers with the numbers so the invoice can be corrected, and I will update you here once it has been. You do not need to do anything in the meantime.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(k.expected_total), usd(k.issued_total), l.plain)
  from ticket_context c
  cross join lateral invoice_check(c.invoice_id) k
  cross join lateral (
    select string_agg(e.name || ' (invoice ' || coalesce(usd(e.amount), 'missing')
                      || ', usage records ' || coalesce(usd(e.expected_amount), 'nothing') || ')', '; ' order by e.line_no) as lines,
           -- The same differences in words a customer can follow.
           string_agg(case
                        when e.amount is null then format('the %s line of %s is missing', e.name, usd(e.expected_amount))
                        when e.expected_amount is null then format('the %s line of %s should not be there', e.name, usd(e.amount))
                        else format('the %s line shows %s and should be %s', e.name, usd(e.amount), usd(e.expected_amount))
                      end, '; ' order by e.line_no) as plain
    from explain_invoice(c.invoice_id) e where not e.matches
  ) l
  where c.ticket_id = p_ticket and c.invoice_id is not null and not k.matches;
$$;

create function pb_dispute_open(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'dispute_open', 14,
    format('The card''s bank opened a dispute (%s) for %s on invoice %s on %s. While it is open the bank holds the money, so a credit on top of it would pay the customer twice.',
           d.reason, usd(d.amount), c.invoice_number, to_char(d.opened_at, 'FMDD Mon YYYY')),
    jsonb_build_array(
      ev('Dispute status', replace(d.status, '_', ' ')),
      ev('Reason given to the bank', d.reason),
      ev('Amount', usd(d.amount)),
      ev('Evidence due by', to_char(d.evidence_due_by, 'FMDD Mon YYYY'))),
    format('Do not credit or refund. Ask whether the customer meant to dispute the charge, and hand the dispute to Billing Engineering before the evidence deadline on %s.',
           to_char(d.evidence_due_by, 'FMDD Mon')),
    'Billing Engineering',
    format(E'Hi %s,\n\nBefore I do anything on invoice %s, I should flag that your card''s bank opened a dispute for it on %s. While a dispute is open the bank holds the %s and decides the outcome, so I cannot credit the same charge at the same time.\n\nIf someone on your side raised it by mistake, the quickest fix is to ask the bank to withdraw it. Once it is closed I can go through the invoice with you properly. If the charge was not recognised, tell me what looked wrong and I will walk through the invoice line by line.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, to_char(d.opened_at, 'FMDD Mon'), usd(d.amount))
  from ticket_context c
  join disputes d on d.invoice_id = c.invoice_id and d.status in ('needs_response', 'under_review')
  where c.ticket_id = p_ticket;
$$;

-- ---------------------------------------------------------------------------
-- Paused projects. Two causes that look the same from the customer's side.
-- ---------------------------------------------------------------------------

create function pb_overdue_paused(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'overdue_paused', 20,
    format('Invoice %s for %s has been outstanding for %s days. An unpaid invoice pauses every project and moves the organization to the Free Plan, which is why %s of its projects %s paused.',
           c.invoice_number, usd(c.invoice_total), c.days_overdue, c.paused_projects,
           case when c.paused_projects = 1 then 'is' else 'are' end),
    jsonb_build_array(
      ev('Outstanding invoice', c.invoice_number || ', ' || usd(c.invoice_total) || ', due ' || to_char(c.due_at, 'FMDD Mon')),
      ev('Failed charges', c.failed_attempts || ', last decline: ' || coalesce(c.last_decline_code, 'none')),
      ev('Projects paused', c.paused_projects || ' of ' || c.project_count),
      ev('Current plan', c.plan)),
    'Support cannot restore these projects; paying every outstanding invoice does. Say so in the first lines, give the reason the charge failed, and say that a credit top-up cannot settle an invoice that is already outstanding.',
    null,
    format(E'Hi %s,\n\nYour projects are paused because invoice %s for %s has not been paid. The charge was tried %s times and the last attempt failed: %s\n\nTo bring the projects back:\n1. %s\n2. Open Organization > Billing > Invoices and click Pay now on invoice %s.\n\nOnce every outstanding invoice is paid you can restore the projects from the dashboard and move back to your previous plan. Two things worth knowing: I cannot restore them from my side while the invoice is open, and a credit top-up cannot be used to pay an invoice that is already outstanding.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(c.invoice_total), c.failed_attempts,
           lower(left(dc.meaning, 1)) || substr(dc.meaning, 2), dc.customer_action, c.invoice_number)
  from ticket_context c
  left join decline_codes dc on dc.code = c.last_decline_code
  where c.ticket_id = p_ticket
    and c.invoice_status = 'open' and c.paused_projects > 0 and c.pause_reason = 'overdue_invoice';
$$;

create function pb_free_project_paused(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'free_project_paused', 25,
    'Not a billing problem. The organization is on the Free Plan, where a project is paused after a week of too little database activity. Nothing is owed and nothing failed.',
    jsonb_build_array(
      ev('Plan', 'Free'),
      ev('Projects paused', c.paused_projects || ' of ' || c.project_count || ', for inactivity'),
      ev('Outstanding invoices', 'none')),
    'Reassure first: no charge, no debt. Then explain how to restore the project and what prevents the pause.',
    null,
    format(E'Hi %s,\n\nGood news first: you do not owe anything, and no payment has failed. Your organization is on the Free Plan, where a project is paused after about a week without enough database activity. That is what happened here.\n\nYou can restore it from the dashboard with Restore project, and it can be restored for up to a year after being paused. To stop it happening again, either keep the database in regular use or upgrade to Pro, where projects are never paused. On Pro the first project costs %s a month in total.\n\nBest,\nTimothy',
           c.first_name, usd((select monthly_fee from plans where id = 'pro')))
  from ticket_context c
  where c.ticket_id = p_ticket and c.plan = 'free' and c.pause_reason = 'inactivity';
$$;

-- ---------------------------------------------------------------------------
-- Failed payments. One symptom, three different fixes.
-- ---------------------------------------------------------------------------

create function pb_expired_card(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'expired_card', 30,
    format('The %s card ending %s expired at the end of %s, so the charge for invoice %s was declined.',
           c.card_brand, c.card_last4, to_char(c.card_expires, 'FMMonth YYYY'), c.invoice_number),
    jsonb_build_array(
      ev('Invoice', c.invoice_number || ', ' || usd(c.invoice_total) || ', outstanding'),
      ev('Card on file', c.card_brand || ' ending ' || c.card_last4 || ', expired ' || to_char(c.card_expires, 'MM/YYYY')),
      ev('Failed charges', c.failed_attempts || ', decline code ' || c.last_decline_code)),
    'Ask for a new card, then payment from the invoices page. Mention that a new card has to be added before the old one can be removed.',
    null,
    format(E'Hi %s,\n\nThe payment for invoice %s (%s) failed because the %s card ending %s expired at the end of %s.\n\nTo fix it:\n1. Add a new card under Organization > Billing. A new card has to be added before the old one can be removed.\n2. Open the Invoices tab and click Pay now on invoice %s.\n\nYour projects are still running. If the invoice stays unpaid, they are paused and the organization moves to the Free Plan until it is settled, so it is worth doing today.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(c.invoice_total), c.card_brand, c.card_last4,
           to_char(c.card_expires, 'FMMonth YYYY'), c.invoice_number)
  from ticket_context c
  where c.ticket_id = p_ticket and c.invoice_status = 'open' and c.failed_attempts > 0
    and (c.last_decline_code = 'expired_card' or c.card_expired)
    and coalesce(c.pause_reason, '') <> 'overdue_invoice';
$$;

create function pb_bank_block(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'bank_block', 30,
    format('The bank declined the charge for invoice %s %s times without giving a reason (%s). The card was issued in %s. Supabase charges in US dollars from its payments entity in Singapore, and many banks block a foreign-currency charge from abroad by default.',
           c.invoice_number, c.failed_attempts, c.last_decline_code, country_name(c.card_country)),
    jsonb_build_array(
      ev('Invoice', c.invoice_number || ', ' || usd(c.invoice_total) || ', outstanding'),
      ev('Card on file', c.card_brand || ' ending ' || c.card_last4 || ', issued in ' || country_name(c.card_country) || ', valid to ' || to_char(c.card_expires, 'MM/YYYY')),
      ev('Failed charges', c.failed_attempts || ', decline code ' || c.last_decline_code),
      ev('Charge details the bank sees', 'USD, merchant in Singapore')),
    'The card is fine; the bank is refusing this kind of charge. Tell the customer exactly what to ask the bank for, then to pay from the invoices page.',
    null,
    format(E'Hi %s,\n\nYour card itself looks fine: it is valid and nothing on our side is blocking it. The charge for invoice %s (%s) was declined by your bank, %s times, without a reason given.\n\nThe usual cause is that we charge in US dollars from Singapore, and many banks block international or foreign-currency payments unless you ask them not to. Please ask your bank to allow a USD payment to Supabase, a merchant in Singapore. Some banks have a switch for international payments in their app.\n\nOnce they confirm, open Organization > Billing > Invoices and click Pay now on invoice %s. If the bank says it did not decline anything, tell me and I will look further.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(c.invoice_total), c.failed_attempts, c.invoice_number)
  from ticket_context c
  where c.ticket_id = p_ticket and c.invoice_status = 'open' and c.failed_attempts > 0
    and c.last_decline_code in ('do_not_honor', 'generic_decline') and not c.card_expired
    and coalesce(c.pause_reason, '') <> 'overdue_invoice';
$$;

create function pb_payment_declined(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'payment_declined', 30,
    format('The charge for invoice %s failed with decline code %s. %s',
           c.invoice_number, c.last_decline_code, dc.meaning),
    jsonb_build_array(
      ev('Invoice', c.invoice_number || ', ' || usd(c.invoice_total) || ', outstanding'),
      ev('Card on file', c.card_brand || ' ending ' || c.card_last4 || ', valid to ' || to_char(c.card_expires, 'MM/YYYY')),
      ev('Failed charges', c.failed_attempts || ', decline code ' || c.last_decline_code)),
    dc.customer_action || case when dc.share_detail then '' else ' Do not repeat the decline reason to the customer.' end,
    null,
    format(E'Hi %s,\n\nThe payment for invoice %s (%s) did not go through. %s\n\nWhat to do: %s Then open Organization > Billing > Invoices and click Pay now on invoice %s.\n\nYour projects are still running. An invoice that stays unpaid leads to paused projects, so it is worth settling soon.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(c.invoice_total),
           case when dc.share_detail then dc.meaning else 'Your card was declined.' end,
           case when dc.share_detail then dc.customer_action else 'Please add a different card.' end,
           c.invoice_number)
  from ticket_context c
  join decline_codes dc on dc.code = c.last_decline_code
  where c.ticket_id = p_ticket and c.invoice_status = 'open' and c.failed_attempts > 0
    and c.last_decline_code not in ('expired_card', 'do_not_honor', 'generic_decline') and not c.card_expired
    and coalesce(c.pause_reason, '') <> 'overdue_invoice';
$$;

-- ---------------------------------------------------------------------------
-- Usage limits and plan changes.
-- ---------------------------------------------------------------------------

create function pb_quota_restriction(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'quota_restriction', 35,
    format('The organization is over its %s quota on %s with the spend cap on. The cap stops overage being billed, so the extra usage is blocked instead, and Supabase has moved the organization to "%s".',
           initcap(c.plan), ov.items, replace(c.restriction_status, '_', ' ')),
    jsonb_build_array(
      ev('Restriction status', replace(c.restriction_status, '_', ' ')),
      ev('Spend cap', 'on'),
      ev('Over quota', ov.detail),
      ev('Cost of last cycle''s overage with the cap off', usd(ov.cost))),
    'Two ways out, and it is the customer''s choice: turn the spend cap off and pay for the overage, or reduce usage. Restrictions lift when quotas refill at the next cycle, or straight away once the cap is off.',
    null,
    format(E'Hi %s,\n\nThe warnings are about usage, not about a payment. Last cycle your organization went over what the Pro Plan includes: %s.\n\nYour spend cap is on. That protects you from extra charges, but it also means usage beyond the quota is blocked, and staying over it leads to restrictions on the organization.\n\nYou have two options:\n1. Turn the spend cap off under Organization > Billing > Cost control. The restriction lifts right away and usage over the quota is billed.\n2. Keep the cap on and bring usage back under the quota. The restriction lifts when the quota refills at the start of your next billing cycle.\n\nTo help you choose: at last cycle''s usage, option 1 would have added %s to the invoice.\n\nBest,\nTimothy',
           c.first_name, ov.detail, usd(ov.cost))
  from ticket_context c
  cross join lateral (
    select string_agg(e.name, ' and ' order by e.line_no) as items,
           string_agg(e.name || ': ' || qty(e.quantity) || ' used, ' || qty(e.included) || ' included', '; ' order by e.line_no) as detail,
           -- What the blocked usage would have cost with the cap off.
           sum(round((e.quantity - e.included) * e.unit_price, 2)) as cost
    from invoice_inputs(c.org_id, c.usage_period_start) inp
    cross join lateral quote_invoice(c.usage_plan, true, inp.projects, inp.usage) e
    where e.kind = 'usage' and e.quantity > e.included
  ) ov
  where c.ticket_id = p_ticket and c.restriction_status is not null and c.spend_cap and ov.items is not null;
$$;

create function pb_downgrade_charge(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'downgrade_charge', 40,
    format('The organization moved from %s to %s on %s. A plan change closes the billing cycle, so usage up to that day was billed then: %s. The unused part of the plan fee came back as %s of credits, which were used first, leaving %s for the card.',
           initcap(pc.from_plan), initcap(pc.to_plan), to_char(pc.changed_at, 'FMDD Mon'),
           usd(l.usage_total), usd(l.credits_used), usd(c.invoice_total)),
    jsonb_build_array(
      ev('Plan change', initcap(pc.from_plan) || ' to ' || initcap(pc.to_plan) || ' on ' || to_char(pc.changed_at, 'FMDD Mon YYYY')),
      ev('Usage billed in arrears', usd(l.usage_total)),
      ev('Credits for unused plan time', usd(l.credits_used) || ', applied to this invoice'),
      ev('Charged to card', usd(c.invoice_total))),
    'Nothing is wrong. Show both sides: the usage that was still owed, and the credit that came back and was already used against it.',
    null,
    format(E'Hi %s,\n\nThe charge is for usage from before the downgrade, not for a new month of Pro. Plan fees are paid in advance, but usage is billed afterwards, and changing plan closes the billing cycle. So when you moved to %s on %s, the usage up to that day was billed: %s.\n\nThe part of the Pro fee you had not used came back to you as %s of credits. Those were applied to this invoice first, which is why your card was charged %s and not the full amount.\n\nYou can see both lines on invoice %s under Organization > Billing > Invoices. There is nothing further to pay.\n\nBest,\nTimothy',
           c.first_name, initcap(pc.to_plan), to_char(pc.changed_at, 'FMDD Mon'), usd(l.usage_total),
           usd(l.credits_used), usd(c.invoice_total), c.invoice_number)
  from ticket_context c
  join plan_changes pc on pc.org_id = c.org_id and pc.reason = 'customer'
                      and pc.changed_at::date between c.usage_period_start and c.issued_at::date
  cross join lateral (
    select coalesce(sum(il.amount) filter (where il.kind <> 'credits'), 0) as usage_total,
           coalesce(-sum(il.amount) filter (where il.kind = 'credits'), 0) as credits_used
    from invoice_lines il where il.invoice_id = c.invoice_id
  ) l
  where c.ticket_id = p_ticket and c.fee_plan <> c.usage_plan;
$$;

create function pb_tax_id_missing(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'tax_id_missing', 45,
    format('Invoice %s includes %s of tax because the organization, billed in %s, has no tax ID on file. An issued invoice cannot be changed; a tax ID added now applies to invoices from the next one on.',
           c.invoice_number, usd(t.tax), country_name(c.country)),
    jsonb_build_array(
      ev('Tax on the invoice', usd(t.tax) || ' at ' || qty(c.tax_rate * 100) || '%'),
      ev('Tax ID on file', c.tax_id),
      ev('Billing country', country_name(c.country))),
    'Say clearly that the issued invoice cannot be edited, then how to get it right from the next invoice on.',
    null,
    format(E'Hi %s,\n\nI cannot add the VAT number to invoice %s, and I would rather say that plainly: once an invoice has been issued it cannot be changed, because our payment provider cannot regenerate it.\n\nWhat you can do is make every invoice from the next one correct. Add your tax ID under Organization > Billing > Billing details. For a VAT-registered business that applies the reverse charge, so the %s of tax on this invoice would not be added in future.\n\nIf your accounts team needs something for this month, tell me what they are asking for and I will see what I can provide.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, usd(t.tax))
  from ticket_context c
  cross join lateral (
    select coalesce(sum(il.amount), 0) as tax from invoice_lines il where il.invoice_id = c.invoice_id and il.kind = 'tax'
  ) t
  where c.ticket_id = p_ticket and c.tax_id is null and t.tax > 0 and c.topic = 'tax';
$$;

-- ---------------------------------------------------------------------------
-- "Why is my invoice more than the plan price?" Three different answers.
-- ---------------------------------------------------------------------------

create function pb_extra_projects(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'extra_projects', 50,
    format('Invoice %s is %s, not the %s plan fee, because the organization ran %s projects. Each project is its own server: together they cost %s in compute, and the plan''s %s of compute credits covers only the first.',
           c.invoice_number, usd(c.invoice_total), usd(l.plan_fee), l.projects, usd(l.compute), usd(-l.compute_credits)),
    jsonb_build_array(
      ev('Plan fee', usd(l.plan_fee)),
      ev('Compute', usd(l.compute) || ' across ' || l.projects || ' projects'),
      ev('Compute credits', usd(l.compute_credits)),
      ev('Invoice total', usd(c.invoice_total))),
    'Nothing is wrong. Walk through the compute lines, then say what would lower the bill: pausing or deleting projects that are not needed.',
    null,
    format(E'Hi %s,\n\nThe invoice is correct, and the difference from %s is compute. On Supabase every project is its own dedicated server, billed for each hour it runs, even when it is idle.\n\nLast cycle your organization ran %s projects:\n- Pro Plan: %s\n- Compute for %s projects: %s\n- Compute credits included with the plan: %s\n\nThe credits cover one small project, so each additional one adds about $10 a month or more, depending on its size. If any of those projects are no longer needed, pausing or deleting them stops their compute charge from that hour on.\n\nBest,\nTimothy',
           c.first_name, usd(l.plan_fee), l.projects, usd(l.plan_fee), l.projects, usd(l.compute), usd(l.compute_credits))
  from ticket_context c
  cross join lateral (
    select count(*) filter (where il.kind = 'compute') as projects,
           coalesce(sum(il.amount) filter (where il.kind = 'compute'), 0) as compute,
           coalesce(sum(il.amount) filter (where il.kind = 'compute_credits'), 0) as compute_credits,
           coalesce(sum(il.amount) filter (where il.kind = 'plan'), 0) as plan_fee
    from invoice_lines il where il.invoice_id = c.invoice_id
  ) l
  where c.ticket_id = p_ticket and c.usage_plan <> 'free' and c.fee_plan = c.usage_plan
    and l.projects > 1 and l.compute + l.compute_credits > 0
    -- Not while projects are paused for non-payment: that customer needs
    -- their projects back, not a breakdown of the bill.
    and coalesce(c.pause_reason, '') <> 'overdue_invoice';
$$;

create function pb_usage_overage(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'usage_overage', 50,
    format('Invoice %s bills %s of usage beyond the plan''s quota: %s. The spend cap is off, so usage over the quota is charged instead of blocked.',
           c.invoice_number, usd(l.overage), l.detail),
    jsonb_build_array(
      ev('Spend cap', 'off'),
      ev('Overage on this invoice', usd(l.overage)),
      ev('Lines', l.detail),
      ev('Invoice total', usd(c.invoice_total))),
    'Acknowledge the surprise, then the numbers line by line. Finish with how to prevent it: the spend cap, the usage page, and the upcoming-invoice estimate. Do not offer a credit for a correct invoice.',
    null,
    format(E'Hi %s,\n\nI understand why %s was a surprise on a %s plan, so here is exactly where it comes from. The plan fee covers a set amount of usage each month, and usage beyond that is billed on the following invoice. Last cycle the organization went over on:\n\n%s\n\nThat is %s of the total. The invoice is correct, and I am sorry it was not expected.\n\nTo keep it from happening again:\n1. Turn on the spend cap under Organization > Billing > Cost control. Usage over the quota is then blocked instead of billed.\n2. Check Organization > Usage during the month. It shows how close each item is to its quota, and the billing page shows an estimate of the upcoming invoice.\n\nIf you tell me what the project does, I can point at what is driving the egress or the invocations.\n\nBest,\nTimothy',
           c.first_name, usd(c.invoice_total), usd(l.plan_fee), l.bullets, usd(l.overage))
  from ticket_context c
  cross join lateral (
    select coalesce(sum(il.amount) filter (where il.kind = 'usage'), 0) as overage,
           coalesce(sum(il.amount) filter (where il.kind = 'plan'), 0) as plan_fee,
           string_agg(il.name || ' ' || usd(il.amount), ', ' order by il.amount desc) filter (where il.kind = 'usage' and il.amount > 0) as detail,
           string_agg('- ' || il.name || ': ' || qty(il.quantity) || ' used, ' || qty(il.included) || ' included, ' || usd(il.amount),
                      E'\n' order by il.amount desc) filter (where il.kind = 'usage' and il.amount > 0) as bullets
    from invoice_lines il where il.invoice_id = c.invoice_id
  ) l
  where c.ticket_id = p_ticket and l.overage > 0 and c.fee_plan = c.usage_plan;
$$;

create function pb_addons_with_cap(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'addons_with_cap', 52,
    format('The spend cap is on, and invoice %s still bills %s of add-ons: %s. The cap only blocks usage over the plan''s quotas. Add-ons are switched on by the customer and are never covered by it.',
           c.invoice_number, usd(l.addons), l.detail),
    jsonb_build_array(
      ev('Spend cap', 'on'),
      ev('Add-ons on this invoice', usd(l.addons)),
      ev('Lines', l.detail),
      ev('Usage overage billed', usd(l.overage))),
    'Explain what the cap covers and what it does not. Name each add-on and where to turn it off if it is not needed.',
    null,
    format(E'Hi %s,\n\nYour spend cap is on and it is working: you were not charged for any usage over your plan''s quotas. The extra on invoice %s is add-ons, which the spend cap does not cover:\n\n%s\n\nThe cap stops surprise charges from usage, like traffic or active users going over the quota. Add-ons are different: they are features switched on for a project, so they are billed for every hour they are on.\n\nIf you do not need one of them, you can remove it under Project Settings > Add-ons, and its charge stops from that hour.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, l.bullets)
  from ticket_context c
  cross join lateral (
    select coalesce(sum(il.amount) filter (where il.kind = 'addon'), 0) as addons,
           coalesce(sum(il.amount) filter (where il.kind = 'usage'), 0) as overage,
           string_agg(il.name || ' ' || usd(il.amount), ', ' order by il.amount desc) filter (where il.kind = 'addon') as detail,
           string_agg('- ' || il.name || ' on ' || il.project || ': ' || usd(il.amount), E'\n' order by il.amount desc) filter (where il.kind = 'addon') as bullets
    from invoice_lines il where il.invoice_id = c.invoice_id
  ) l
  where c.ticket_id = p_ticket and c.invoice_spend_cap and l.addons > 0;
$$;

-- ---------------------------------------------------------------------------
-- Policy answers. Nothing is wrong with the account.
-- ---------------------------------------------------------------------------

create function pb_pre_sales(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'pre_sales', 60,
    'A question about how to pay, not a problem with the account. Supabase bills monthly, by card. The supported way to pay ahead is a credit top-up of up to $2,000 at a time; larger upfront payments are arranged case by case.',
    jsonb_build_array(
      ev('Plan', initcap(c.plan)),
      ev('Asks about', case when w.large then 'paying upfront by bank transfer or purchase order' else 'annual billing' end),
      ev('Top-up limit', '$2,000 per top-up')),
    case when w.large then 'Answer what is possible today, then hand over to the growth team, who arrange larger upfront payments.'
         else 'Say no to annual billing plainly, then offer credit top-ups as the way to prepay.' end,
    case when w.large then 'Growth team' end,
    case when w.large then
      format(E'Hi %s,\n\nThanks for asking before you start. Supabase bills monthly and takes card payments, so I cannot set up a standard bank transfer on a monthly invoice.\n\nFor a commitment of the size you describe there is another route: an upfront payment arranged with our growth team, who can work with a purchase order. I have passed your message to them with the details you gave, and they will reply on this thread.\n\nIn the meantime, credit top-ups of up to $2,000 each are available on the billing page if you want to prepay a smaller amount. Credits never expire.\n\nBest,\nTimothy', c.first_name)
    else
      format(E'Hi %s,\n\nWe do not offer annual plans: billing is monthly, by card. I would rather say that up front than leave you looking for the option.\n\nIf the aim is to pay ahead or avoid a monthly card charge, credit top-ups do that. You can add up to $2,000 at a time under Organization > Billing, and each invoice is taken from your credit balance before your card is charged. Credits never expire. For %s that is roughly a year of the plan fee in one top-up.\n\nOne thing to know: top-ups cannot be refunded, so add what you expect to use.\n\nBest,\nTimothy',
             c.first_name, c.org_name)
    end
  from ticket_context c
  cross join lateral (select lower(c.subject || ' ' || c.body) ~ '(bank transfer|wire|purchase order)' as large) w
  where c.ticket_id = p_ticket and c.category = 'Sales enquiry';
$$;

create function pb_refund_policy(p_ticket bigint) returns setof finding
language sql stable security invoker set search_path = public, pg_catalog as $$
  select 'refund_policy', 70,
    format('Invoice %s is correct: it matches the usage records and was collected once. Supabase does not refund card payments. What exists is credits: downgrading today would return about %s of the current plan fee as credits that never expire.',
           c.invoice_number, usd(r.credit)),
    jsonb_build_array(
      ev('Invoice', c.invoice_number || ', ' || usd(c.invoice_total) || ', ' || invoice_status_label(c.invoice_status)),
      ev('Matches usage records', 'yes'),
      ev('Successful charges', c.succeeded_attempts::text),
      ev('Credit if downgraded today', usd(r.credit) || ' for ' || r.days_left || ' unused days')),
    'Say no in the first sentence, then what is possible. A vague answer here produces three follow-ups. Escalate only if the charge itself looks wrong, which it does not.',
    null,
    format(E'Hi %s,\n\nI cannot refund invoice %s to your card. We do not refund card payments, and I would rather tell you that now than leave you waiting.\n\nHere is what I can do. If you no longer need the %s Plan, you can downgrade under Organization > Billing. The part of this month you have not used comes back as credits: downgrading today would return about %s for the %s days left in the cycle. Credits never expire and are used automatically if you upgrade again later.\n\nI checked the invoice itself as well. It matches your usage and was charged once, so nothing was taken in error.\n\nBest,\nTimothy',
           c.first_name, c.invoice_number, initcap(c.plan), usd(r.credit), r.days_left)
  from ticket_context c
  cross join lateral invoice_check(c.invoice_id) k
  cross join lateral (
    select d.days_left,
           round((select monthly_fee from plans where id = c.plan) * d.days_left / d.days_in_month, 2) as credit
    from (
      select extract(day from date_trunc('month', demo_now()) + interval '1 month' - interval '1 day')::integer as days_in_month,
             extract(day from date_trunc('month', demo_now()) + interval '1 month' - interval '1 day')::integer
               - extract(day from demo_now())::integer as days_left
    ) d
  ) r
  where c.ticket_id = p_ticket and c.category = 'Refund enquiry' and c.plan <> 'free'
    and k.matches and c.succeeded_attempts <= 1
    and not exists (select 1 from disputes d where d.invoice_id = c.invoice_id and d.status in ('needs_response', 'under_review'));
$$;

-- ---------------------------------------------------------------------------
-- Running the playbooks.
-- ---------------------------------------------------------------------------

create function diagnose_ticket(p_ticket bigint)
returns table (
  playbook text, title text, rank integer, cause text, evidence jsonb,
  next_step text, escalate_to text, doc_url text, reply text
)
language sql stable security invoker set search_path = public, pg_catalog as $$
  with found as (
    select * from pb_duplicate_charge(p_ticket)
    union all select * from pb_invoice_mismatch(p_ticket)
    union all select * from pb_dispute_open(p_ticket)
    union all select * from pb_overdue_paused(p_ticket)
    union all select * from pb_free_project_paused(p_ticket)
    union all select * from pb_expired_card(p_ticket)
    union all select * from pb_bank_block(p_ticket)
    union all select * from pb_payment_declined(p_ticket)
    union all select * from pb_quota_restriction(p_ticket)
    union all select * from pb_downgrade_charge(p_ticket)
    union all select * from pb_tax_id_missing(p_ticket)
    union all select * from pb_extra_projects(p_ticket)
    union all select * from pb_usage_overage(p_ticket)
    union all select * from pb_addons_with_cap(p_ticket)
    union all select * from pb_pre_sales(p_ticket)
    union all select * from pb_refund_policy(p_ticket)
  )
  select f.playbook, p.title, f.rank, f.cause, f.evidence, f.next_step, f.escalate_to, p.doc_url, f.reply
  from found f
  join playbooks p on p.id = f.playbook
  union all
  -- No playbook matched. Saying so is better than forcing a match.
  select 'needs_review', 'No playbook matched', 999,
         'None of the known causes is present on this account. Read the thread and the account by hand.',
         '[]'::jsonb, 'Work it manually, and if the same shape turns up again, write a playbook for it.',
         null, null, null
  where not exists (select 1 from found)
  order by 3;
$$;

comment on function diagnose_ticket(bigint) is
  'Every playbook that matches a ticket, most specific first, each with its cause, evidence, next step and a drafted first reply.';

-- The SQL of each playbook, read from the database itself, so what the
-- console shows is what actually ran.
create view playbook_source
with (security_invoker = true) as
select p.id, p.title, p.applies_when, p.doc_url, p.sort,
       pg_get_functiondef(('public.pb_' || p.id || '(bigint)')::regprocedure) as sql
from playbooks p;

-- The handover for a ticket that support cannot settle. An engineer should be
-- able to act on it without opening the ticket.
create function escalation_note(p_ticket bigint) returns text
language sql stable security invoker set search_path = public, pg_catalog as $$
  select format(
    E'To: %s\nTicket #%s (%s): %s\n\nCustomer: %s, org %s, %s Plan, spend cap %s\nInvoice: %s, %s, %s\n\nWhat the customer reports\n%s\n\nWhat I found\n%s\n\nEvidence\n%s\n\nWhat I need\n%s',
    d.escalate_to, c.ticket_id, c.severity, c.subject,
    c.requester_name, c.org_id, initcap(c.plan), case when c.spend_cap then 'on' else 'off' end,
    coalesce(c.invoice_number, 'none'), coalesce(usd(c.invoice_total), 'n/a'),
    coalesce(invoice_status_label(c.invoice_status), 'n/a'),
    c.body, d.cause,
    (select string_agg('- ' || (e->>'label') || ': ' || (e->>'value'), E'\n') from jsonb_array_elements(d.evidence) e),
    -- The ask is written for the person receiving the note, not for support.
    case d.playbook
      when 'duplicate_charge' then 'Reverse the extra charge, and confirm here so I can tell the customer it is done.'
      when 'invoice_mismatch' then 'Correct and reissue the invoice. Please also say whether other invoices from the same billing run could be affected.'
      when 'dispute_open'     then 'Decide whether to contest the dispute before the evidence deadline, and tell me what I can say to the customer in the meantime.'
      when 'pre_sales'        then 'Contact the customer about an upfront payment against a purchase order. I have told them to expect a reply on this thread.'
      else d.next_step
    end)
  from ticket_context c
  cross join lateral (
    select * from diagnose_ticket(c.ticket_id) x where x.escalate_to is not null order by x.rank limit 1
  ) d
  where c.ticket_id = p_ticket;
$$;

-- The inbox: open tickets, oldest first-reply deadline first.
create view ticket_queue
with (security_invoker = true) as
select t.id, t.org_id, o.name as org_name, o.plan, t.requester_name, t.category, t.severity,
       t.subject, t.created_at, ticket_topic(t.subject, t.body) as topic,
       sla.due_at as first_response_due,
       round(extract(epoch from demo_now() - t.created_at) / 3600.0, 1) as hours_waiting,
       case when demo_now() > sla.due_at then 'overdue'
            when demo_now() > sla.due_at - (sla.due_at - t.created_at) / 4 then 'due soon'
            else 'on track' end as sla_state,
       d.playbook, d.title as diagnosis, d.escalate_to
from tickets t
join orgs o on o.id = t.org_id
cross join lateral (
  select t.created_at + make_interval(hours => (
    select s.value::integer from demo_settings s where s.key = 'first_response_hours_' || lower(t.severity))) as due_at
) sla
left join lateral (select * from diagnose_ticket(t.id) limit 1) d on true
where t.status = 'open';

-- Patterns. Which causes fill the queue, and which keep growing.
create view playbook_stats
with (security_invoker = true) as
select p.id as playbook, p.title,
       count(t.id) as tickets,
       round(100.0 * count(t.id) / nullif(sum(count(t.id)) over (), 0), 1) as share_pct,
       count(t.id) filter (where t.escalated) as escalated,
       round((percentile_cont(0.5) within group (
         order by extract(epoch from t.first_response_at - t.created_at) / 60.0))::numeric, 0) as median_first_response_min
from playbooks p
left join tickets t on t.solved_by_playbook = p.id and t.status = 'solved'
group by p.id, p.title, p.sort;

create view tickets_weekly
with (security_invoker = true) as
select date_trunc('week', t.created_at)::date as week_start, t.solved_by_playbook as playbook, count(*) as tickets
from tickets t
where t.status = 'solved' and t.solved_by_playbook is not null
group by 1, 2;

-- New organizations spending far beyond anything they have ever paid. Caught
-- on the day, this is a conversation. Caught as an overdue invoice six weeks
-- later, it is a loss.
create view spend_spike_signals
with (security_invoker = true) as
select o.id as org_id, o.name, o.plan, o.created_at,
       extract(day from demo_now() - o.created_at)::integer as age_days,
       coalesce(paid.total, 0) as lifetime_paid,
       round(run.monthly, 2) as monthly_run_rate,
       run.largest_size
from orgs o
cross join lateral (
  select coalesce(sum(cs.hourly_price * 730), 0) as monthly,
         (array_agg(cs.name order by cs.sort desc))[1] as largest_size
  from projects p join compute_sizes cs on cs.id = p.compute_size
  where p.org_id = o.id and p.status = 'active'
) run
left join lateral (
  select sum(i.total) as total from invoices i where i.org_id = o.id and i.status = 'paid'
) paid on true
where o.created_at > demo_now() - interval '30 days'
  and run.monthly >= 1000
  and coalesce(paid.total, 0) < 100;

alter table playbooks enable row level security;
create policy "public read" on playbooks for select to anon, authenticated using (true);

-- Supabase grants these by default. Stating them makes the access model
-- readable here and keeps the tests honest, since PGlite grants nothing.
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;

commit;
