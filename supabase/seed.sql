-- Synthetic data. Every company, person, card and ticket below is invented.
--
-- The seed is built around scenarios, not volume: each organization is set up
-- so that one cause is really present in its account, and a ticket about it
-- is waiting in the inbox. Invoices are not typed in. They are issued by the
-- same engine that later checks them, from the usage rows seeded here. Two
-- billing errors are then planted on purpose, for the playbooks to find.
--
-- The demo's "today" is 20 November 2026 (see demo_settings).

begin;

-- ---------------------------------------------------------------------------
-- Helpers, dropped at the end of this file.
-- ---------------------------------------------------------------------------

create function seed_project(
  p_org text, p_name text, p_size text,
  p_period date default '2026-10-01', p_hours numeric default 744,
  p_disk numeric default null, p_addons jsonb default '{}',
  p_status text default 'active', p_pause text default null
) returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into projects (org_id, name, compute_size, region, status, pause_reason, created_at)
  values (p_org, p_name, p_size, 'eu-central-1', p_status, p_pause,
          (select created_at + interval '1 hour' from orgs where id = p_org))
  returning id into v_id;
  if p_hours > 0 then
    insert into compute_usage values (v_id, p_period, p_size, p_hours);
  end if;
  if p_disk is not null then
    insert into usage (org_id, project_id, period_start, metric, quantity) values (p_org, v_id, p_period, 'disk_size', p_disk);
  end if;
  insert into addon_usage select v_id, p_period, e.key, e.value::numeric from jsonb_each_text(p_addons) e;
  return v_id;
end $$;

create function seed_usage(p_org text, p_usage jsonb, p_period date default '2026-10-01')
returns void language sql as $$
  insert into usage (org_id, period_start, metric, quantity)
  select p_org, p_period, e.key, e.value::numeric from jsonb_each_text(p_usage) e;
$$;

-- Issues an invoice the way the billing system would: from the usage rows.
create function seed_invoice(
  p_org text, p_start date, p_end date, p_issued timestamptz, p_status text,
  p_usage_plan text default null, p_fee_plan text default null
) returns bigint language plpgsql as $$
declare v_id bigint; v_total numeric;
begin
  insert into invoices (org_id, number, status, usage_period_start, usage_period_end,
                        usage_plan, fee_plan, spend_cap, issued_at, due_at, total)
  select o.id, 'pending', p_status, p_start, p_end,
         coalesce(p_usage_plan, o.plan), coalesce(p_fee_plan, p_usage_plan, o.plan),
         o.spend_cap, p_issued, p_issued, 0
  from orgs o where o.id = p_org
  returning id into v_id;

  insert into invoice_lines
  select v_id, e.line_no, e.kind, e.project, e.name, e.quantity, e.unit, e.included, e.billable, e.unit_price, e.amount
  from expected_invoice(v_id) e;

  select coalesce(sum(amount), 0) into v_total from invoice_lines where invoice_id = v_id;
  update invoices
  set total = v_total,
      number = 'SB-' || to_char(p_issued, 'YYMM') || '-' || lpad(v_id::text, 4, '0'),
      paid_at = case when p_status = 'paid' then p_issued + interval '2 minutes' end
  where id = v_id;

  if p_status = 'paid' and v_total > 0 then
    insert into payment_attempts (invoice_id, payment_method_id, attempted_at, status, amount)
    select v_id, pm.id, p_issued + interval '2 minutes', 'succeeded', v_total
    from payment_methods pm where pm.org_id = p_org and pm.is_active;
  end if;
  return v_id;
end $$;

create function seed_failures(p_invoice bigint, p_code text, p_day_offsets integer[])
returns void language sql as $$
  insert into payment_attempts (invoice_id, payment_method_id, attempted_at, status, decline_code, amount)
  select i.id, pm.id, i.issued_at + make_interval(days => d, mins => 2), 'failed', p_code, i.total
  from invoices i
  join payment_methods pm on pm.org_id = i.org_id and pm.is_active
  cross join unnest(p_day_offsets) d
  where i.id = p_invoice;
$$;

-- ---------------------------------------------------------------------------
-- Organizations, one per scenario.
-- ---------------------------------------------------------------------------

