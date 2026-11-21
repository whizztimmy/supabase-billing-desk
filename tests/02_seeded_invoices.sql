-- The seeded invoices: each scenario's total, and the reconciliation that
-- finds the one invoice whose lines do not match its usage records.

create function latest_total(p_org text) returns numeric language sql as $$
  select total from invoices where org_id = p_org order by issued_at desc limit 1;
$$;

select expect_eq('Kestrel Maps: three projects on Pro',           latest_total('kestrel-maps'),    45.00);
select expect_eq('Tidepool Games: overage with the cap off',      latest_total('tidepool-games'),  248.66);
select expect_eq('Quill Notes: add-ons with the cap on',          latest_total('quill-notes'),     136.35);
select expect_eq('Harbor CRM: the unpaid September invoice',      latest_total('harbor-crm'),      39.51);
select expect_eq('Mosaic Studio: charged after a downgrade',      latest_total('mosaic-studio'),   14.83);
select expect_eq('Vela Commerce: $25 plus 19% tax',               latest_total('vela-commerce'),   29.75);
select expect_eq('Cobalt Robotics: Team with two projects',       latest_total('cobalt-robotics'), 717.19);
select expect_eq('Nimbus Education: over quota, cap on, not billed for it', latest_total('nimbus-edu'), 30.33);

select expect_true('Every invoice total equals the sum of its lines',
  (select bool_and(i.total = (select sum(l.amount) from invoice_lines l where l.invoice_id = i.id)) from invoices i));

select expect_eq('Reconciliation finds exactly one invoice that does not match its usage',
  (select string_agg(i.org_id, ', ') from invoices i cross join lateral invoice_check(i.id) k where not k.matches),
  'orchard-iot');

select expect_eq('Orchard IoT was overcharged by exactly the missing compute credits',
  (select k.difference from invoices i cross join lateral invoice_check(i.id) k where i.org_id = 'orchard-iot'), 10.00);

select expect_eq('The missing line is named in the explanation',
  (select name from invoices i cross join lateral explain_invoice(i.id) e where i.org_id = 'orchard-iot' and not e.matches),
  'Compute Credits');

select expect_eq('Mosaic Studio used all of its downgrade credits',
  (select balance from credit_balances where org_id = 'mosaic-studio'), 0.00);

select expect_eq('Only Pixel Forge has an invoice collected twice',
  (select string_agg(org_id, ', ') from invoice_overview where succeeded_attempts > 1), 'pixel-forge');

select expect_eq('Harbor CRM is 50 days overdue on the demo date',
  (select days_overdue from invoice_overview where org_id = 'harbor-crm'), 50);

select expect_eq('A void invoice would be shown to the customer as Forgiven', invoice_status_label('void'), 'Forgiven');

select expect_eq('Spend spike signal: the six-day-old organization running a 16XL',
  (select string_agg(org_id, ', ') from spend_spike_signals), 'ember-labs');

drop function latest_total(text);
