-- Development only: removes everything this project creates, so the
-- migrations and the seed can be run again from nothing. It drops objects by
-- name and never touches the schema itself, so Supabase's own grants and
-- extensions in `public` stay as they were.

begin;

-- The nightly clock job, where pg_cron is installed.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'advance-demo-clock';
  end if;
end $$;

drop view if exists spend_spike_signals, tickets_weekly, playbook_stats, ticket_queue,
                    playbook_source, ticket_context, invoice_overview, credit_balances cascade;

drop function if exists advance_demo_clock(date), escalation_note(bigint), diagnose_ticket(bigint),
  pb_duplicate_charge(bigint), pb_invoice_mismatch(bigint), pb_dispute_open(bigint),
  pb_overdue_paused(bigint), pb_free_project_paused(bigint), pb_expired_card(bigint),
  pb_bank_block(bigint), pb_payment_declined(bigint), pb_quota_restriction(bigint),
  pb_downgrade_charge(bigint), pb_tax_id_missing(bigint), pb_extra_projects(bigint),
  pb_usage_overage(bigint), pb_addons_with_cap(bigint), pb_pre_sales(bigint), pb_refund_policy(bigint),
  ev(text, text), ticket_topic(text, text),
  invoice_check(bigint), explain_invoice(bigint), expected_invoice(bigint), invoice_inputs(text, date),
  quote_invoice(text, boolean, jsonb, jsonb, numeric, text, numeric),
  invoice_status_label(text), country_name(text), usd(numeric), qty(numeric), demo_now() cascade;

drop type if exists finding cascade;

drop table if exists playbooks, tickets, disputes, credit_ledger, payment_attempts, invoice_lines, invoices,
                     usage, addon_usage, compute_usage, payment_methods, plan_changes, projects, orgs,
                     demo_settings, decline_codes, addons, usage_metrics, compute_sizes, plans cascade;

commit;