insert into orgs (id, name, owner_name, billing_email, country, plan, spend_cap, tax_id, tax_rate, restriction_status, created_at) values
  ('lumen-health',    'Lumen Health',        'Amara Okafor',    'billing@lumenhealth.example',   'GB', 'pro',  true,  null, 0,    null,           '2025-06-01'),
  ('kestrel-maps',    'Kestrel Maps',        'Jonas Lindqvist', 'jonas@kestrelmaps.example',     'SE', 'pro',  true,  null, 0,    null,           '2025-09-01'),
  ('baobab-pay',      'Baobab Pay',          'Chidi Eze',       'finance@baobabpay.example',     'NG', 'pro',  true,  null, 0,    null,           '2026-02-10'),
  ('fjord-analytics', 'Fjord Analytics',     'Ingrid Solberg',  'ingrid@fjordanalytics.example', 'NO', 'pro',  true,  null, 0,    null,           '2024-11-10'),
  ('tidepool-games',  'Tidepool Games',      'Mateus Ferreira', 'mateus@tidepool.example',       'BR', 'pro',  false, null, 0,    null,           '2026-01-01'),
  ('quill-notes',     'Quill Notes',         'Hana Kobayashi',  'hana@quillnotes.example',       'JP', 'pro',  true,  null, 0,    null,           '2025-12-01'),
  ('harbor-crm',      'Harbor CRM',          'Tomasz Nowak',    'tomasz@harborcrm.example',      'PL', 'free', true,  null, 0,    null,           '2025-04-01'),
  ('mosaic-studio',   'Mosaic Studio',       'Leila Haddad',    'leila@mosaicstudio.example',    'FR', 'free', false, null, 0,    null,           '2026-03-01'),
  ('pixel-forge',     'Pixel Forge',         'Sofia Marin',     'sofia@pixelforge.example',      'RO', 'pro',  true,  null, 0,    null,           '2026-05-01'),
  ('orchard-iot',     'Orchard IoT',         'Kwame Mensah',    'kwame@orchardiot.example',      'GH', 'pro',  true,  null, 0,    null,           '2026-04-01'),
  ('nimbus-edu',      'Nimbus Education',    'Priya Raman',     'priya@nimbusedu.example',       'IN', 'pro',  true,  null, 0,    'grace_period', '2025-08-01'),
  ('vela-commerce',   'Vela Commerce',       'Katrin Bauer',    'buchhaltung@vela.example',      'DE', 'pro',  true,  null, 0.19, null,           '2026-06-01'),
  ('cobalt-robotics', 'Cobalt Robotics',     'Marcus Reed',     'ap@cobaltrobotics.example',     'US', 'team', false, null, 0,    null,           '2025-02-01'),
  ('sprout-journal',  'Sprout Journal',      'Nomvula Dlamini', 'nomvula@sproutjournal.example', 'ZA', 'free', false, null, 0,    null,           '2026-07-01'),
  ('atlas-freight',   'Atlas Freight',       'Diego Ramos',     'diego@atlasfreight.example',    'MX', 'pro',  true,  null, 0,    null,           '2026-08-01'),
  ('delta-sensor',    'Delta Sensor',        'Elif Yilmaz',     'elif@deltasensor.example',      'TR', 'pro',  true,  null, 0,    null,           '2026-01-10'),
  ('prairie-cu',      'Prairie Credit Union','Hannah Schultz',  'procurement@prairiecu.example', 'CA', 'pro',  true,  null, 0,    null,           '2026-10-01'),
  ('saffron-ai',      'Saffron AI',          'Arjun Mehta',     'arjun@saffronai.example',       'AE', 'pro',  false, null, 0,    null,           '2025-10-01'),
  ('umbra-video',     'Umbra Video',         'Lucia Romano',    'lucia@umbravideo.example',      'IT', 'pro',  true,  null, 0,    null,           '2025-11-10'),
  ('ember-labs',      'Ember Labs',          'Viktor Hale',     'viktor@emberlabs.example',      'US', 'pro',  false, null, 0,    null,           '2026-11-14');

