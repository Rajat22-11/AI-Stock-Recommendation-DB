-- Signal log (signal-log spec): append-only signals, supersession, vocabulary, provenance,
-- exclusions and rationale.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

insert into skill_versions(version, effective_from, sha256, summary)
values ('2026-01-01-sigtest0', '2026-01-01', repeat('a', 64), 'test');
insert into runs(run_type) values ('adhoc');

insert into signals(run_id, symbol, signal_date, source, verdict, skill_version, stop)
values ((select max(id) from runs), 'SIGTEST', '2026-01-02', 'weekly_scan', 'ENTRY', '2026-01-01-sigtest0', 90);

-- Append-only
prepare upd as update signals set stop = 100 where symbol = 'SIGTEST';
select throws_like('upd', 'signals are append-only: insert a new row with supersedes = %',
  'UPDATE on a signal is rejected with the append-only message');
select is((select stop from signals where symbol = 'SIGTEST'), 90::numeric, 'the rejected update left the row unchanged');

prepare del as delete from signals where symbol = 'SIGTEST';
select throws_like('del', 'signals are append-only: insert a new row with supersedes = %',
  'DELETE on a signal is rejected with the append-only message');
select is((select count(*) from signals where symbol = 'SIGTEST'), 1::bigint, 'the rejected delete left the row in place');

-- The message names the signal id
select throws_matching('upd',
  'supersedes = ' || (select id from signals where symbol = 'SIGTEST')::text || ' instead',
  'the append-only message names the signal id to supersede');

-- Escape hatch
set local tracker.allow_signal_edit = 'on';
select lives_ok('upd', 'UPDATE is allowed when tracker.allow_signal_edit = on');
select is((select stop from signals where symbol = 'SIGTEST'), 100::numeric, 'the escape-hatch update was applied');
set local tracker.allow_signal_edit = 'off';
select throws_like('upd', 'signals are append-only%', 'turning the flag off restores the guard');

-- Supersession is plain data; a live signal is one nobody supersedes
insert into signals(symbol, signal_date, source, verdict, supersedes)
values ('SIGTEST', '2026-01-03', 'adhoc', 'ENTRY', (select id from signals where symbol = 'SIGTEST' and supersedes is null order by id limit 1));
select is(
  (select count(*) from signals s where s.symbol = 'SIGTEST'
     and not exists (select 1 from signals y where y.supersedes = s.id)),
  1::bigint, 'after supersession exactly one SIGTEST signal is live');

-- Vocabulary and defaults
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict) values ('X', '2026-01-02', 'adhoc', 'BUY') $$,
  '23514', null, 'unknown verdict BUY is rejected');
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict) values ('X', '2026-01-02', 'manual', 'WAIT') $$,
  '23514', null, 'unknown source is rejected');
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict, why_grade) values ('X', '2026-01-02', 'adhoc', 'WAIT', 'E') $$,
  '23514', null, 'why_grade outside A-D is rejected');
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict, stage) values ('X', '2026-01-02', 'adhoc', 'WAIT', 5) $$,
  '23514', null, 'stage outside 1-4 is rejected');
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict, liquidity_tier) values ('X', '2026-01-02', 'adhoc', 'WAIT', 'illiquid') $$,
  '23514', null, 'unknown liquidity_tier is rejected');

insert into signals(symbol, signal_date, source, verdict) values ('SIGDEF', '2026-01-02', 'adhoc', 'NO_GO');
select row_eq(
  $$ select exchange, provisional, liquidity_tier, retro_seeded from signals where symbol = 'SIGDEF' $$,
  row('NSE'::text, false, 'liquid'::text, false),
  'defaults: exchange NSE, provisional false, liquidity_tier liquid, retro_seeded false');

select throws_ok($$ insert into signals(symbol, source, verdict) values ('X', 'adhoc', 'WAIT') $$,
  '23502', null, 'signal_date is mandatory');
select lives_ok($$ insert into signals(symbol, signal_date, source, verdict, pivot) values ('SIGNOPIV', '2026-01-02', 'adhoc', 'ENTRY', null) $$,
  'measurement fields such as pivot are optional (real-fill signals)');

-- Provenance
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict, skill_version) values ('X', '2026-01-02', 'adhoc', 'WAIT', '2099-01-01-deadbeef') $$,
  '23503', null, 'unknown skill_version is rejected by the foreign key');
select throws_ok($$ insert into signals(symbol, signal_date, source, verdict, run_id) values ('X', '2026-01-02', 'adhoc', 'WAIT', -1) $$,
  '23503', null, 'unknown run_id is rejected by the foreign key');
select lives_ok($$ insert into skill_versions(version, effective_from) values ('2026-01-01-sigtest0', '2026-01-01') on conflict do nothing $$,
  'registering an existing skill version with on conflict do nothing is a no-op');

-- Exclusions and rationale: at most one per signal
insert into signal_exclusions(signal_id, batch, reason)
values ((select id from signals where symbol = 'SIGDEF'), 'test_batch', 'test');
select throws_ok($$ insert into signal_exclusions(signal_id, batch, reason) select id, 'b2', 'again' from signals where symbol = 'SIGDEF' $$,
  '23505', null, 'a signal can be excluded only once');

insert into signal_rationale(signal_id, thesis, confidence) select id, 'test', 3 from signals where symbol = 'SIGDEF';
select throws_ok($$ insert into signal_rationale(signal_id, thesis, confidence) select id, 'again', 3 from signals where symbol = 'SIGDEF' $$,
  '23505', null, 'a signal has at most one rationale');
select throws_ok($$ insert into signal_rationale(signal_id, thesis, confidence) select id, 't', 6 from signals where symbol = 'SIGNOPIV' $$,
  '23514', null, 'rationale confidence outside 1-5 is rejected');
select throws_ok($$ insert into signal_rationale(signal_id, confidence) select id, 3 from signals where symbol = 'SIGNOPIV' $$,
  '23502', null, 'rationale thesis is mandatory');

select * from finish();
rollback;
