-- View behaviour (performance-analytics spec). Expected values worked out by hand from the rules.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(31);

create function pg_temp.reset() returns void language plpgsql as $$
begin
  perform set_config('tracker.allow_signal_edit', 'on', true);
  delete from marks; delete from events; delete from positions;
  delete from signal_rationale; delete from signal_exclusions; delete from trade_reviews;
  delete from signals; delete from price_bars;
  perform set_config('tracker.allow_signal_edit', 'off', true);
end $$;

create function pg_temp.sig(p_sym text, p_date date, p_verdict text, p_extra jsonb default '{}') returns bigint language sql as $$
  insert into signals overriding system value select * from jsonb_populate_record(null::signals,
    jsonb_build_object('id', nextval(pg_get_serial_sequence('public.signals', 'id')), 'created_at', now(), 'symbol', p_sym,
                       'exchange', 'NSE', 'signal_date', p_date, 'source', 'weekly_scan', 'verdict', p_verdict,
                       'provisional', false, 'liquidity_tier', 'liquid', 'retro_seeded', false) || p_extra)
  returning id $$;

create function pg_temp.bar(p_sym text, p_d date, o numeric, h numeric, l numeric, c numeric) returns void language sql as $$
  insert into price_bars(symbol, bar_date, open, high, low, close, source) values (p_sym, p_d, o, h, l, c, 'test') $$;

create function pg_temp.ck(p_id bigint, p_ord int) returns text language sql as $$
  select status from v_signal_checklist where signal_id = p_id and ord = p_ord $$;

