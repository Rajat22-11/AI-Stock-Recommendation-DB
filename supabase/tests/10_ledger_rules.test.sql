-- Paper-ledger rules (paper-ledger spec). One small fixture per rule; expected values are worked
-- out by hand from the rules, not copied from a run. Capital 1,000,000, cap 10%, liquid cost 0.5%
-- round trip (0.25% per side). Sessions: Fri 2026-01-02, then Mon 01-05 .. Fri 01-09.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(50);

-- ---------------------------------------------------------------- helpers
create function pg_temp.reset() returns void language plpgsql as $$
begin
  perform set_config('tracker.allow_signal_edit', 'on', true);
  delete from marks; delete from events; delete from positions;
  delete from signal_rationale; delete from signal_exclusions; delete from trade_reviews;
  delete from signals; delete from price_bars;
  perform set_config('tracker.allow_signal_edit', 'off', true);
  update config set value = '10' where key = 'max_open_positions';
end $$;

create function pg_temp.entry(
  p_sym text, p_ehigh numeric, p_stop numeric, p_pivot numeric,
  p_ws date default '2026-01-05', p_we date default '2026-01-08', p_size numeric default 10,
  p_rank int default 1, p_verdict text default 'ENTRY', p_prov boolean default false,
  p_liq text default 'liquid', p_risk numeric default null, p_sdate date default '2026-01-02',
  p_supersedes bigint default null) returns bigint language sql as $$
  insert into signals(symbol, signal_date, source, verdict, provisional, entry_low, entry_high, stop, pivot,
                      window_start, window_end, size_pct, priority_rank, liquidity_tier, risk_pct, supersedes)
  values (p_sym, p_sdate, 'weekly_scan', p_verdict, p_prov, p_ehigh, p_ehigh, p_stop, p_pivot,
          p_ws, p_we, p_size, p_rank, p_liq, p_risk, p_supersedes)
  returning id $$;

create function pg_temp.mgmt(p_sym text, p_sdate date, p_verdict text, p_stop numeric default null,
  p_size numeric default null, p_prov boolean default false) returns bigint language sql as $$
  insert into signals(symbol, signal_date, source, verdict, provisional, stop, size_pct)
  values (p_sym, p_sdate, 'weekly_scan', p_verdict, p_prov, p_stop, p_size) returning id $$;

create function pg_temp.bar(p_sym text, p_d date, o numeric, h numeric, l numeric, c numeric) returns void language sql as $$
  insert into price_bars(symbol, bar_date, open, high, low, close, source) values (p_sym, p_d, o, h, l, c, 'test') $$;

-- status|fill_date|fill|qty_initial|qty_open|stop_at_fill|stop_current|trim|trimmed|exit_date|exit|reason|realized|costs
create function pg_temp.pos(p_sym text) returns text language sql as $$
  select string_agg(concat_ws('|', status, coalesce(fill_date::text, '-'), coalesce(round(fill_price, 2)::text, '-'),
           coalesce(qty_initial::text, '-'), coalesce(qty_open::text, '-'), coalesce(round(stop_at_fill, 2)::text, '-'),
           coalesce(round(stop_current, 2)::text, '-'), coalesce(round(trim_price, 2)::text, '-'), coalesce(trimmed::text, '-'),
           coalesce(exit_date::text, '-'), coalesce(round(exit_price, 2)::text, '-'), coalesce(exit_reason, '-'),
           coalesce(round(realized_pnl, 2)::text, '-'), coalesce(round(costs, 2)::text, '-')), ' / ' order by id)
  from positions where symbol = p_sym $$;

-- date type price xqty pnl
create function pg_temp.evs(p_sym text) returns text language sql as $$
  select string_agg(concat_ws(' ', event_date, event_type, coalesce(round(price, 2)::text, '-'),
           'x' || coalesce(qty::text, '-'), coalesce(round(pnl, 2)::text, '-')), '; ' order by event_date, id)
  from events where symbol = p_sym $$;

create function pg_temp.mark(p_sym text, p_d date) returns text language sql as $$
  select concat_ws(' ', mark_date, round(close, 2), 'q' || qty_open, 'cb', round(cost_basis, 2), 'mv', round(market_value, 2),
           'u', round(unrealized_pnl, 2), coalesce(unrealized_pct::text, '-') || '%', 'r', round(realized_to_date, 2),
           's', round(stop_current, 2), 'd', coalesce(dist_to_stop_pct::text, '-'))
  from marks where symbol = p_sym and mark_date = p_d $$;

