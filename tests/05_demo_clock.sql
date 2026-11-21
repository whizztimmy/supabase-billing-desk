-- The demo clock. Moving it forward must change the calendar and nothing
-- else: every diagnosis, total, age and trend has to come out the same.
--
-- This file runs last, because it moves the dates the earlier files rely on.

create temp table before_move as
select
  (select string_agg(q.id || ':' || q.playbook || ':' || q.sla_state || ':' || q.hours_waiting, ',' order by q.id) from ticket_queue q) as queue,
  (select string_agg(i.id || ':' || i.total || ':' || coalesce(i.days_overdue::text, '-') || ':' || i.failed_attempts, ',' order by i.id) from invoice_overview i) as invoices,
  (select string_agg(i.org_id, ',') from invoices i cross join lateral invoice_check(i.id) k where not k.matches) as mismatched,
  (select string_agg(w.playbook || ':' || w.tickets, ',' order by w.week_start, w.playbook) from tickets_weekly w) as weekly,
  (select string_agg(c.ticket_id || ':' || coalesce(c.card_expired::text, '-'), ',' order by c.ticket_id) from ticket_context c) as cards,
  (select string_agg(s.org_id || ':' || s.age_days, ',') from spend_spike_signals s) as signals,
  (select string_agg(i.id || ':' || (i.usage_period_end - i.usage_period_start), ',' order by i.id) from invoices i) as period_lengths,
  (select balance from credit_balances where org_id = 'mosaic-studio') as mosaic_credits;

-- 107 days on: across a year end and a February.
select expect_eq('Advancing from 20 November 2026 to 7 March 2027 moves 107 days',
  advance_demo_clock(date '2027-03-07'), 107);

select expect_eq('The demo clock now reads 09:00 UTC on the new day',
  demo_now(), timestamptz '2027-03-07 09:00:00+00');

create temp table after_move as
select
  (select string_agg(q.id || ':' || q.playbook || ':' || q.sla_state || ':' || q.hours_waiting, ',' order by q.id) from ticket_queue q) as queue,
  (select string_agg(i.id || ':' || i.total || ':' || coalesce(i.days_overdue::text, '-') || ':' || i.failed_attempts, ',' order by i.id) from invoice_overview i) as invoices,
  (select string_agg(i.org_id, ',') from invoices i cross join lateral invoice_check(i.id) k where not k.matches) as mismatched,
  (select string_agg(w.playbook || ':' || w.tickets, ',' order by w.week_start, w.playbook) from tickets_weekly w) as weekly,
  (select string_agg(c.ticket_id || ':' || coalesce(c.card_expired::text, '-'), ',' order by c.ticket_id) from ticket_context c) as cards,
  (select string_agg(s.org_id || ':' || s.age_days, ',') from spend_spike_signals s) as signals,
  (select string_agg(i.id || ':' || (i.usage_period_end - i.usage_period_start), ',' order by i.id) from invoices i) as period_lengths,
  (select balance from credit_balances where org_id = 'mosaic-studio') as mosaic_credits;

select expect_true('Every ticket keeps its diagnosis, its reply deadline state and its age',
  (select b.queue = a.queue from before_move b, after_move a));
select expect_true('Every invoice keeps its total, its days overdue and its failed charges',
  (select b.invoices = a.invoices from before_move b, after_move a));
select expect_true('The one wrong invoice is still the only wrong invoice',
  (select b.mismatched = a.mismatched and a.mismatched = 'orchard-iot' from before_move b, after_move a));
select expect_true('The weekly trend has the same shape',
  (select b.weekly = a.weekly from before_move b, after_move a));
select expect_true('The expired card is still the only expired card',
  (select b.cards = a.cards from before_move b, after_move a));
select expect_true('The spend signal is unchanged',
  (select b.signals = a.signals from before_move b, after_move a));
select expect_true('Every usage period keeps its length',
  (select b.period_lengths = a.period_lengths from before_move b, after_move a));
select expect_true('Credit balances are untouched',
  (select b.mosaic_credits = a.mosaic_credits from before_move b, after_move a));

select expect_eq('The urgent ticket was received on the new day',
  (select created_at::date from tickets where org_id = 'harbor-crm' and status = 'open'), date '2027-03-07');

select expect_eq('Running it again for the same day moves nothing', advance_demo_clock(date '2027-03-07'), 0);
select expect_eq('It never moves backwards', advance_demo_clock(date '2026-01-01'), 0);
select expect_eq('A missed night is made up: two days later it moves two days', advance_demo_clock(date '2027-03-09'), 2);

drop table before_move, after_move;