insert into payment_methods (org_id, brand, last4, exp_month, exp_year, country) values
  ('lumen-health',    'Visa',       '4242', 8,  2028, 'GB'),
  ('kestrel-maps',    'Mastercard', '5510', 3,  2029, 'SE'),
  ('baobab-pay',      'Visa',       '4071', 6,  2028, 'NG'),
  ('fjord-analytics', 'Mastercard', '2291', 10, 2026, 'NO'),
  ('tidepool-games',  'Visa',       '9004', 1,  2028, 'BR'),
  ('quill-notes',     'JCB',        '3530', 12, 2027, 'JP'),
  ('harbor-crm',      'Visa',       '1881', 5,  2027, 'PL'),
  ('mosaic-studio',   'Visa',       '7712', 9,  2028, 'FR'),
  ('pixel-forge',     'Mastercard', '5454', 2,  2029, 'RO'),
  ('orchard-iot',     'Visa',       '0341', 4,  2028, 'GH'),
  ('nimbus-edu',      'Visa',       '6011', 7,  2028, 'IN'),
  ('vela-commerce',   'Mastercard', '8210', 11, 2028, 'DE'),
  ('cobalt-robotics', 'Amex',       '0005', 3,  2028, 'US'),
  ('atlas-freight',   'Visa',       '1117', 6,  2029, 'MX'),
  ('delta-sensor',    'Mastercard', '3305', 9,  2027, 'TR'),
  ('prairie-cu',      'Visa',       '2468', 12, 2028, 'CA'),
  ('saffron-ai',      'Visa',       '9090', 5,  2028, 'AE'),
  ('umbra-video',     'Mastercard', '7373', 8,  2027, 'IT'),
  ('ember-labs',      'Visa',       '0019', 1,  2027, 'US');

-- ---------------------------------------------------------------------------
-- Projects and a month of usage. Most cycles run 1 to 31 October. The
-- organizations with a failed payment bill on the 10th, so their invoice is
-- ten days old and their projects have not been paused yet.
-- ---------------------------------------------------------------------------

select seed_project('lumen-health',   'patient-portal', 'micro');
select seed_usage('lumen-health',   '{"egress": 41, "mau": 8200, "storage_size": 12}');

select seed_project('kestrel-maps',   'production', 'micro');
select seed_project('kestrel-maps',   'staging',    'micro');
select seed_project('kestrel-maps',   'tile-cache', 'micro');
select seed_usage('kestrel-maps',   '{"egress": 190, "mau": 31000}');

select seed_project('baobab-pay',     'payments-api', 'small', '2026-10-10');
select seed_usage('baobab-pay',     '{"egress": 88, "mau": 54000}', '2026-10-10');

select seed_project('fjord-analytics','warehouse', 'micro', '2026-10-10');
select seed_usage('fjord-analytics','{"egress": 23}', '2026-10-10');

select seed_project('tidepool-games', 'game-backend', 'medium');
select seed_usage('tidepool-games', '{"egress": 1900, "function_invocations": 14000000, "mau": 96000, "realtime_messages": 4100000}');

select seed_project('quill-notes',    'notes-prod', 'small', '2026-10-01', 744, 6, '{"ipv4": 744, "pitr_7": 744}');
select seed_usage('quill-notes',    '{"egress": 310, "mau": 12000}');

-- Harbor's unpaid invoice is for September. Its projects were paused for it.
select seed_project('harbor-crm',     'crm-prod',    'small', '2026-09-01', 720, null, '{}', 'paused', 'overdue_invoice');
select seed_project('harbor-crm',     'crm-staging', 'micro', '2026-09-01', 720, null, '{}', 'paused', 'overdue_invoice');
select seed_usage('harbor-crm',     '{"egress": 120, "mau": 4000}', '2026-09-01');

select seed_project('mosaic-studio',  'portfolio-api', 'small');
select seed_usage('mosaic-studio',  '{"egress": 180}');
-- 1 to 10 November, up to the downgrade: 228 hours of compute and a spike in egress.
insert into compute_usage select id, '2026-11-01', 'small', 228 from projects where org_id = 'mosaic-studio';
select seed_usage('mosaic-studio',  '{"egress": 600}', '2026-11-01');

select seed_project('pixel-forge',    'render-queue', 'micro');
select seed_usage('pixel-forge',    '{"egress": 60}');

select seed_project('orchard-iot',    'sensor-ingest', 'micro');
select seed_usage('orchard-iot',    '{"egress": 75, "realtime_messages": 1900000}');

select seed_project('nimbus-edu',     'classroom', 'small');
select seed_usage('nimbus-edu',     '{"egress": 140, "mau": 180000}');

select seed_project('vela-commerce',  'storefront', 'micro');
select seed_usage('vela-commerce',  '{"egress": 95, "mau": 22000}');

