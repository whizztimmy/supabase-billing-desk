-- 0001: the price list.
--
-- Everything in this file is public information about how Supabase bills,
-- copied from its documentation source (github.com/supabase/supabase,
-- apps/docs/content/guides/platform) on 21 November 2026. Each row carries the
-- page it came from, so a price can be checked in one click and corrected in
-- one place when Supabase changes it.
--
-- One simplification runs through the whole demo: Supabase meters disk,
-- storage and add-ons by the hour, and this demo bills usage as one monthly
-- quantity. Compute and add-ons are still billed by the hour.

begin;

create table plans (
  id                  text primary key,
  name                text          not null,
  monthly_fee         numeric(10,2) not null,
  -- Paid plans include $10 of compute credits a month, enough for one Micro
  -- project. They offset compute only, never usage or add-ons.
  compute_credits     numeric(10,2) not null,
  -- The spend cap exists on Pro only. Team and above always pay overages.
  spend_cap_available boolean       not null,
  sort                integer       not null,
  source_url          text          not null
);

insert into plans values
  ('free', 'Free Plan',   0,  0, false, 1, 'https://supabase.com/docs/guides/platform/billing-on-supabase'),
  ('pro',  'Pro Plan',   25, 10, true,  2, 'https://supabase.com/docs/guides/platform/billing-on-supabase'),
  ('team', 'Team Plan', 599, 10, false, 3, 'https://supabase.com/docs/guides/platform/billing-on-supabase');

create table compute_sizes (
  id           text primary key,
  name         text          not null,
  hourly_price numeric(10,5) not null,
  sort         integer       not null,
  source_url   text          not null
);

-- Nano is free on the Free Plan. On a paid plan a Nano project is billed at
-- the Micro price, which quote_invoice() handles.
insert into compute_sizes
select v.id, v.name, v.price, v.sort, 'https://supabase.com/docs/guides/platform/manage-your-usage/compute'
from (values
  ('nano',  'Nano',  0,       1),
  ('micro', 'Micro', 0.01344, 2),
  ('small', 'Small', 0.0206,  3),
  ('medium','Medium',0.0822,  4),
  ('large', 'Large', 0.1517,  5),
  ('xl',    'XL',    0.2877,  6),
  ('2xl',   '2XL',   0.562,   7),
  ('4xl',   '4XL',   1.32,    8),
  ('8xl',   '8XL',   2.562,   9),
  ('12xl',  '12XL',  3.836,  10),
  ('16xl',  '16XL',  5.12,   11)
) as v(id, name, price, sort);

create table usage_metrics (
  id            text primary key,
  -- The name as it appears on a Supabase invoice.
  line_name     text    not null,
  unit          text    not null,
  -- 'org': one quota shared by every project in the organization.
  -- 'project': each project gets its own quota (disk size).
  scope         text    not null check (scope in ('org', 'project')),
  -- null means the feature is not available on that plan.
  free_quota    numeric,
  paid_quota    numeric not null,
  -- Price for `price_per` units over the quota: $2 per 1,000,000 invocations.
  overage_price numeric(12,5) not null,
  price_per     numeric not null default 1,
  -- When the spend cap is on, overage on a covered item is blocked, not billed.
  covered_by_spend_cap boolean not null,
  sort          integer not null,
  source_url    text    not null
);

insert into usage_metrics values
  ('egress',            'Egress GB',                     'GB',     'org',     5,       250,     0.09,    1,       true, 1, 'https://supabase.com/docs/guides/platform/manage-your-usage/egress'),
  ('cached_egress',     'Cached Egress GB',              'GB',     'org',     5,       250,     0.03,    1,       true, 2, 'https://supabase.com/docs/guides/platform/manage-your-usage/egress'),
  ('disk_size',         'Disk Size GB',                  'GB',     'project', 0.5,     8,       0.125,   1,       true, 3, 'https://supabase.com/docs/guides/platform/manage-your-usage/disk-size'),
  ('storage_size',      'Storage Size GB',               'GB',     'org',     1,       100,     0.021,   1,       true, 4, 'https://supabase.com/docs/guides/platform/manage-your-usage/storage-size'),
  ('mau',               'Monthly Active Users',          'users',  'org',     50000,   100000,  0.00325, 1,       true, 5, 'https://supabase.com/docs/guides/platform/manage-your-usage/monthly-active-users'),
  ('mau_sso',           'Monthly Active SSO Users',      'users',  'org',     null,    50,      0.015,   1,       true, 6, 'https://supabase.com/docs/guides/platform/manage-your-usage/monthly-active-users-sso'),
  ('function_invocations','Function Invocations',        'invocations','org', 500000,  2000000, 2,       1000000, true, 7, 'https://supabase.com/docs/guides/platform/manage-your-usage/edge-function-invocations'),
  ('realtime_messages', 'Realtime Messages',             'messages','org',    2000000, 5000000, 2.5,     1000000, true, 8, 'https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages'),
  ('realtime_peak_connections','Realtime Peak Connections','connections','org',200,    500,     10,      1000,    true, 9, 'https://supabase.com/docs/guides/platform/manage-your-usage/realtime-peak-connections'),
  ('image_transformations','Storage Image Transformations','images','org',    null,    100,     5,       1000,    true, 10,'https://supabase.com/docs/guides/platform/manage-your-usage/storage-image-transformations');

