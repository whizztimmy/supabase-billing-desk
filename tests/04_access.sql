-- Access: what a visitor's browser can do with the public anon key.
-- It can read the synthetic data and run the read-only functions. It cannot
-- write anything.

do $$
declare
  v_tickets integer; v_findings integer; v_lines integer;
  v_insert_denied boolean := false; v_update_denied boolean := false; v_delete_denied boolean := false;
  v_clock_denied boolean := false;
begin
  set role anon;

  select count(*) into v_tickets from ticket_queue;
  select count(*) into v_findings from diagnose_ticket((select min(id) from tickets));
  select count(*) into v_lines from quote_invoice('pro', true, '[{"size":"micro"}]');

  begin
    insert into credit_ledger (org_id, at, entry_type, amount, reason)
    values ('lumen-health', now(), 'increment', 1000, 'free money');
  exception when insufficient_privilege then v_insert_denied := true;
  end;

  begin
    update invoices set status = 'void';
  exception when insufficient_privilege then v_update_denied := true;
  end;

  begin
    delete from tickets;
  exception when insufficient_privilege then v_delete_denied := true;
  end;

  begin
    perform advance_demo_clock(date '2099-01-01');
  exception when insufficient_privilege then v_clock_denied := true;
  end;

  reset role;

  perform expect_true('anon cannot move the demo clock', v_clock_denied);
  perform expect_true('anon can read the inbox', v_tickets > 0);
  perform expect_true('anon can run a diagnosis', v_findings > 0);
  perform expect_true('anon can use the invoice explainer', v_lines > 0);
  perform expect_true('anon cannot give an organization credits', v_insert_denied);
  perform expect_true('anon cannot void invoices', v_update_denied);
  perform expect_true('anon cannot delete tickets', v_delete_denied);
end $$;

select expect_true('Row level security is on for every table',
  (select bool_and(c.relrowsecurity) from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'test_results'));

select expect_true('Every view runs with the caller''s rights, so it cannot bypass row level security',
  (select bool_and(coalesce(c.reloptions::text, '') like '%security_invoker=true%') from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'));

select expect_true('No function runs with its owner''s rights',
  (select not bool_or(p.prosecdef) from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'));

select expect_true('No text shown to a customer contains an em dash',
  (select not exists (select 1 from tickets t cross join lateral diagnose_ticket(t.id) d
                      where t.status = 'open' and (d.reply like '%' || chr(8212) || '%' or d.cause like '%' || chr(8212) || '%'))));