select seed_project('cobalt-robotics','fleet-telemetry', 'large');
select seed_project('cobalt-robotics','internal-tools',  'small');
select seed_usage('cobalt-robotics','{"egress": 210, "mau": 900, "mau_sso": 38}');

select seed_project('sprout-journal', 'journal', 'nano', '2026-10-01', 0, null, '{}', 'paused', 'inactivity');

select seed_project('atlas-freight',  'dispatch', 'micro');
select seed_usage('atlas-freight',  '{"egress": 30}');

select seed_project('delta-sensor',   'telemetry', 'micro', '2026-10-10');
select seed_usage('delta-sensor',   '{"egress": 52}', '2026-10-10');

select seed_project('prairie-cu',     'member-portal-pilot', 'micro');
select seed_usage('prairie-cu',     '{"egress": 4}');

select seed_project('saffron-ai',     'inference-app', 'small');
select seed_usage('saffron-ai',     '{"egress": 240, "mau": 104000, "realtime_peak_connections": 2600, "image_transformations": 4100}');

select seed_project('umbra-video',    'transcoder', 'small', '2026-10-10');
select seed_usage('umbra-video',    '{"egress": 201}', '2026-10-10');

-- Six days old, nothing ever paid, and a 16XL running.
select seed_project('ember-labs',     'batch-1', '16xl', '2026-11-14', 0);

-- ---------------------------------------------------------------------------
-- Invoices and how their payment went.
-- ---------------------------------------------------------------------------

select seed_invoice(o, '2026-10-01', '2026-10-31', '2026-11-01 00:10+00', 'paid')
from unnest(array['lumen-health', 'kestrel-maps', 'tidepool-games', 'quill-notes', 'orchard-iot', 'nimbus-edu',
                  'vela-commerce', 'cobalt-robotics', 'atlas-freight', 'prairie-cu', 'saffron-ai', 'pixel-forge']) o;

-- Failed payments on the 10 November invoices: one symptom, four causes.
select seed_failures(seed_invoice('baobab-pay',      '2026-10-10', '2026-11-09', '2026-11-10 00:10+00', 'open'), 'do_not_honor',            array[0, 3, 5]);
select seed_failures(seed_invoice('fjord-analytics', '2026-10-10', '2026-11-09', '2026-11-10 00:10+00', 'open'), 'expired_card',            array[0, 3, 5]);
select seed_failures(seed_invoice('delta-sensor',    '2026-10-10', '2026-11-09', '2026-11-10 00:10+00', 'open'), 'authentication_required', array[0, 3]);
select seed_failures(seed_invoice('umbra-video',     '2026-10-10', '2026-11-09', '2026-11-10 00:10+00', 'open'), 'insufficient_funds',      array[0, 3, 5, 7]);

-- Harbor CRM: the September invoice was never paid. After the retries ran
-- out, the projects were paused and the organization was moved to Free.
select seed_failures(seed_invoice('harbor-crm', '2026-09-01', '2026-09-30', '2026-10-01 00:10+00', 'open', 'pro'), 'insufficient_funds', array[0, 3, 5, 7]);
insert into plan_changes (org_id, changed_at, from_plan, to_plan, reason)
values ('harbor-crm', '2026-10-15 00:00+00', 'pro', 'free', 'overdue_invoice');

-- Mosaic Studio: a normal October invoice, then a downgrade on 10 November.
-- The downgrade returns the unused 20 of 30 days of the plan fee as credits,
-- and closes the cycle with an invoice for the usage up to that day.
select seed_invoice('mosaic-studio', '2026-10-01', '2026-10-31', '2026-11-01 00:10+00', 'paid', 'pro');
insert into plan_changes (org_id, changed_at, from_plan, to_plan, reason)
values ('mosaic-studio', '2026-11-10 09:00+00', 'pro', 'free', 'customer');
insert into credit_ledger (org_id, at, entry_type, amount, reason)
values ('mosaic-studio', '2026-11-10 08:59+00', 'increment', round(25 * 20 / 30.0, 2), 'Unused time on the Pro Plan after downgrade');
select seed_invoice('mosaic-studio', '2026-11-01', '2026-11-10', '2026-11-10 09:00+00', 'paid', 'pro', 'free');
insert into credit_ledger (org_id, at, entry_type, amount, reason, invoice_id)
select i.org_id, i.issued_at, 'decrement', -l.amount, 'Applied to invoice ' || i.number, i.id
from invoices i join invoice_lines l on l.invoice_id = i.id and l.kind = 'credits'
where i.org_id = 'mosaic-studio';