-- Add-ons are things a customer switches on deliberately. None of them is
-- covered by the spend cap, which is the cause of a whole family of tickets.
create table addons (
  id           text primary key,
  line_name    text          not null,
  hourly_price numeric(10,5) not null,
  sort         integer       not null,
  source_url   text          not null
);

insert into addons values
  ('ipv4',          'IPv4 Hours',                         0.0055, 1, 'https://supabase.com/docs/guides/platform/manage-your-usage/ipv4'),
  ('custom_domain', 'Custom Domain Hours',                0.0137, 2, 'https://supabase.com/docs/guides/platform/manage-your-usage/custom-domains'),
  ('pitr_7',        '7-day Point-in-time recovery Hours', 0.137,  3, 'https://supabase.com/docs/guides/platform/manage-your-usage/point-in-time-recovery');

-- Stripe's card decline codes, with what each one means for the customer.
-- share_detail = false marks the codes where Stripe says to tell the customer
-- only that the card was declined.
create table decline_codes (
  code            text primary key,
  meaning         text    not null,
  customer_action text    not null,
  share_detail    boolean not null default true,
  source_url      text    not null default 'https://docs.stripe.com/declines/codes'
);

insert into decline_codes (code, meaning, customer_action, share_detail) values
  ('expired_card',            'The card has expired.',                                 'Add a new card.', true),
  ('insufficient_funds',      'The card does not have enough funds for the charge.',   'Use another card, or fund this one and pay again.', true),
  ('do_not_honor',            'The bank declined the charge without giving a reason.', 'Ask the bank to allow the charge, then pay again.', true),
  ('generic_decline',         'The bank declined the charge without giving a reason.', 'Ask the bank to allow the charge, then pay again.', true),
  ('authentication_required', 'The bank wants the cardholder to approve the charge (3D Secure).', 'Pay from the invoices page so the bank can ask for approval.', true),
  ('card_velocity_exceeded',  'The charge would take the card over its limit.',        'Ask the bank to raise the limit, or use another card.', true),
  ('fraudulent',              'The bank suspects fraud.',                              'Say only that the card was declined, and ask for another card.', false);

-- Settings for the demo. `kind` separates what Supabase documents from what
-- this demo had to assume because Supabase does not publish it.
create table demo_settings (
  key   text primary key,
  value text not null,
  kind  text not null check (kind in ('demo', 'documented', 'assumed')),
  note  text not null
);

insert into demo_settings values
  ('demo_now', '2026-11-20 09:00:00+00', 'demo',
   'The moment the demo treats as now. The seed sets it to 20 November 2026; advance_demo_clock() then moves it, and every date in the data with it, to 09:00 UTC on the real day.'),
  ('overdue_pause_days', '14', 'assumed',
   'Days after the due date before an unpaid invoice pauses projects. Supabase documents the pause, not the number of days.'),
  ('first_response_hours_urgent', '1',  'assumed', 'First reply target for Urgent tickets. Supabase publishes no target.'),
  ('first_response_hours_high',   '4',  'assumed', 'First reply target for High tickets.'),
  ('first_response_hours_normal', '24', 'assumed', 'First reply target for Normal tickets.'),
  ('first_response_hours_low',    '48', 'assumed', 'First reply target for Low tickets.'),
  ('topup_limit_usd', '2000', 'documented', 'Largest single credit top-up. https://supabase.com/docs/guides/platform/credits');

create function demo_now() returns timestamptz
language sql stable security invoker set search_path = public, pg_catalog as $$
  select value::timestamptz from demo_settings where key = 'demo_now';
$$;

comment on function demo_now() is 'The fixed date the demo treats as today.';

-- $1,234.50, and -$10.00 rather than $-10.00.
create function usd(amount numeric) returns text
language sql immutable set search_path = pg_catalog as $$
  select case when amount < 0 then '-' else '' end || '$' || to_char(abs(amount), 'FM999,999,990.00');
$$;

-- 1,900 and 0.5 and 0.01344, rather than 1900.000000 and .500000.
create function qty(n numeric) returns text
language sql immutable set search_path = pg_catalog as $$
  select rtrim(to_char(n, 'FM999,999,999,990.99999'), '.');
$$;

alter table plans          enable row level security;
alter table compute_sizes  enable row level security;
alter table usage_metrics  enable row level security;
alter table addons         enable row level security;
alter table decline_codes  enable row level security;
alter table demo_settings  enable row level security;

create policy "public read" on plans         for select to anon, authenticated using (true);
create policy "public read" on compute_sizes for select to anon, authenticated using (true);
create policy "public read" on usage_metrics for select to anon, authenticated using (true);
create policy "public read" on addons        for select to anon, authenticated using (true);
create policy "public read" on decline_codes for select to anon, authenticated using (true);
create policy "public read" on demo_settings for select to anon, authenticated using (true);

commit;
