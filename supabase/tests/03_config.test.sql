-- Configuration, runs, price bars and reviews (run-protocol, market-data, trade-review specs).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(25);

-- Baseline policy values (run-protocol: "Tracker configuration registry")
select results_eq(
  $$ select key, value::text from config
      where key not in ('protocol', 'fill_rules', 'processed_through', 'book_started_on') order by key $$,
  $$ values ('cost_roundtrip_pct_liquid', '0.5'), ('cost_roundtrip_pct_thin', '1.5'), ('max_open_positions', '10'),
            ('min_closed_trades_before_rule_change', '30'), ('paper_capital', '1000000'), ('position_cap_pct', '10'),
            ('reduced_size_multiple', '0.5'), ('risk_per_trade_pct', '1'), ('stop_cap_pct', '8'),
            ('trim_fraction', '0.30'), ('trim_multiple', '1.25') $$,
  'migrations seed exactly the baseline numeric policy values');

select ok((select value #>> '{}' like 'TRACKER PROTOCOL v1 %' from config where key = 'protocol'),
  'protocol text is TRACKER PROTOCOL v1');
select ok((select value #>> '{}' ilike '%stop = max(pivot*0.99, fill*0.92)%' from config where key = 'fill_rules'),
  'fill_rules text states the current stop rule');
select is((select count(*) from config where key in ('processed_through', 'book_started_on')), 0::bigint,
  'migrations do not write runtime keys');

-- Numeric lookup
select is(cfg_num('paper_capital'), 1000000::numeric, 'cfg_num reads paper_capital as a number');
select is(cfg_num('no_such_key'), null::numeric, 'cfg_num returns null for a missing key');

-- Runs
insert into runs(run_type) values ('weekly_scan');
select row_eq($$ select status, started_at is not null, finished_at is null from runs order by id desc limit 1 $$,
  row('running'::text, true, true), 'a new run defaults to running, with started_at set and no finished_at');
select throws_ok($$ update runs set status = 'done' where id = (select max(id) from runs) $$,
  '23514', null, 'run status outside running/succeeded/partial/failed is rejected');
select throws_ok($$ insert into runs(run_type) values ('nightly') $$, '23514', null, 'unknown run_type is rejected');
select lives_ok($$ update runs set finished_at = now(), status = 'succeeded', summary = 'ok', data_calls = '{"tapetide": 3}'
                    where id = (select max(id) from runs) $$, 'a run can be closed');

-- Price bars (market-data)
insert into price_bars(symbol, bar_date, open, high, low, close, volume, source)
values ('BARTEST', '2026-01-02', 10, 11, 9, 10.5, 1000, 'tapetide_quote');
select throws_ok($$ insert into price_bars(symbol, bar_date, open, high, low, close) values ('BARTEST', '2026-01-02', 1, 1, 1, 1) $$,
  '23505', null, 'a second bar for the same (symbol, bar_date) is rejected');
insert into price_bars(symbol, bar_date, open, high, low, close, volume, source)
values ('BARTEST', '2026-01-02', 10.1, 11.2, 9.1, 10.6, 1200, 'tapetide')
on conflict (symbol, bar_date) do update
  set open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close,
      volume = excluded.volume, source = excluded.source;
select row_eq($$ select count(*), max(close), max(source) from price_bars where symbol = 'BARTEST' $$,
  row(1::bigint, 10.6::numeric, 'tapetide'::text), 'upsert replaces a quote-based bar with the official bar');
select throws_ok($$ insert into price_bars(symbol, bar_date, open, high, low) values ('BARTEST', '2026-01-05', 1, 1, 1) $$,
  '23502', null, 'close is mandatory');
select lives_ok($$ insert into price_bars(symbol, bar_date, open, high, low, close) values ('BARTEST', '2026-01-05', 1, 1, 1, 1) $$,
  'volume and source are optional');
select ok((select inserted_at is not null from price_bars where symbol = 'BARTEST' and bar_date = '2026-01-05'),
  'insert time is recorded');

-- Trade reviews
insert into signals(symbol, signal_date, source, verdict) values ('REVTEST', '2026-01-02', 'adhoc', 'WAIT');
insert into trade_reviews(signal_id, symbol, tag, lesson) select id, 'REVTEST', 'missed_runner', 'ran 18% in 4w' from signals where symbol = 'REVTEST';
select is((select author from trade_reviews where symbol = 'REVTEST'), 'agent', 'trade review author defaults to agent');
select throws_ok($$ insert into trade_reviews(signal_id, symbol, tag) select id, 'REVTEST', 'lucky' from signals where symbol = 'REVTEST' $$,
  '23514', null, 'unknown trade review tag is rejected');
select throws_ok($$ insert into trade_reviews(signal_id, symbol, tag, author) select id, 'REVTEST', 'other', 'bot' from signals where symbol = 'REVTEST' $$,
  '23514', null, 'author outside agent/rajat is rejected');
select lives_ok($$ insert into trade_reviews(signal_id, symbol, tag, lesson) select id, 'REVTEST', 'missed_runner', 'dup' from signals where symbol = 'REVTEST' $$,
  'baseline quirk recorded: a duplicate (signal, tag) review is not blocked by the database');
select throws_ok($$ insert into trade_reviews(signal_id, tag) select id, 'other' from signals where symbol = 'REVTEST' $$,
  '23502', null, 'trade review symbol is mandatory');

-- Periodic reviews
insert into reviews(review_date, period) values ('2026-01-02', 'weekly');
select is((select proposal_status from reviews order by id desc limit 1), 'none', 'proposal_status defaults to none');
select throws_ok($$ insert into reviews(review_date, period) values ('2026-01-02', 'daily') $$,
  '23514', null, 'unknown review period is rejected');
select throws_ok($$ insert into reviews(review_date, period, proposal_status) values ('2026-01-02', 'weekly', 'maybe') $$,
  '23514', null, 'unknown proposal_status is rejected');
select throws_ok($$ insert into reviews(period) values ('weekly') $$, '23502', null, 'review_date is mandatory');
select throws_ok($$ insert into reviews(review_date, period, run_id) values ('2026-01-02', 'weekly', -1) $$,
  '23503', null, 'unknown run_id on a review is rejected by the foreign key');

select * from finish();
rollback;
