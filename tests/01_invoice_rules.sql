-- The billing rules, pinned to worked examples. Where Supabase's docs give an
-- example with numbers, the test uses the same numbers.

create function total(p_plan text, p_cap boolean, p_projects jsonb, p_usage jsonb default '{}',
                      p_tax numeric default 0, p_fee_plan text default null, p_credits numeric default 0)
returns numeric language sql as $$
  select coalesce(sum(amount), 0) from quote_invoice(p_plan, p_cap, p_projects, p_usage, p_tax, p_fee_plan, p_credits);
$$;

-- Compute and compute credits
select expect_eq('Pro with one Micro project costs $25: the credits cover the project',
  total('pro', true, '[{"size":"micro","hours":744}]'), 25.00);

select expect_eq('Pro with three Micro projects costs $45 (25 + 30 - 10)',
  total('pro', true, '[{"size":"micro"},{"size":"micro"},{"size":"micro"}]'), 45.00);

select expect_eq('Compute credits never exceed compute: a 30-day month on Micro is still $25',
  total('pro', true, '[{"size":"micro","hours":720}]'), 25.00);

select expect_eq('A Nano project on a paid plan is billed at the Micro price',
  (select amount from quote_invoice('pro', true, '[{"size":"nano","hours":744}]') where kind = 'compute'), 10.00);

select expect_eq('A project paused half the month is billed for the hours it ran',
  (select amount from quote_invoice('pro', true, '[{"size":"small","hours":372}]') where kind = 'compute'), 7.66);

select expect_eq('Compute credits do not offset usage: no projects, 300 GB egress, cap off',
  total('pro', false, '[]', '{"egress": 300}'), 29.50);

-- The Free Plan
select expect_eq('The Free Plan is never billed, even far over quota',
  total('free', false, '[{"size":"nano"}]', '{"egress": 900, "mau": 400000}'), 0.00);

-- The spend cap
select expect_eq('Spend cap on: 300 GB egress on Pro is not billed',
  total('pro', true, '[{"size":"micro"}]', '{"egress": 300}'), 25.00);

select expect_eq('Spend cap off: the same 50 GB over quota costs $4.50',
  total('pro', false, '[{"size":"micro"}]', '{"egress": 300}'), 29.50);

select expect_eq('The spend cap does not exist on Team: overage is billed whatever is passed',
  total('team', true, '[]', '{"egress": 300}'), 603.50);

select expect_eq('Add-ons are billed with the spend cap on: IPv4 for a month is $4.09',
  total('pro', true, '[{"size":"micro","addons":{"ipv4":744}}]'), 29.09);

-- Usage prices
select expect_eq('12M function invocations over quota cost $24',
  (select amount from quote_invoice('pro', false, '[]', '{"function_invocations": 14000000}') where kind = 'usage'), 24.00);

select expect_eq('4,000 monthly active users over quota cost $13',
  (select amount from quote_invoice('pro', false, '[]', '{"mau": 104000}') where kind = 'usage'), 13.00);

select expect_eq('Disk quota is per project: 10 GB and 6 GB bill 2 GB, not 0',
  (select sum(amount) from quote_invoice('pro', false, '[{"disk_gb":10},{"disk_gb":6}]') where kind = 'usage'), 0.25);

select expect_eq('Usage inside the quota appears on the invoice at $0',
  (select amount from quote_invoice('pro', false, '[]', '{"egress": 100}') where kind = 'usage'), 0.00);

-- Tax, credits and plan changes
select expect_eq('19% tax on a $25 invoice is $4.75',
  total('pro', true, '[{"size":"micro"}]', '{}', 0.19), 29.75);

select expect_eq('Credits are used before the card is charged',
  total('pro', true, '[{"size":"micro"}]', '{}', 0, null, 16.67), 8.33);

select expect_eq('Credits never take an invoice below zero',
  total('pro', true, '[{"size":"micro"}]', '{}', 0, null, 100), 0.00);

select expect_eq('After a downgrade: usage on Pro, fee on Free, so no plan fee',
  total('pro', false, '[{"size":"small","hours":228}]', '{"egress": 600}', 0, 'free'), 31.50);

-- Numbers in the explanations are written the way a person would write them
select expect_eq('Small prices keep their decimals', qty(0.01344), '0.01344');
select expect_eq('Whole numbers have no trailing point', qty(744), '744');
select expect_eq('Thousands are grouped', qty(14000000), '14,000,000');
select expect_eq('Negative money reads -$10.00', usd(-10), '-$10.00');

select expect_true('The compute explanation states the real hourly price',
  (select explanation like '%744 hours at $0.01344 an hour%'
   from quote_invoice('pro', true, '[{"size":"micro","hours":744}]') where kind = 'compute'));

select expect_true('The overage explanation states the real unit price',
  (select explanation like '%at $0.00325 per user.'
   from quote_invoice('pro', false, '[]', '{"mau": 104000}') where kind = 'usage'));

-- Every line explains itself
select expect_true('Every line of a quote carries an explanation',
  (select bool_and(length(explanation) > 20)
   from quote_invoice('pro', false, '[{"size":"small","addons":{"pitr_7":744}}]', '{"egress": 900, "mau": 10}', 0.2, null, 5)));

drop function total(text, boolean, jsonb, jsonb, numeric, text, numeric);
