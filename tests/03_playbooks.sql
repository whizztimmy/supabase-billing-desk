-- The playbooks: every ticket in the inbox gets the cause that is really
-- present in its account, including the four that all say "payment failed".

create function top_playbook(p_org text, p_subject_like text default '%') returns text language sql as $$
  select d.playbook
  from tickets t cross join lateral diagnose_ticket(t.id) d
  where t.org_id = p_org and t.status = 'open' and t.subject ilike p_subject_like
  order by t.id, d.rank limit 1;
$$;

-- One symptom, four causes
select expect_eq('Payment failed, card issued in Nigeria, do_not_honor: the bank is blocking it', top_playbook('baobab-pay'),      'bank_block');
select expect_eq('Payment failed, card expired last month',                                       top_playbook('fjord-analytics'), 'expired_card');
select expect_eq('Payment failed, bank wants 3D Secure approval',                                 top_playbook('delta-sensor'),    'payment_declined');
select expect_eq('Payment failed, insufficient funds',                                            top_playbook('umbra-video'),     'payment_declined');

-- "My project is paused": two causes
select expect_eq('Paused for an unpaid invoice: only payment restores it', top_playbook('harbor-crm'),     'overdue_paused');
select expect_eq('Paused on Free for inactivity: nothing is owed',         top_playbook('sprout-journal'), 'free_project_paused');

-- "Why is my invoice so high?": four causes
select expect_eq('More than one project',                          top_playbook('kestrel-maps'),   'extra_projects');
select expect_eq('Usage over quota with the cap off',              top_playbook('tidepool-games'), 'usage_overage');
select expect_eq('Add-ons, which the cap does not cover',          top_playbook('quill-notes'),    'addons_with_cap');
select expect_eq('The invoice itself is wrong',                    top_playbook('orchard-iot'),    'invoice_mismatch');

-- Refunds: three different situations
select expect_eq('Refund asked, charged twice: a billing error, not a refund',        top_playbook('pixel-forge'),     'duplicate_charge');
select expect_eq('Refund asked, bank dispute already open: hold',                     top_playbook('cobalt-robotics'), 'dispute_open');
select expect_eq('Refund asked, invoice correct: policy answer with the credit amount', top_playbook('atlas-freight'), 'refund_policy');

-- The rest
select expect_eq('Charged after a downgrade',             top_playbook('mosaic-studio'), 'downgrade_charge');
select expect_eq('Quota warnings with the cap on',        top_playbook('nimbus-edu'),    'quota_restriction');
select expect_eq('VAT number on an issued invoice',       top_playbook('vela-commerce'), 'tax_id_missing');
select expect_eq('Annual billing question',               top_playbook('lumen-health', '%annual%'), 'pre_sales');
select expect_eq('Bank transfer for $30,000 goes to the growth team',
  (select d.escalate_to from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'prairie-cu' limit 1), 'Growth team');

select expect_eq('A ticket no playbook covers says so, and does not force a match',
  top_playbook('lumen-health', '%email%'), 'needs_review');

-- What the findings say
select expect_eq('A customer with paused production gets one finding, not a breakdown of the bill',
  (select count(*)::integer from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'harbor-crm'), 1);

select expect_true('The quota reply prices the choice: 80,000 users over quota would have cost $260.00',
  (select d.reply like '%would have added $260.00%'
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'nimbus-edu' limit 1));

select expect_true('The wrong-invoice reply names the error in plain words',
  (select d.reply like '%the Compute Credits line of -$10.00 is missing%'
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'orchard-iot' limit 1));

select expect_true('The bank-block reply names the country, not its code',
  (select d.cause like '%issued in Nigeria%'
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'baobab-pay' limit 1));

select expect_eq('"Card declined twice" is a failed payment, not a duplicate charge',
  (select topic from ticket_queue where org_id = 'delta-sensor'), 'failed payment');

-- What a playbook is allowed to read. The cause comes from the account. Only
-- these playbooks also look at what the customer is asking for.
select expect_eq('Only the tax and pre-sales playbooks read the customer''s wording',
  (select string_agg(id, ', ' order by id) from playbook_source where sql ~ 'c\.(topic|subject|body)'),
  'pre_sales, tax_id_missing');

select expect_eq('Only the pre-sales and refund playbooks use the form''s category',
  (select string_agg(id, ', ' order by id) from playbook_source where sql ~ 'c\.category'),
  'pre_sales, refund_policy');

-- Guard rails
select expect_true('The no-refund policy answer never fires on a ticket with a real billing error',
  not exists (select 1 from tickets t cross join lateral diagnose_ticket(t.id) d
              where t.org_id in ('pixel-forge', 'cobalt-robotics') and d.playbook = 'refund_policy'));

select expect_eq('Exactly three open tickets go to Billing Engineering',
  (select count(*)::integer from ticket_queue where escalate_to = 'Billing Engineering'), 3);

select expect_true('An escalation note exists for every escalated ticket and for no other',
  (select bool_and((escalation_note(q.id) is not null) = (q.escalate_to is not null)) from ticket_queue q));

select expect_true('The duplicate-charge note carries the invoice number and the amount to reverse',
  (select escalation_note(t.id) ~ 'SB-2611-[0-9]{4}' and escalation_note(t.id) like '%$50.00%'
   from tickets t where t.org_id = 'pixel-forge'));

select expect_true('Every drafted reply greets the requester by first name',
  (select bool_and(d.reply like 'Hi ' || split_part(t.requester_name, ' ', 1) || ',%')
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.status = 'open' and d.reply is not null));

select expect_true('The refund reply says no in its first sentence',
  (select d.reply ~ '^Hi Diego,\s+I cannot refund'
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.org_id = 'atlas-freight' limit 1));

select expect_true('No reply leaves a blank where a value should be',
  (select bool_and(d.reply !~ '(\$\s|\(\)|  )' and d.cause !~ '(\(\)|  )')
   from tickets t cross join lateral diagnose_ticket(t.id) d where t.status = 'open' and d.reply is not null));

select expect_eq('Every playbook has its SQL on show',
  (select count(*)::integer from playbook_source where sql like '%ticket_context%'), (select count(*)::integer from playbooks));

select expect_eq('Every playbook in the history exists in the catalogue',
  (select count(*)::integer from tickets t where t.solved_by_playbook is not null
     and not exists (select 1 from playbooks p where p.id = t.solved_by_playbook)), 0);

select expect_eq('The inbox holds all 20 open tickets', (select count(*)::integer from ticket_queue), 20);

select expect_eq('The urgent ticket is past its one-hour reply target',
  (select sla_state from ticket_queue where org_id = 'harbor-crm'), 'overdue');

drop function top_playbook(text, text);
