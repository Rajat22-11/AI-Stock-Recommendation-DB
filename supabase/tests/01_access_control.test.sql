-- Access control (access-control spec): public read, privileged write, privileged ledger.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(17);

-- Row-level security on every table
select is(
  (select array_agg(relname::text order by relname) from pg_class
    where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity),
  null,
  'every public table has row-level security enabled');

-- Public read access: a permissive SELECT policy using (true) reaching anon and authenticated
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
      and not exists (select 1 from pg_policies p
                       where p.schemaname = 'public' and p.tablename = c.relname
                         and p.permissive = 'PERMISSIVE' and p.cmd in ('SELECT', 'ALL') and p.qual = 'true'
                         and p.roles && array['anon', 'public']::name[]
                         and p.roles && array['authenticated', 'public']::name[])),
  null,
  'every public table has a permissive SELECT policy using (true) for anon and authenticated');

select is(
  (select array_agg(r || ' ' || c.relname order by r, c.relname) from pg_class c
     cross join unnest(array['anon', 'authenticated']) r
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')
      and not has_table_privilege(r, c.oid, 'SELECT')),
  null,
  'anon and authenticated can SELECT every public table and view');

-- No public writes
select is(
  (select array_agg(r || ' ' || pr || ' ' || c.relname order by r, pr, c.relname) from pg_class c
     cross join unnest(array['anon', 'authenticated']) r
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) pr
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')
      and has_table_privilege(r, c.oid, pr)),
  null,
  'anon and authenticated hold no INSERT/UPDATE/DELETE/TRUNCATE on any public table or view');

-- Function execute rights
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  array['block_signal_mutation', 'cfg_num']::text[],
  'only cfg_num and block_signal_mutation are executable by anon/authenticated');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and has_function_privilege('service_role', p.oid, 'EXECUTE')),
  array['_ledger_manage', '_ledger_pending', '_ledger_sell', 'block_signal_mutation', 'cfg_num', 'process_ledger']::text[],
  'service_role can execute every public function, including ledger processing');

-- Fixed search_path on every function
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and not coalesce('search_path=public' = any(p.proconfig), false)),
  null,
  'every public function sets search_path = public');

-- Behaviour as anon. pgTAP cannot run as anon, so each probe runs as anon inside a block,
-- records its outcome in a transaction-local setting, and the assertion runs as the owner.
insert into public.skill_versions(version, effective_from) values ('2026-01-01-acctest0', '2026-01-01');
insert into public.signals(symbol, signal_date, source, verdict, skill_version)
values ('ACCTEST', '2026-01-02', 'adhoc', 'WAIT', '2026-01-01-acctest0');

set local role anon;
do $$
declare n bigint;
begin
  select count(*) into n from public.signals where symbol = 'ACCTEST';
  perform set_config('t.anon_signals', n::text, true);
  select count(*) into n from public.v_suggestions;
  perform set_config('t.anon_view', 'ok', true);
  begin
    insert into public.price_bars(symbol, bar_date, open, high, low, close) values ('ACCTEST', '2026-01-02', 1, 1, 1, 1);
    perform set_config('t.anon_insert', 'succeeded', true);
  exception when others then perform set_config('t.anon_insert', sqlstate, true);
  end;
  begin
    update public.config set value = '0' where key = 'paper_capital';
    perform set_config('t.anon_update', 'succeeded', true);
  exception when others then perform set_config('t.anon_update', sqlstate, true);
  end;
  begin
    perform public.process_ledger('2026-01-02');
    perform set_config('t.anon_ledger', 'succeeded', true);
  exception when others then perform set_config('t.anon_ledger', sqlstate, true);
  end;
  begin
    perform public.cfg_num('paper_capital');
    perform set_config('t.anon_cfg', 'ok', true);
  exception when others then perform set_config('t.anon_cfg', sqlstate, true);
  end;
end $$;
reset role;

set local role authenticated;
do $$
begin
  begin
    delete from public.signals where symbol = 'ACCTEST';
    perform set_config('t.auth_delete', 'succeeded', true);
  exception when others then perform set_config('t.auth_delete', sqlstate, true);
  end;
end $$;
reset role;

select is(current_setting('t.anon_signals'), '1', 'anon reads all rows of a table (signals)');
select is(current_setting('t.anon_view'), 'ok', 'anon can query a contract view (v_suggestions)');
select is(current_setting('t.anon_insert'), '42501', 'anon INSERT into price_bars fails with insufficient_privilege');
select is(current_setting('t.anon_update'), '42501', 'anon UPDATE of config fails with insufficient_privilege');
select is(current_setting('t.anon_ledger'), '42501', 'anon cannot run ledger processing');
select is(current_setting('t.anon_cfg'), 'ok', 'anon can use the numeric config lookup (views depend on it)');
select is(current_setting('t.auth_delete'), '42501', 'authenticated DELETE on signals fails with insufficient_privilege');
select is((select count(*) from public.signals where symbol = 'ACCTEST'), 1::bigint, 'the probe signal is still there');

-- Leftover baseline grants are recorded as-is (not a write path)
select ok(has_table_privilege('anon', 'public.signals', 'REFERENCES') and has_table_privilege('anon', 'public.signals', 'TRIGGER'),
  'baseline quirk recorded: anon still holds REFERENCES and TRIGGER');

-- Archive schema: only present in production; when present it must stay private.
select case when exists (select 1 from pg_namespace where nspname = 'archive_20261002')
  then ok(not has_schema_privilege('anon', 'archive_20261002', 'USAGE'), 'archive_20261002 is not usable by anon')
  else skip('archive_20261002 exists only in production', 1) end;

select * from finish();
rollback;