create function pg_temp.snapshot() returns text language sql as $$
  select coalesce((select string_agg(s, E'\n' order by s) from (
    select 'P ' || symbol || ' ' || pg_temp.pos(symbol) s from (select distinct symbol from positions) x
    union all select 'E ' || symbol || ' ' || coalesce(pg_temp.evs(symbol), '') from (select distinct symbol from events) y
    union all select 'M ' || m.symbol || ' ' || pg_temp.mark(m.symbol, m.mark_date) from marks m) z), '') $$;

-- ---------------------------------------------------------------- 1. entry window and fill rule
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('FILL', 300, 270, 280);
  perform pg_temp.bar('FILL', '2026-01-02', 260, 262, 255, 261);  -- before the window: ignored
  perform pg_temp.bar('FILL', '2026-01-05', 310, 315, 305, 312);  -- low above entry_high: no fill
  perform pg_temp.bar('FILL', '2026-01-06', 298, 305, 296, 303);  -- gap-down open below entry_high
  perform process_ledger('2026-01-06');
end $$;
-- qty floor(100000/298)=335; cost round(335*298*0.0025,2)=249.58; stop max(280*0.99=277.20, 298*0.92=274.16)
select is(pg_temp.pos('FILL'), 'open|2026-01-06|298.00|335|335|277.20|277.20|372.50|false|-|-|-|-249.58|249.58',
  'fills on the first in-window session with low <= entry_high, at min(open, entry_high); pivot leg sets the stop');
select is(pg_temp.evs('FILL'), '2026-01-06 fill 298.00 x335 -249.58', 'one fill event, buy-side cost charged as negative P&L');
select is(pg_temp.mark('FILL', '2026-01-06'), '2026-01-06 303.00 q335 cb 99830.00 mv 101505.00 u 1675.00 1.68% r -249.58 s 277.20 d 9.31',
  'mark on the fill day: cost basis, market value, unrealised P&L and distance to stop');
select is((select count(*) from marks where symbol = 'FILL' and mark_date < '2026-01-06'), 0::bigint, 'no marks while pending');

-- ---------------------------------------------------------------- 2. expiry
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('EXPA', 100, 92, null, p_we => '2026-01-06');
  perform pg_temp.bar('EXPA', '2026-01-05', 106, 107, 105, 106);
  perform pg_temp.bar('EXPA', '2026-01-06', 105, 106, 104, 105);
  perform pg_temp.bar('EXPA', '2026-01-07', 104, 105, 103, 104);
  perform pg_temp.entry('EXPB', 50, 46, null, p_we => '2026-01-06');  -- no bars of its own
  perform process_ledger('2026-01-09');
end $$;
select is((select status || '|' || exit_reason from positions where symbol = 'EXPA'), 'expired|no fill in window',
  'a session after window_end expires an unfilled position');
select is((select concat_ws(' ', event_date, event_type, rule) from events where symbol = 'EXPA'),
  '2026-01-07 expire window ended without a fill', 'expiry event is dated on the first session after the window');
select is((select concat_ws(' ', event_date, status, exit_reason) from positions p join events e using (signal_id) where p.symbol = 'EXPB'),
  '2026-01-07 expired no fill in window',
  'sessions are the bar dates of any symbol: a symbol with no bars still expires on the first session after its window');

do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('EXPC', 50, 46, null, p_we => '2026-01-06');  -- no bars anywhere: no sessions at all
  perform process_ledger('2026-01-09');
end $$;
select is((select status || '|' || exit_reason from positions where symbol = 'EXPC'), 'expired|no fill in window (no price data)',
  'with no session after the window, a pending position is expired at the end of processing');
select is((select concat_ws(' ', event_date, event_type, rule) from events where symbol = 'EXPC'),
  '2026-01-06 expire window ended without a fill (no price data in window)', 'end-of-processing expiry is dated on window_end');
select is((select count(*) from positions where status = 'pending'), 0::bigint, 'nothing past its window stays pending');

