-- 0005: a demo clock that follows the real date.
--
-- The seed is written around one moment, 09:00 UTC on 20 November 2026. Left
-- there, the demo would age: a visitor in January would read "today is 20
-- November", and an invoice ten days overdue would look sixty days overdue
-- against the real calendar.
--
-- advance_demo_clock() moves that moment to 09:00 UTC today, and moves every
-- date in the data forward by the same number of days. Nothing changes
-- relative to anything else: the urgent ticket is still 80 minutes old, the
-- failed payment is still ten days old, the expired card still expired the
-- month before its invoice. Only the calendar they sit on moves.
--
-- pg_cron runs it shortly after midnight UTC. If a night is missed, the next
-- run covers the gap, because the distance is worked out from the stored
-- clock and not assumed to be one day.

begin;

create function advance_demo_clock(p_today date default current_date) returns integer
language plpgsql security invoker set search_path = public, pg_catalog as $$
declare
  v_days integer;
  v_step interval;
  c      record;
begin
  select p_today - (value::timestamptz at time zone 'UTC')::date into v_days
  from demo_settings where key = 'demo_now' for update;

  -- Forward only. Running it twice in a day, or with an earlier date, does nothing.
  if v_days is null or v_days <= 0 then return 0; end if;
  v_step := make_interval(days => v_days);

  for c in
    select * from (values
      ('orgs', 'created_at'), ('projects', 'created_at'), ('plan_changes', 'changed_at'),
      ('payment_methods', 'expires_on'),
      ('invoices', 'usage_period_start'), ('invoices', 'usage_period_end'),
      ('invoices', 'issued_at'), ('invoices', 'due_at'), ('invoices', 'paid_at'),
      ('payment_attempts', 'attempted_at'), ('credit_ledger', 'at'),
      ('disputes', 'opened_at'), ('disputes', 'evidence_due_by'),
      ('tickets', 'created_at'), ('tickets', 'first_response_at'), ('tickets', 'solved_at')
    ) as cols(tbl, col)
  loop
    execute format('update %I set %I = %I + $1 where %I is not null', c.tbl, c.col, c.col, c.col) using v_step;
  end loop;

  -- period_start is part of a key in these tables. Moving every row by, say,
  -- 31 days would land one row on another's old value before that row had
  -- moved. So each row first jumps far out of the way, then comes back.
  for c in select * from (values ('compute_usage'), ('addon_usage'), ('usage')) as t(tbl) loop
    execute format('update %I set period_start = period_start + $1', c.tbl) using v_days + 100000;
    execute format('update %I set period_start = period_start - 100000', c.tbl);
  end loop;

  update demo_settings
  set value = to_char((value::timestamptz + v_step) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00'
  where key = 'demo_now';

  return v_days;
end $$;

comment on function advance_demo_clock(date) is
  'Moves the demo clock, and every date in the data, forward to the given day. Returns the number of days moved.';

-- This is the one function here that writes. It runs as the caller, and the
-- API roles have no write access to the tables, so it could not change
-- anything for them anyway. It is still not theirs to call.
revoke execute on function advance_demo_clock(date) from public, anon, authenticated;

-- Schedule it where pg_cron exists (a Supabase project). The tests run in
-- PGlite, which has no pg_cron, and call the function directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'advance-demo-clock';
    perform cron.schedule('advance-demo-clock', '5 0 * * *', 'select public.advance_demo_clock()');
  end if;
exception when others then
  -- A missing schedule must not block the migration: the clock can still be
  -- advanced by hand, and the reason is worth reading.
  raise notice 'pg_cron schedule not created: %', sqlerrm;
end $$;

commit;