-- ---------------------------------------------------------------- checklist
do $$ begin
  perform pg_temp.reset();
  perform set_config('t.cka', pg_temp.sig('CKA', '2026-01-02', 'ENTRY', '{"signal_close": 105, "pivot": 100, "vol_mult": 6, "req_vol_mult": 2,
    "sma13_rising": true, "dist_sma_pct": 25, "correction_pct": 25, "setup": "A_base", "close_loc": 0.6, "why_grade": "C",
    "risk_pct": 9, "liquidity_tier": "thin"}')::text, true);
  perform set_config('t.ckb', pg_temp.sig('CKB', '2026-01-02', 'WAIT_ALERT', '{"signal_close": 95, "pivot": 100, "vol_mult": 1.5,
    "close_loc": 0.6, "correction_pct": 5, "setup": "B_flag"}')::text, true);
  perform set_config('t.ckc', pg_temp.sig('CKC', '2026-01-02', 'ENTRY', '{"signal_close": 95, "pivot": 100, "vol_mult": 2.5,
    "dist_sma_pct": 8, "correction_pct": 40, "close_loc": 0.8, "why_grade": "A", "risk_pct": 7, "sma13_rising": false}')::text, true);
  perform set_config('t.ckd', pg_temp.sig('CKD', '2026-01-02', 'ENTRY')::text, true);
end $$;
select is((select count(*) from v_signal_checklist where signal_id = current_setting('t.cka')::bigint), 9::bigint, 'nine rule rows per signal');
select is(
  (select string_agg(ord || ':' || status, ' ' order by ord) from v_signal_checklist where signal_id = current_setting('t.cka')::bigint),
  '1:pass 2:weak 3:pass 4:weak 5:weak 6:weak 7:weak 8:fail 9:weak',
  'ENTRY: volume > 5x weak, SMA distance 10-30 weak, correction 20-35 weak, close_loc 0.5-0.7 weak, grade C weak, risk > 8 fail, thin weak');
select is(
  (select string_agg(ord || ':' || status, ' ' order by ord) from v_signal_checklist where signal_id = current_setting('t.ckb')::bigint),
  '1:pending 2:pending 3:n/a 4:n/a 5:pass 6:pending 7:n/a 8:n/a 9:pass',
  'WAIT_ALERT: unmet close/volume/close-location are pending, not failed; Setup B needs no correction');
select is(
  (select string_agg(ord || ':' || status, ' ' order by ord) from v_signal_checklist where signal_id = current_setting('t.ckc')::bigint),
  '1:fail 2:pass 3:fail 4:pass 5:pass 6:pass 7:pass 8:pass 9:pass',
  'ENTRY: close below pivot and falling SMA fail; 2-3x volume, <= 10% SMA distance, >= 35% correction, A grade pass');
select is(
  (select string_agg(status, ' ' order by ord) from v_signal_checklist where signal_id = current_setting('t.ckd')::bigint),
  'n/a n/a n/a n/a n/a n/a n/a n/a pass', 'missing measurements are n/a (liquidity defaults to liquid)');
select is(
  (select concat_ws('|', passes, weak, fails, failed_rules) from v_signal_plan where signal_id = current_setting('t.cka')::bigint),
  '2|6|1|Risk to stop', 'the plan counts checklist passes, weak and fails and names failed rules');

-- ---------------------------------------------------------------- suggestions, plan, book risk, equity (no fills)
do $$
declare x bigint;
begin
  perform pg_temp.reset();
  perform pg_temp.sig('SGA', '2026-03-20', 'WAIT_ALERT', '{"priority_rank": 1}');
  perform pg_temp.sig('SGA', '2026-03-27', 'ENTRY', '{"priority_rank": 1, "entry_low": 100, "entry_high": 105, "stop": 92,
    "size_pct": 10, "window_start": "2026-04-01", "window_end": "2026-04-03"}');
  perform pg_temp.sig('SGB', '2026-02-20', 'WAIT');                                  -- older than 31 days
  x := pg_temp.sig('SGC', '2026-03-27', 'WAIT_ALERT');                               -- excluded
  insert into signal_exclusions(signal_id, batch, reason) values (x, 'test', 'test');
  perform pg_temp.sig('SGD', '2026-03-20', 'WAIT');
  perform pg_temp.sig('SGD', '2026-03-27', 'NO_GO');                                 -- latest verdict is not a suggestion
  x := pg_temp.sig('SGE', '2026-03-27', 'WAIT_ALERT', '{"priority_rank": 1, "alert_trigger": 210, "signal_close": 200}');
  insert into signal_rationale(signal_id, thesis, confidence) values (x, 'test thesis', 4);
  perform process_ledger('2026-03-31');
end $$;
select is((select string_agg(bucket || ':' || symbol || ':' || verdict, ' ' order by bucket, symbol) from v_suggestions),
  'entry:SGA:ENTRY watch:SGE:WAIT_ALERT',
  'latest live, non-excluded ENTRY/WAIT signal per symbol within 31 days; older, excluded and NO_GO-latest symbols are left out');
select is((select string_agg(symbol, ' ') from (select symbol from v_suggestions) s), 'SGA SGE', 'entries are listed before watch names');
select is((select concat_ws('|', position_value, book_cash, fundable_now) from v_suggestions where symbol = 'SGA'), '100000|1000000.00|t',
  'position value = capital x size; fundable when it fits the latest book cash');
select is((select concat_ws('|', thesis, confidence) from v_suggestions where symbol = 'SGE'), 'test thesis|4', 'suggestions carry the rationale');
select is((select concat_ws('|', entry_ref, stop_ref, trim_ref, risk_pct_plan, reward_pct_plan, rr_plan, book_status) from v_signal_plan
            where symbol = 'SGA' and verdict = 'ENTRY'), '100|92|125.00|8.00|25.00|3.13|pending',
  'plan: entry ref = entry_low, stop ref = signal stop, trim ref = entry x 1.25, R:R, book status');
select is((select count(*) from v_book_risk), 1::bigint, 'v_book_risk returns exactly one row');
select is((select concat_ws('|', equity, cash, open_positions, pending_entries, pending_committed_rupees, cash_after_pending) from v_book_risk),
  '1000000.00|1000000.00|0|1|100000|900000', 'book risk: cash, pending entries and cash committed to them');
select is((select concat_ws('|', count(*), max(as_of), max(equity)) from v_equity_daily), '1|2026-03-31|1000000.00',
  'with no fills the equity curve has one row at processed_through, equal to capital');

-- ---------------------------------------------------------------- forward outcomes
do $$ begin
  perform pg_temp.reset();
  perform set_config('t.out', pg_temp.sig('OUT', '2026-01-02', 'WAIT_ALERT', '{"signal_close": 100, "alert_trigger": 105, "stop": 92}')::text, true);
  perform pg_temp.bar('OUT', '2026-01-02', 99, 101, 98, 100);   -- the signal day itself is not a trigger hit
  perform pg_temp.bar('OUT', '2026-01-05', 101, 104, 100, 103);
  perform pg_temp.bar('OUT', '2026-01-08', 104, 106, 103, 105);  -- high > 105: trigger hit
  perform pg_temp.bar('OUT', '2026-01-09', 103, 104, 102, 103);  -- first bar on/after +7 days
  perform pg_temp.bar('OUT', '2026-01-12', 95, 96, 91, 93);      -- low <= 92: stop touched
  perform pg_temp.bar('OUT', '2026-02-02', 108, 115, 107, 110);  -- first bar on/after +28 days (no bar on 01-30)
end $$;
select is((select concat_ws('|', trigger_hit_date, stop_touch_date, ret_1w_pct, ret_4w_pct, coalesce(ret_13w_pct::text, '-'), max_up_4w_pct, max_down_4w_pct, last_bar)
             from v_signal_outcomes where signal_id = current_setting('t.out')::bigint),
  '2026-01-08|2026-01-12|3.00|10.00|-|6.00|-9.00|2026-02-02',
  'outcomes: first trigger/stop dates after the signal, horizon returns from the first bar on/after +7/+28 days, 4-week extremes');
select is((select count(*) from v_signal_outcomes where ret_13w_pct is null and signal_id = current_setting('t.out')::bigint), 1::bigint,
  'a horizon without data yet is null');

-- ---------------------------------------------------------------- trade review auto tags, trade stats
do $$ begin
  perform pg_temp.reset();
  -- WHP: stop = max(99.5*0.99=98.51, 92) = 98.51; stopped at 98.51 while the 8% strategy stop (92) never broke
  perform pg_temp.sig('WHP', '2026-01-02', 'ENTRY', '{"entry_low": 100, "entry_high": 100, "stop": 92, "pivot": 99.5, "size_pct": 10,
    "window_start": "2026-01-05", "window_end": "2026-01-08", "priority_rank": 1, "why_grade": "A", "setup": "A_base"}');
  perform pg_temp.sig('GPS', '2026-01-02', 'ENTRY', '{"entry_low": 100, "entry_high": 100, "stop": 92, "size_pct": 10,
    "window_start": "2026-01-05", "window_end": "2026-01-08", "priority_rank": 2, "why_grade": "B", "setup": "A_base"}');
  perform pg_temp.sig('VST', '2026-01-02', 'ENTRY', '{"entry_low": 100, "entry_high": 100, "stop": 92, "size_pct": 10,
    "window_start": "2026-01-05", "window_end": "2026-01-08", "priority_rank": 3, "why_grade": "B", "setup": "A_base"}');
  perform pg_temp.sig('OPN', '2026-01-02', 'ENTRY', '{"entry_low": 100, "entry_high": 100, "stop": 92, "size_pct": 10,
    "window_start": "2026-01-05", "window_end": "2026-01-08", "priority_rank": 4, "why_grade": "A", "setup": "B_flag"}');
  perform pg_temp.bar(s, '2026-01-05', 100, 101, 99, 100) from unnest(array['WHP', 'GPS', 'VST', 'OPN']) s;
  perform pg_temp.bar('WHP', '2026-01-06', 99, 99.5, 98, 99);
  perform pg_temp.bar('GPS', '2026-01-06', 90, 91, 88, 89);
  perform pg_temp.bar('VST', '2026-01-06', 95, 96, 91, 94);
  perform pg_temp.bar('OPN', '2026-01-06', 101, 103, 100, 102);
  perform pg_temp.bar('WHP', '2026-01-07', 100, 104, 99, 103);
  perform process_ledger('2026-01-07');
  insert into trade_reviews(signal_id, symbol, tag, lesson) select id, 'WHP', 'rule_violation', 'first' from signals where symbol = 'WHP';
  insert into trade_reviews(signal_id, symbol, tag, lesson, author) select id, 'WHP', 'whipsaw_tight_stop', 'second', 'rajat' from signals where symbol = 'WHP';
end $$;
select is((select string_agg(symbol || ':' || auto_tag, ' ' order by symbol) from v_trade_review),
  'GPS:gap_through_stop OPN:open VST:valid_stop WHP:whipsaw_tight_stop',
  'auto tags: exit below the ledger stop = gap; stop hit while fill x 0.92 never broke = whipsaw; otherwise valid stop');
select is((select concat_ws('|', skill_stop, skill_stop_still_intact, mae_pct, ledger_risk_pct) from v_trade_review where symbol = 'WHP'),
  '92.00|t|-2.00|1.49', 'strategy stop = fill x 0.92 and whether it still holds; MAE; ledger risk %');
select is((select concat_ws('|', review_tag, review_lesson, review_author) from v_trade_review where symbol = 'WHP'),
  'whipsaw_tight_stop|second|rajat', 'the latest (highest id) review is shown per trade');
select is((select count(*) from v_trade_stats where dimension = 'overall'), 1::bigint, 'v_trade_stats has exactly one overall row');
select is((select concat_ws('|', closed, open, not_filled) from v_trade_stats where dimension = 'overall'), '3|1|0',
  'overall row counts closed, open and unfilled positions');
select is((select concat_ws('|', closed, open) from v_trade_stats where dimension = 'setup' and setup = 'B_flag'), '0|1', 'per-setup rows');
select is((select win_rate_pct from v_trade_stats where dimension = 'overall'), 0.0, 'win rate over closed trades');
select ok((select count(*) from v_rule_effectiveness) > 0, 'rule effectiveness has rows once trades have closed');
select is((select count(*) from v_open_positions), 1::bigint, 'v_open_positions lists only open positions');
select is((select concat_ws('|', symbol, last_close, mark_date) from v_open_positions), 'OPN|102|2026-01-06', 'open position carries its latest mark');
select ok((select count(*) from v_activity where kind is not null and symbol = 'GPS') >= 3, 'activity feed merges signals and ledger events');
select is((select count(*) from v_pnl_monthly where month = '2026-01-01' and trades_closed = 3), 1::bigint, 'monthly P&L counts trades closed in the month');
select is((select count(*) from v_pnl_yearly), 1::bigint, 'yearly P&L has one row per year with data');
select is((select count(*) from v_equity_daily), 4::bigint, 'equity curve runs from the day before the first fill to processed_through');
select ok((select bool_and(equity = round(capital + realized_cum + unrealized, 2)) from v_equity_daily), 'equity = capital + realised + unrealised on every row');

select * from finish();
rollback;