-- Planted billing error 1: Pixel Forge was charged twice for one invoice.
insert into payment_attempts (invoice_id, payment_method_id, attempted_at, status, amount)
select a.invoice_id, a.payment_method_id, a.attempted_at + interval '3 minutes', 'succeeded', a.amount
from payment_attempts a join invoices i on i.id = a.invoice_id
where i.org_id = 'pixel-forge';

-- Planted billing error 2: Orchard IoT's invoice lost its compute credits.
delete from invoice_lines l using invoices i
where i.id = l.invoice_id and i.org_id = 'orchard-iot' and l.kind = 'compute_credits';
update invoices i set total = (select sum(amount) from invoice_lines where invoice_id = i.id)
where i.org_id = 'orchard-iot';
update payment_attempts a set amount = i.total from invoices i
where i.id = a.invoice_id and i.org_id = 'orchard-iot';

-- Cobalt Robotics: accounts payable disputed the charge with their bank.
insert into disputes (invoice_id, opened_at, reason, status, amount, evidence_due_by)
select id, '2026-11-12 14:00+00', 'unrecognized', 'needs_response', total, '2026-11-26 23:59+00'
from invoices where org_id = 'cobalt-robotics';

-- ---------------------------------------------------------------------------
-- The inbox: open tickets, written the way customers write them.
-- ---------------------------------------------------------------------------

