-- Golden replay (delivery-pipeline: "Golden ledger replays"). Replays production's real inputs as of
-- 2026-10-09 and requires exactly the positions, events and marks production computed itself.
-- A PR that changes ledger behaviour must update fixtures/snapshot_2026-10-09.psql's expected
-- rows in the same PR, which makes the P&L effect of the change visible in review.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(7);

\ir fixtures/snapshot_2026-10-09.psql

select is(
  jsonb_build_object('signals', (select count(*) from signals), 'price_bars', (select count(*) from price_bars)),
  (select data - 'positions' - 'events' - 'marks' from snap_expected where kind = 'summary'),
  'snapshot inputs loaded: 122 signals, 281 price bars');

select lives_ok($$ select process_ledger('2026-10-09') $$, 'process_ledger replays the production inputs');

create temp view snap_actual as
  select 'positions'::text kind, coalesce(jsonb_agg(to_jsonb(p) - 'id' order by p.signal_id), '[]') data from positions p
  union all
  select 'events', coalesce(jsonb_agg(to_jsonb(e) - 'id' - 'position_id' - 'created_at'
                                      order by e.signal_id, e.event_date, e.event_type, e.trigger_signal_id), '[]') from events e
  union all
  select 'marks', coalesce(jsonb_agg((to_jsonb(m) - 'position_id') || jsonb_build_object('signal_id', p.signal_id)
                                     order by p.signal_id, m.mark_date), '[]') from marks m join positions p on p.id = m.position_id;

-- Readable failure: which rows differ (by signal id / date), before the exact comparisons.
select is(
  (select array_agg(distinct k || ' signal ' || coalesce(r ->> 'signal_id', '?') order by k || ' signal ' || coalesce(r ->> 'signal_id', '?'))
     from (select a.kind k, x r from snap_actual a, jsonb_array_elements(a.data) x
           except
           select e.kind, y from snap_expected e, jsonb_array_elements(e.data) y where e.kind <> 'summary'
           union
           (select e.kind, y from snap_expected e, jsonb_array_elements(e.data) y where e.kind <> 'summary'
            except
            select a.kind, x from snap_actual a, jsonb_array_elements(a.data) x)) d),
  null,
  'no position, event or mark differs from production (lists differing signal ids otherwise)');

select is((select data from snap_actual where kind = 'positions'), (select data from snap_expected where kind = 'positions'),
  'positions equal production exactly (6 rows)');
select is((select data from snap_actual where kind = 'events'), (select data from snap_expected where kind = 'events'),
  'events equal production exactly (5 rows)');
select is((select data from snap_actual where kind = 'marks'), (select data from snap_expected where kind = 'marks'),
  'marks equal production exactly (10 rows)');
select is((select round(sum(pnl), 2) from events), (select round(sum((x ->> 'pnl')::numeric), 2) from snap_expected, jsonb_array_elements(data) x where kind = 'events'),
  'total realised P&L equals production');

select * from finish();
rollback;