-- ---------------------------------------------------------------- 3. entry selection, size, cost
do $$
declare e2 bigint; e3 bigint;
begin
  perform pg_temp.reset();
  perform pg_temp.entry('SELA', 100, 92, null, p_prov => true);
  e2 := pg_temp.entry('SELB', 100, 92, null, p_sdate => '2026-01-01');
  e3 := pg_temp.entry('SELB', 100, 92, null, p_supersedes => e2);
  perform set_config('t.e3', e3::text, true);
  perform pg_temp.entry('SELC', 100, 92, null, p_verdict => 'WAIT');
  perform pg_temp.entry('SZA', 100, 92, null, p_verdict => 'ENTRY_REDUCED', p_size => 5);
  perform pg_temp.entry('SZB', 100, 92, null, p_size => null, p_risk => 8);
  perform pg_temp.entry('SZC', 100, 92, null, p_size => null, p_risk => 20);
  perform pg_temp.entry('SZD', 100, 92, null, p_verdict => 'ENTRY_REDUCED', p_size => null, p_risk => 20);
  perform pg_temp.entry('SZE', 100, 92, null, p_size => null, p_liq => 'thin');
  perform process_ledger('2026-01-02');
end $$;
select is((select string_agg(symbol || ':' || round(planned_size_pct, 4) || ':' || cost_pct || ':' || status, ' ' order by symbol) from positions),
  'SELB:10.0000:0.5:pending SZA:5.0000:0.5:pending SZB:10.0000:0.5:pending SZC:5.0000:0.5:pending SZD:2.5000:0.5:pending SZE:10.0000:1.5:pending',
  'positions only for live non-provisional ENTRY/ENTRY_REDUCED; size = size_pct, else min(cap, risk/risk_pct*100) x reduced multiple; thin cost 1.5');
select is((select signal_id from positions where symbol = 'SELB'), current_setting('t.e3')::bigint,
  'a superseded entry is ignored; the superseding signal becomes the position');

-- ---------------------------------------------------------------- 4. priority and max open positions
do $$ begin
  perform pg_temp.reset();
  update config set value = '1' where key = 'max_open_positions';
  perform pg_temp.entry('PRA', 100, 92, null, p_rank => 2);
  perform pg_temp.entry('PRB', 100, 92, null, p_rank => 1);
  perform pg_temp.bar('PRA', '2026-01-05', 99, 101, 98, 100);
  perform pg_temp.bar('PRB', '2026-01-05', 99, 101, 98, 100);
  perform process_ledger('2026-01-05');
end $$;
select is((select string_agg(symbol || ':' || status || ':' || coalesce(exit_reason, '-'), ' ' order by symbol) from positions),
  'PRA:skipped:max open positions PRB:open:-', 'lower priority_rank takes the last open slot; the other is skipped');
select is((select rule from events where symbol = 'PRA'), 'max open positions reached', 'skip event explains the reason');

-- ---------------------------------------------------------------- 5. pre-fill skip rules and their order
do $$
declare h2 bigint; h3 bigint;
begin
  perform pg_temp.reset();
  perform pg_temp.entry('SKA', 100, 92, null);
  perform pg_temp.bar('SKA', '2026-01-05', 91, 93, 90, 92);                 -- opens at/below stop
  perform pg_temp.entry('HLD', 100, 92, null);                               -- fills 01-05
  h2 := pg_temp.entry('HLD', 101, 93, null, p_ws => '2026-01-06', p_we => '2026-01-09', p_sdate => '2026-01-05');
  h3 := pg_temp.entry('HLD', 101, 105, null, p_ws => '2026-01-06', p_we => '2026-01-09', p_sdate => '2026-01-05');
  perform set_config('t.h2', h2::text, true); perform set_config('t.h3', h3::text, true);
  perform pg_temp.bar('HLD', '2026-01-05', 99, 101, 98, 100);
  perform pg_temp.bar('HLD', '2026-01-06', 100, 102, 99, 101);
  perform pg_temp.entry('SZ1', 2000, 1840, null, p_size => 0.1);           -- budget 1000 < one share
  perform pg_temp.bar('SZ1', '2026-01-05', 1990, 2001, 1985, 1995);
  perform process_ledger('2026-01-06');
end $$;
select is((select concat_ws('|', status, exit_reason) from positions where symbol = 'SKA'), 'skipped|opened at/below stop',
  'a session opening at or below the signal stop skips the trade');
select is((select concat_ws(' ', event_type, round(price, 2)) from events where symbol = 'SKA'), 'skip 91.00', 'skip event records the open');
select is((select concat_ws('|', status, exit_reason) from positions where signal_id = current_setting('t.h2')::bigint),
  'skipped|already holding', 'a second entry for a symbol already held is skipped');
select is((select concat_ws('|', status, exit_reason) from positions where signal_id = current_setting('t.h3')::bigint),
  'skipped|opened at/below stop', 'skip checks run in order: open-below-stop is reported before already-holding');