insert into tickets (org_id, requester_name, category, severity, subject, body, created_at) values
  ('harbor-crm', 'Tomasz Nowak', 'Billing', 'Urgent', 'Production database is paused, we are down',
   'Our CRM stopped working this morning and the dashboard says both projects are paused. We did not pause anything. We have customers who cannot log in. Please restore them now, this is costing us money every hour.',
   '2026-11-20 07:40+00'),
  ('baobab-pay', 'Chidi Eze', 'Billing', 'High', 'Payment keeps failing but my card works everywhere else',
   'I got three emails saying my payment failed. I use this same card for AWS and for everything else with no problem and there is money in the account. Is something wrong on your side? I do not want my project paused.',
   '2026-11-20 06:45+00'),
  ('pixel-forge', 'Sofia Marin', 'Refund enquiry', 'High', 'Charged twice for October',
   'My bank statement shows two charges of $25.00 from Supabase on 1 November. I only have one organization and one project. Please refund the duplicate.',
   '2026-11-20 07:30+00'),
  ('tidepool-games', 'Mateus Ferreira', 'Billing', 'High', 'Invoice of $248 on a $25 plan??',
   'I am on the Pro plan which is $25 a month. I just saw that you charged my card $248.66. Nobody warned me. This is ten times what I signed up for. I want an explanation and I want this fixed.',
   '2026-11-19 22:10+00'),
  ('cobalt-robotics', 'Dana Whitfield', 'Refund enquiry', 'Normal', 'Refund request for charge we do not recognise',
   'I work in accounts payable at Cobalt Robotics. There is a charge of $717.19 from SUPABASE on our company card that nobody here could match to a purchase order. Please refund it.',
   '2026-11-19 16:40+00'),
  ('fjord-analytics', 'Ingrid Solberg', 'Billing', 'Normal', 'Payment failed email',
   'Hi, I received an email that my payment failed. Nothing has changed on my side. Can you check what happened?',
   '2026-11-19 14:05+00'),
  ('orchard-iot', 'Kwame Mensah', 'Billing', 'Normal', 'Why was I charged $35?',
   'I have one small project on Pro. My understanding from your pricing page is that this costs $25 a month. My invoice for October was $35. What is the extra $10 for?',
   '2026-11-19 11:30+00'),
  ('quill-notes', 'Hana Kobayashi', 'Billing', 'Normal', 'Spend cap is on but I was charged $136',
   'I turned the spend cap on specifically so I would never pay more than the plan price. My invoice is $136.35. How is that possible with the cap enabled? Is the cap broken?',
   '2026-11-19 09:15+00'),
  ('mosaic-studio', 'Leila Haddad', 'Billing', 'Normal', 'I downgraded and you charged me again',
   'I downgraded to the free plan on 10 November because the project is finished. The same day my card was charged $14.83. Why am I paying for a plan I just cancelled?',
   '2026-11-19 08:50+00'),
  ('nimbus-edu', 'Priya Raman', 'Billing', 'High', 'Emails saying we exceeded our quota',
   'We keep getting emails that our organization exceeded its quota and may be restricted. We have exams running next week and cannot have students locked out. What do we need to do? We have the spend cap on so I thought we were covered.',
   '2026-11-20 05:10+00'),
  ('kestrel-maps', 'Jonas Lindqvist', 'Billing', 'Low', 'Invoice is $45 but Pro is $25',
   'Small thing, but my invoice has been $45 for the last few months and the Pro plan is listed at $25. Am I on the wrong plan?',
   '2026-11-18 15:00+00'),
  ('vela-commerce', 'Katrin Bauer', 'Billing', 'Normal', 'Please add our VAT number to the November invoice',
   'Our accountant needs the invoice from 1 November to show our VAT ID DE811907980 and to be issued without VAT. Can you correct the invoice and send it again?',
   '2026-11-19 10:20+00'),
  ('atlas-freight', 'Diego Ramos', 'Refund enquiry', 'Normal', 'Forgot to cancel, please refund November',
   'We stopped using the project in October and I forgot to cancel. I was charged $25 on 1 November. Can I get my money back?',
   '2026-11-19 13:45+00'),
  ('delta-sensor', 'Elif Yilmaz', 'Billing', 'Normal', 'Card declined twice',
   'Your system says my card was declined two times. The card is new and it works in shops. My bank app shows no attempt from you at all.',
   '2026-11-19 17:25+00'),
  ('umbra-video', 'Lucia Romano', 'Billing', 'Normal', 'Payment failed, what now?',
   'I saw the payment failed notice. We are between funding rounds and the company card is low until next week. What happens to our project in the meantime?',
   '2026-11-19 12:00+00'),
  ('saffron-ai', 'Arjun Mehta', 'Billing', 'Normal', 'Unexpected charge this month',
   'My bill went up a lot this month compared to September and I have not changed anything. Can you tell me what the charge is for?',
   '2026-11-18 19:30+00'),
  ('sprout-journal', 'Nomvula Dlamini', 'Billing', 'Normal', 'My project is paused, did my payment fail?',
   'I opened my app and it says it cannot connect. The dashboard shows the project as paused. I do not remember getting a bill. Do I owe you something?',
   '2026-11-19 18:10+00'),
  ('lumen-health', 'Amara Okafor', 'Sales enquiry', 'Low', 'Can we pay annually?',
   'Our finance team prefers yearly billing so we have one invoice instead of twelve. Do you offer an annual plan for Pro?',
   '2026-11-18 09:00+00'),
  ('prairie-cu', 'Hannah Schultz', 'Sales enquiry', 'Normal', 'Paying upfront by bank transfer against a purchase order',
   'We are a credit union finishing a pilot. Procurement rules mean we cannot put recurring charges on a card. We expect to spend about $30,000 over the next year and would need to pay by bank transfer against a purchase order. Is that possible?',
   '2026-11-19 15:20+00'),
  ('lumen-health', 'Amara Okafor', 'Billing', 'Low', 'Change the email our invoices go to',
   'Could invoices go to accounts@lumenhealth.example from now on instead of my address? I could not find where to change it.',
   '2026-11-19 09:40+00');

-- Each ticket about a specific invoice points at it.
update tickets t
set invoice_id = (select i.id from invoices i where i.org_id = t.org_id order by i.issued_at desc limit 1)
where t.status = 'open' and t.category <> 'Sales enquiry';

-- ---------------------------------------------------------------------------
-- History for the patterns page: 12 weeks of solved tickets across thirty
-- more organizations. Counts are arithmetic on the row number, not random(),
-- so every run of this file produces the same rows.
-- ---------------------------------------------------------------------------

insert into orgs (id, name, owner_name, billing_email, country, plan, spend_cap, tax_rate, created_at)
select 'history-' || lpad(n::text, 2, '0'),
       (array['Northwind', 'Juniper', 'Copperline', 'Bluejay', 'Tamarind', 'Halcyon', 'Sandbar', 'Ironwood', 'Marigold', 'Lantern'])[1 + n % 10]
         || ' ' || (array['Labs', 'Systems', 'Health', 'Logistics', 'Studio', 'Learning'])[1 + n % 6],
       (array['Ada Obi', 'Ben Carter', 'Chloe Martin', 'Dev Patel', 'Emeka Nwosu', 'Farah Aziz', 'Goran Petrov', 'Hui Min Tan'])[1 + n % 8],
       'billing@history-' || lpad(n::text, 2, '0') || '.example',
       (array['US', 'GB', 'DE', 'NG', 'IN', 'BR', 'FR', 'KE', 'NL', 'ZA'])[1 + n % 10],
       'pro', n % 3 <> 0, 0, timestamptz '2025-01-01' + make_interval(days => n * 11)
