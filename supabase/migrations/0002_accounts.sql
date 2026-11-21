-- 0002: customers, what they used, what they were invoiced, how they paid,
-- and the tickets they sent.
--
-- Every row in these tables is invented by supabase/seed.sql. The shapes are
-- not: statuses and field names follow what is public about the tools Supabase
-- uses. Invoice statuses and decline codes are Stripe's, the credit ledger
-- follows Orb's, organization restriction states and ticket categories are the
-- ones in Supabase's own dashboard source.

begin;

create table orgs (
  id           text primary key,              -- the slug, as in the dashboard URL
  name         text        not null,
  owner_name   text        not null,
  billing_email text       not null,
  country      text        not null,          -- ISO 3166-1 alpha-2, from the billing address
  plan         text        not null references plans (id),
  spend_cap    boolean     not null default true,
  tax_id       text,
  tax_rate     numeric(5,4) not null default 0,
  -- Set while Supabase is restricting the organization under fair use.
  restriction_status text check (restriction_status in ('grace_period', 'grace_period_over', 'restricted')),
  created_at   timestamptz not null
);

create table projects (
  id           bigint generated always as identity primary key,
  org_id       text        not null references orgs (id) on delete cascade,
  name         text        not null,
  compute_size text        not null references compute_sizes (id),
  region       text        not null,
  status       text        not null default 'active' check (status in ('active', 'paused')),
  -- Why a paused project is paused decides who can help: support cannot
  -- restore a project paused for an unpaid invoice, only payment can.
  pause_reason text check (pause_reason in ('overdue_invoice', 'inactivity', 'paused_by_user', 'restriction')),
  created_at   timestamptz not null,
  check ((status = 'paused') = (pause_reason is not null))
);

create table plan_changes (
  id         bigint generated always as identity primary key,
  org_id     text        not null references orgs (id) on delete cascade,
  changed_at timestamptz not null,
  from_plan  text        not null references plans (id),
  to_plan    text        not null references plans (id),
  -- 'customer': the customer changed plan. 'overdue_invoice': Supabase moved
  -- the organization to Free because an invoice went unpaid.
  reason     text        not null check (reason in ('customer', 'overdue_invoice'))
);

-- Cards only, and one active card per organization, as Supabase documents.
create table payment_methods (
  id         bigint generated always as identity primary key,
  org_id     text    not null references orgs (id) on delete cascade,
  brand      text    not null,
  last4      text    not null check (last4 ~ '^[0-9]{4}$'),
  -- A card is valid to the end of a month. Stored as a date, not a month and a
  -- year, so it moves with every other date when the demo clock advances.
  expires_on date    not null,
  country    text    not null,                -- the country of the bank that issued the card
  is_active  boolean not null default true
);

create unique index one_active_card_per_org on payment_methods (org_id) where is_active;

-- What each project consumed in a billing period. period_start is the first
-- day of the usage period.
create table compute_usage (
  project_id   bigint  not null references projects (id) on delete cascade,
  period_start date    not null,
  compute_size text    not null references compute_sizes (id),
  hours        numeric not null check (hours >= 0),
  primary key (project_id, period_start)
);

create table addon_usage (
  project_id   bigint  not null references projects (id) on delete cascade,
  period_start date    not null,
  addon        text    not null references addons (id),
  hours        numeric not null check (hours >= 0),
  primary key (project_id, period_start, addon)
);

-- project_id is set for per-project metrics (disk size) and null otherwise.
create table usage (
  id           bigint generated always as identity primary key,
  org_id       text    not null references orgs (id) on delete cascade,
  project_id   bigint  references projects (id) on delete cascade,
  period_start date    not null,
  metric       text    not null references usage_metrics (id),
  quantity     numeric not null check (quantity >= 0)
);

create unique index usage_one_row on usage (org_id, coalesce(project_id, 0), period_start, metric);

create table invoices (
  id            bigint generated always as identity primary key,
  org_id        text        not null references orgs (id) on delete cascade,
  number        text        not null unique,
  -- Stripe's statuses. The dashboard shows `void` as "Forgiven" and both
  -- `open` and `uncollectible` as "Outstanding".
  status        text        not null check (status in ('draft', 'open', 'paid', 'void', 'uncollectible')),
  -- An invoice carries two periods: usage for the period that just ended, in
  -- arrears, and the plan fee for the period about to start, in advance.
  -- They can be on different plans, which is what happens after a downgrade.
  usage_period_start date   not null,
  usage_period_end   date   not null,
  usage_plan    text        not null references plans (id),
  fee_plan      text        not null references plans (id),
  spend_cap     boolean     not null,
  issued_at     timestamptz not null,
  due_at        timestamptz not null,
  paid_at       timestamptz,
  total         numeric(12,2) not null
);

create index invoices_by_org on invoices (org_id, issued_at desc);

create table invoice_lines (
  invoice_id bigint  not null references invoices (id) on delete cascade,
  line_no    integer not null,
  kind       text    not null check (kind in ('plan', 'compute', 'addon', 'usage', 'compute_credits', 'tax', 'credits')),
  project    text,
  name       text    not null,
  quantity   numeric,
  unit       text,
  included   numeric,
  billable   numeric,
  unit_price numeric,
  amount     numeric(12,2) not null,
  primary key (invoice_id, line_no)
);

create table payment_attempts (
  id                bigint generated always as identity primary key,
  invoice_id        bigint        not null references invoices (id) on delete cascade,
  payment_method_id bigint        references payment_methods (id) on delete set null,
  attempted_at      timestamptz   not null,
  status            text          not null check (status in ('succeeded', 'failed', 'processing')),
  decline_code      text          references decline_codes (code),
  amount            numeric(12,2) not null,
  check ((status = 'failed') = (decline_code is not null))
);