select is((select concat_ws('|', status, exit_reason) from positions where symbol = 'SZ1'), 'skipped|size_below_1_share',
  'a planned budget that buys under one share is skipped');
select is((select rule from events where symbol = 'SZ1'), 'planned size Rs 1000.00 is below one share at Rs 1990',
  'size skip explains budget and price');

-- ---------------------------------------------------------------- 6. available cash
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('CSA', 300, 270, null, p_size => 100, p_rank => 1);
  perform pg_temp.entry('CSB', 100, 92, null, p_rank => 2);
  perform pg_temp.bar('CSA', '2026-01-05', 300, 301, 299, 300);
  perform pg_temp.bar('CSB', '2026-01-05', 100, 101, 99, 100);
  perform process_ledger('2026-01-05');
end $$;
-- CSA: 3333 x 300 = 999,900 invested, cost 2,499.75 -> cash = 1e6 - 2,499.75 - 999,900 = -2,399.75
select is((select concat_ws('|', qty_initial, round(costs, 2)) from positions where symbol = 'CSA'), '3333|2499.75', 'full-capital entry');
select is((select concat_ws('|', status, exit_reason) from positions where symbol = 'CSB'), 'skipped|insufficient cash',
  'cash = capital + event P&L - open cost basis; below one share skips the trade');

do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('CLA', 300, 270, null, p_size => 95, p_rank => 1);
  perform pg_temp.entry('CLB', 100, 92, null, p_rank => 2);
  perform pg_temp.bar('CLA', '2026-01-05', 300, 301, 299, 300);
  perform pg_temp.bar('CLB', '2026-01-05', 100, 101, 99, 100);
  perform process_ledger('2026-01-05');
end $$;
-- CLA: 3166 x 300 = 949,800, cost 2,374.50 -> cash 47,825.50 -> CLB qty floor(47,825.50 / 100) = 478
select is((select qty_initial from positions where symbol = 'CLB'), 478, 'quantity is limited by available cash');

-- ---------------------------------------------------------------- 7. stop at fill (both legs, NULL pivot) and trim level
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('PVA', 300, 270, 289.65);
  perform pg_temp.entry('PVB', 300, 270, 250);
  perform pg_temp.entry('NPV', 282, 259.44, null);
  perform pg_temp.entry('NPW', 282, 250, null);
  perform pg_temp.bar('PVA', '2026-01-05', 300, 301, 299, 300);
  perform pg_temp.bar('PVB', '2026-01-05', 300, 301, 299, 300);
  perform pg_temp.bar('NPV', '2026-01-05', 282, 283, 281, 282);
  perform pg_temp.bar('NPW', '2026-01-05', 282, 283, 281, 282);
  perform process_ledger('2026-01-05');
end $$;
select is((select round(stop_at_fill, 2) from positions where symbol = 'PVA'), 286.75, 'pivot leg: max(289.65*0.99=286.75, 300*0.92=276.00)');
select is((select round(stop_at_fill, 2) from positions where symbol = 'PVB'), 276.00, 'fill leg: max(250*0.99=247.50, 300*0.92=276.00)');
select is((select round(stop_at_fill, 2) from positions where symbol = 'NPV'), 259.44, 'NULL pivot: the signal stop replaces the pivot leg (259.44 vs 259.44)');
select is((select round(stop_at_fill, 2) from positions where symbol = 'NPW'), 259.44, 'NULL pivot: fill x 0.92 wins over a lower signal stop');
select is((select string_agg(round(trim_price, 2)::text || ':' || trimmed, ' ' order by symbol) from positions where symbol in ('PVA', 'NPV')),
  '352.50:false 375.00:false', 'trim level = round(fill x 1.25, 2), not yet trimmed');