from generate_series(1, 30) n;

with weights (playbook, upto, subject) as (values
  ('bank_block',          16, 'Card declined but it works elsewhere'),
  ('extra_projects',      30, 'Why is my invoice more than $25?'),
  ('expired_card',        42, 'Payment failed'),
  ('usage_overage',       53, 'Unexpectedly high invoice'),
  ('payment_declined',    62, 'Payment did not go through'),
  ('refund_policy',       71, 'Refund request'),
  ('downgrade_charge',    78, 'Charged after downgrading'),
  ('addons_with_cap',     83, 'Charged with the spend cap on'),
  ('overdue_paused',      88, 'Projects paused'),
  ('free_project_paused', 91, 'Free project paused'),
  ('quota_restriction',   94, 'Quota warning emails'),
  ('tax_id_missing',      96, 'VAT on my invoice'),
  ('pre_sales',           98, 'Annual billing?'),
  ('dispute_open',        99, 'Charge not recognised'),
  ('duplicate_charge',   100, 'Charged twice')
),
rows as (
  select n, (n * 37) % 100 as roll,
         timestamptz '2026-08-24 08:00+00'
           + make_interval(days => ((n * 7) % 12) * 7 + (n * 11) % 7, hours => (n * 5) % 10, mins => (n * 13) % 60) as created_at
  from generate_series(1, 300) n
)
insert into tickets (org_id, requester_name, category, severity, subject, body, status, created_at,
                     first_response_at, solved_at, solved_by_playbook, escalated)
select 'history-' || lpad((1 + r.n % 30)::text, 2, '0'),
       (array['Ada Obi', 'Ben Carter', 'Chloe Martin', 'Dev Patel', 'Emeka Nwosu', 'Farah Aziz', 'Goran Petrov', 'Hui Min Tan'])[1 + r.n % 8],
       case w.playbook when 'refund_policy' then 'Refund enquiry' when 'pre_sales' then 'Sales enquiry' else 'Billing' end,
       (array['Normal', 'Normal', 'Normal', 'High', 'Low', 'Normal', 'High', 'Urgent'])[1 + r.n % 8],
       w.subject, 'Solved ticket from the demo history.', 'solved', r.created_at,
       r.created_at + make_interval(mins => 6 + (r.n * 29) % 170),
       r.created_at + make_interval(mins => 30 + (r.n * 41) % 900),
       w.playbook,
       w.playbook in ('dispute_open', 'duplicate_charge')
from rows r
join lateral (select * from weights w where r.roll < w.upto order by w.upto limit 1) w on true;

-- The pattern worth noticing: tax questions climb after tax collection began.
insert into tickets (org_id, requester_name, category, severity, subject, body, status, created_at,
                     first_response_at, solved_at, solved_by_playbook)
select 'history-' || lpad((1 + n % 30)::text, 2, '0'), 'Farah Aziz', 'Billing', 'Normal',
       'VAT on my invoice', 'Solved ticket from the demo history.', 'solved', c.created_at,
       c.created_at + make_interval(mins => 20 + n * 3), c.created_at + make_interval(mins => 120 + n * 7), 'tax_id_missing'
from generate_series(1, 30) n
cross join lateral (
  -- weeks 7 to 12, more tickets each week
  select timestamptz '2026-08-24 09:00+00'
         + make_interval(days => (case when n <= 2 then 6 when n <= 5 then 7 when n <= 9 then 8 when n <= 15 then 9 when n <= 22 then 10 else 11 end) * 7 + n % 5,
                         hours => n % 8) as created_at
) c;

drop function seed_project(text, text, text, date, numeric, numeric, jsonb, text, text);
drop function seed_usage(text, jsonb, date);
drop function seed_invoice(text, date, date, timestamptz, text, text, text);
drop function seed_failures(bigint, text, integer[]);

commit;