create index payment_attempts_by_invoice on payment_attempts (invoice_id, attempted_at);

-- Credits never expire and are never refunded to a card. Entry types follow
-- Orb's credit ledger.
create table credit_ledger (
  id         bigint generated always as identity primary key,
  org_id     text          not null references orgs (id) on delete cascade,
  at         timestamptz   not null,
  entry_type text          not null check (entry_type in ('increment', 'decrement')),
  amount     numeric(12,2) not null check (amount > 0),
  reason     text          not null,
  invoice_id bigint        references invoices (id) on delete set null
);

create index credit_ledger_by_org on credit_ledger (org_id, at);

-- A dispute is the cardholder asking their bank, not Supabase, for the money
-- back. Reasons and statuses are Stripe's.
create table disputes (
  id              bigint generated always as identity primary key,
  invoice_id      bigint        not null references invoices (id) on delete cascade,
  opened_at       timestamptz   not null,
  reason          text          not null check (reason in ('fraudulent', 'unrecognized', 'duplicate', 'subscription_canceled', 'product_unacceptable', 'general')),
  status          text          not null check (status in ('needs_response', 'under_review', 'won', 'lost')),
  amount          numeric(12,2) not null,
  evidence_due_by timestamptz
);

create table tickets (
  id             bigint generated always as identity primary key,
  org_id         text        not null references orgs (id) on delete cascade,
  requester_name text        not null,
  -- The billing-related categories and the severity levels of the support
  -- form in the Supabase dashboard.
  category       text        not null check (category in ('Billing', 'Refund enquiry', 'Sales enquiry')),
  severity       text        not null check (severity in ('Low', 'Normal', 'High', 'Urgent')),
  subject        text        not null,
  body           text        not null,
  invoice_id     bigint      references invoices (id) on delete set null,
  status         text        not null default 'open' check (status in ('open', 'solved')),
  created_at     timestamptz not null,
  first_response_at timestamptz,
  solved_at      timestamptz,
  -- For solved tickets: the playbook that settled it. Feeds the patterns page.
  solved_by_playbook text,
  escalated      boolean     not null default false
);

create index tickets_open on tickets (created_at) where status = 'open';
create index tickets_by_org on tickets (org_id);

-- The balance is the ledger added up, never a number stored on its own, so
-- it cannot drift from its history.
create view credit_balances
with (security_invoker = true) as
select o.id as org_id,
       coalesce(sum(case l.entry_type when 'increment' then l.amount else -l.amount end), 0)::numeric(12,2) as balance
from orgs o
left join credit_ledger l on l.org_id = o.id
group by o.id;

-- Country names for the codes the demo uses, so a reply says "Nigeria", not "NG".
create function country_name(code text) returns text
language sql immutable set search_path = pg_catalog as $$
  select coalesce((select n from (values
    ('AE', 'the United Arab Emirates'), ('BR', 'Brazil'), ('CA', 'Canada'), ('DE', 'Germany'),
    ('FR', 'France'), ('GB', 'the United Kingdom'), ('GH', 'Ghana'), ('IN', 'India'), ('IT', 'Italy'),
    ('JP', 'Japan'), ('KE', 'Kenya'), ('MX', 'Mexico'), ('NG', 'Nigeria'), ('NL', 'the Netherlands'),
    ('NO', 'Norway'), ('PL', 'Poland'), ('RO', 'Romania'), ('SE', 'Sweden'), ('SG', 'Singapore'),
    ('TR', 'Turkey'), ('US', 'the United States'), ('ZA', 'South Africa')
  ) as c(k, n) where k = code), code);
$$;

-- The label the customer sees in the dashboard for an invoice.
create function invoice_status_label(status text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case status
    when 'paid' then 'Paid'
    when 'void' then 'Forgiven'
    when 'open' then 'Outstanding'
    when 'uncollectible' then 'Outstanding'
    else initcap(status)
  end;
$$;

alter table orgs             enable row level security;
alter table projects         enable row level security;
alter table plan_changes     enable row level security;
alter table payment_methods  enable row level security;
alter table compute_usage    enable row level security;
alter table addon_usage      enable row level security;
alter table usage            enable row level security;
alter table invoices         enable row level security;
alter table invoice_lines    enable row level security;
alter table payment_attempts enable row level security;
alter table credit_ledger    enable row level security;
alter table disputes         enable row level security;
alter table tickets          enable row level security;

-- Read-only to everyone, because every row is synthetic and the point of the
-- demo is that a visitor can look. A real billing console would be the
-- opposite: no anon access at all, and agents scoped to the tickets they own.
-- Nothing has an insert, update or delete policy, so the API cannot write.
create policy "public read" on orgs             for select to anon, authenticated using (true);
create policy "public read" on projects         for select to anon, authenticated using (true);
create policy "public read" on plan_changes     for select to anon, authenticated using (true);
create policy "public read" on payment_methods  for select to anon, authenticated using (true);
create policy "public read" on compute_usage    for select to anon, authenticated using (true);
create policy "public read" on addon_usage      for select to anon, authenticated using (true);
create policy "public read" on usage            for select to anon, authenticated using (true);
create policy "public read" on invoices         for select to anon, authenticated using (true);
create policy "public read" on invoice_lines    for select to anon, authenticated using (true);
create policy "public read" on payment_attempts for select to anon, authenticated using (true);
create policy "public read" on credit_ledger    for select to anon, authenticated using (true);
create policy "public read" on disputes         for select to anon, authenticated using (true);
create policy "public read" on tickets          for select to anon, authenticated using (true);

commit;