-- ---------------------------------------------------------------- 8. management verdicts, ratchet, marks, watermark
do $$
declare x bigint;
begin
  perform pg_temp.reset();
  perform pg_temp.entry('MGT', 100, 92, null, p_rank => 1);
  perform pg_temp.entry('MISS', 50, 46, null, p_size => 1, p_rank => 2);
  perform pg_temp.mgmt('MGT', '2026-01-05', 'TRIM');                      -- dated on the fill day -> next session
  perform pg_temp.mgmt('MGT', '2026-01-06', 'HOLD', p_stop => 90);        -- lower stop: ignored
  perform pg_temp.mgmt('MGT', '2026-01-06', 'REDUCE');
  perform pg_temp.mgmt('MGT', '2026-01-07', 'HOLD', p_stop => 95);        -- raises the stop
  perform pg_temp.mgmt('MGT', '2026-01-07', 'EXIT', p_prov => true);      -- provisional: ignored
  x := pg_temp.mgmt('MGT', '2026-01-08', 'EXIT');
  perform set_config('t.exit', x::text, true);
  perform pg_temp.bar('MGT', '2026-01-05', 100, 101, 99, 100);
  perform pg_temp.bar('MGT', '2026-01-06', 105, 106, 104, 105);
  perform pg_temp.bar('MGT', '2026-01-07', 106, 107, 105, 106);
  perform pg_temp.bar('MGT', '2026-01-08', 107, 108, 106, 107);
  perform pg_temp.bar('MGT', '2026-01-09', 108, 109, 107, 108);
  perform pg_temp.bar('MISS', '2026-01-05', 50, 51, 49, 50);              -- MISS has no bars on 01-06, 01-08, 01-09
  perform pg_temp.bar('MISS', '2026-01-07', 51, 52, 50, 51);
  perform set_config('t.res1', process_ledger('2026-01-09')::text, true);
  perform set_config('t.snap1', pg_temp.snapshot(), true);
  perform process_ledger('2026-01-09');
end $$;
select is(pg_temp.evs('MGT'),
  '2026-01-05 fill 100.00 x1000 -250.00; 2026-01-06 trim 105.00 x300 1421.25; 2026-01-07 reduce 106.00 x350 2007.25; '
  || '2026-01-08 stop_raise 95.00 x- 0.00; 2026-01-09 exit 108.00 x350 2705.50',
  'TRIM sells 30% once, REDUCE half, HOLD raises the stop, EXIT sells all; each at the next session open');
select is(pg_temp.pos('MGT'), 'closed|2026-01-05|100.00|1000|0|92.00|95.00|125.00|true|2026-01-09|108.00|exit|5884.00|516.00',
  'realised P&L nets sell-side costs; full exit closes the position with exit date, price and reason');
select is((select trigger_signal_id from events where symbol = 'MGT' and event_type = 'exit'), current_setting('t.exit')::bigint,
  'the exit event links to the EXIT signal (the provisional EXIT was ignored)');
select is((select count(*) from events where symbol = 'MGT' and event_type = 'stop_raise'), 1::bigint,
  'a lower signal stop never lowers the stop and writes no event');
select is(pg_temp.mark('MGT', '2026-01-06'), '2026-01-06 105.00 q700 cb 70000.00 mv 73500.00 u 3500.00 5.00% r 1171.25 s 92.00 d 14.13',
  'daily mark after the trim');
select is(pg_temp.mark('MGT', '2026-01-09'), '2026-01-09 108.00 q0 cb 0.00 mv 0.00 u 0.00 -% r 5884.00 s 95.00 d -',
  'a position closed on a session still gets that session''s mark');
select is((select string_agg(mark_date::text, ' ' order by mark_date) from marks where symbol = 'MISS'), '2026-01-05 2026-01-07',
  'no mark (and no action) on sessions without a bar for the symbol');
select is(current_setting('t.snap1'), pg_temp.snapshot(), 'processing again with the same inputs gives identical positions, events and marks');
select is((select value #>> '{}' from config where key = 'processed_through'), '2026-01-09', 'processed_through watermark is saved');
select is((current_setting('t.res1')::jsonb) - 'realized_pnl',
  '{"events": 6, "through": "2026-01-09", "positions": {"open": 1, "closed": 1}, "open_without_recent_bars": []}'::jsonb,
  'result summarises date, positions by status, events and stale symbols');
select is((current_setting('t.res1')::jsonb ->> 'realized_pnl')::numeric, 5884.00 - 25.00, 'result realised P&L sums every event (MISS fill cost 25.00 included)');
select is(process_ledger('2026-01-13') -> 'open_without_recent_bars', '["MISS"]'::jsonb,
  'open symbols with no bar in the 4 days up to the processed date are reported');

-- ---------------------------------------------------------------- 9. stop execution and automatic trim
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('GAP', 100, 92, null, p_rank => 1);
  perform pg_temp.entry('TCH', 100, 92, null, p_rank => 2);
  perform pg_temp.entry('SBT', 100, 92, null, p_rank => 3);
  perform pg_temp.entry('TGU', 100, 92, null, p_rank => 4);
  perform pg_temp.bar(s, '2026-01-05', 100, 101, 99, 100) from unnest(array['GAP', 'TCH', 'SBT', 'TGU']) s;
  perform pg_temp.bar('GAP', '2026-01-06', 90, 91, 88, 89);     -- gaps through the stop
  perform pg_temp.bar('TCH', '2026-01-06', 95, 96, 91, 94);     -- touches the stop intraday
  perform pg_temp.bar('SBT', '2026-01-06', 100, 130, 91, 110);  -- touches both stop and trim
  perform pg_temp.bar('TGU', '2026-01-06', 130, 131, 129, 130); -- gaps above the trim level
  perform pg_temp.bar('TGU', '2026-01-07', 131, 140, 129, 135); -- trim level again: no second trim
  perform process_ledger('2026-01-07');
end $$;
select is(pg_temp.pos('GAP'), 'closed|2026-01-05|100.00|1000|0|92.00|92.00|125.00|false|2026-01-06|90.00|stop_hit|-10475.00|475.00',
  'gap through stop: whole position sold at the open');
select is((select rule from events where symbol = 'GAP' and event_type = 'stop_hit'), 'gapped through stop: filled at open', 'gap rule text');
select is(pg_temp.evs('TCH'), '2026-01-05 fill 100.00 x1000 -250.00; 2026-01-06 stop_hit 92.00 x1000 -8230.00',
  'intraday touch sells at the stop');
select is(pg_temp.evs('SBT'), '2026-01-05 fill 100.00 x1000 -250.00; 2026-01-06 stop_hit 92.00 x1000 -8230.00',
  'stop takes precedence when stop and trim are both reached on one day');
select is(pg_temp.evs('TGU'), '2026-01-05 fill 100.00 x1000 -250.00; 2026-01-06 trim 130.00 x300 8902.50',
  'automatic trim sells 30% at max(open, trim level), once');
select is(pg_temp.pos('TGU'), 'open|2026-01-05|100.00|1000|700|92.00|92.00|125.00|true|-|-|-|8652.50|347.50', 'trimmed position stays open');

-- Same-session stop: on the fill day the stop is already checked against that day's low.
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('FDS', 100, 92, 99.5);                     -- stop = max(99.5*0.99=98.51, 92.00) = 98.51
  perform pg_temp.bar('FDS', '2026-01-05', 100, 101, 98, 100);     -- fills at 100, low 98 is below the stop
  perform process_ledger('2026-01-05');
end $$;
select is(pg_temp.evs('FDS'), '2026-01-05 fill 100.00 x1000 -250.00; 2026-01-05 stop_hit 98.51 x1000 -1736.28',
  'baseline behaviour: a fill-day low below the stop exits the position on the fill day');

-- ---------------------------------------------------------------- 10. ADD within the cap
do $$ begin
  perform pg_temp.reset();
  perform pg_temp.entry('ADA', 100, 92, null, p_size => 5, p_rank => 1);
  perform pg_temp.entry('ADB', 100, 92, null, p_size => 10, p_rank => 2);
  perform pg_temp.mgmt('ADA', '2026-01-05', 'ADD', p_size => 3);
  perform pg_temp.mgmt('ADB', '2026-01-05', 'ADD');
  perform pg_temp.bar(s, '2026-01-05', 100, 101, 99, 100) from unnest(array['ADA', 'ADB']) s;
  perform pg_temp.bar(s, '2026-01-06', 102, 103, 101, 102) from unnest(array['ADA', 'ADB']) s;
  perform process_ledger('2026-01-06');
end $$;
-- ADA: add floor(min(30,000, 100,000 - 500*102, cash) / 102) = 294; avg (50,000 + 29,988) / 794
select is((select concat_ws('|', qty_open, round(avg_cost, 4), round(gross_bought, 2), round(costs, 2), round(realized_pnl, 2)) from positions where symbol = 'ADA'),
  '794|100.7406|79988.00|199.97|-199.97', 'ADD buys at the open within size and cap, re-weights average cost, charges cost');
select is(pg_temp.evs('ADA'), '2026-01-05 fill 100.00 x500 -125.00; 2026-01-06 add 102.00 x294 -74.97', 'add event');
select is((select count(*) from events where symbol = 'ADB' and event_type = 'add'), 0::bigint,
  'ADD on a position already at the 10% cap buys nothing and writes no event');

select * from finish();
rollback;
