-- Schema contract (performance-analytics: "Stable view contract", plus the baseline table shape).
-- Generated from the replayed baseline, which equals production as of 2026-10-10 (design D3).
-- Tables must match exactly; views must keep their baseline columns first, in order
-- (appending a column to a view is allowed, removing or renaming one is a breaking change).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(69);

select tables_are('public', array[
    'config',
    'events',
    'marks',
    'positions',
    'price_bars',
    'reviews',
    'runs',
    'signal_exclusions',
    'signal_rationale',
    'signals',
    'skill_versions',
    'trade_reviews'
  ]::text[], 'public schema has exactly the 12 baseline tables');

select views_are('public', array[
    'v_activity',
    'v_book_risk',
    'v_equity_daily',
    'v_open_positions',
    'v_pnl_monthly',
    'v_pnl_yearly',
    'v_positions',
    'v_rule_effectiveness',
    'v_run_log',
    'v_signal_checklist',
    'v_signal_outcomes',
    'v_signal_plan',
    'v_suggestions',
    'v_trade_review',
    'v_trade_stats'
  ]::text[], 'public schema has exactly the 15 contract views');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.config'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'key:text:nn',
    'value:jsonb:nn',
    'description:text:n',
    'updated_at:timestamp with time zone:nn'
  ]::text[],
  'table config: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.events'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'position_id:bigint:n',
    'signal_id:bigint:n',
    'trigger_signal_id:bigint:n',
    'symbol:text:nn',
    'event_date:date:nn',
    'event_type:text:nn',
    'price:numeric:n',
    'qty:integer:n',
    'pnl:numeric:nn',
    'cost:numeric:nn',
    'rule:text:n',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table events: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.marks'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'position_id:bigint:nn',
    'mark_date:date:nn',
    'symbol:text:nn',
    'close:numeric:n',
    'qty_open:integer:n',
    'cost_basis:numeric:n',
    'market_value:numeric:n',
    'unrealized_pnl:numeric:n',
    'unrealized_pct:numeric:n',
    'realized_to_date:numeric:n',
    'stop_current:numeric:n',
    'dist_to_stop_pct:numeric:n'
  ]::text[],
  'table marks: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.positions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'signal_id:bigint:nn',
    'symbol:text:nn',
    'status:text:nn',
    'planned_size_pct:numeric:nn',
    'cost_pct:numeric:nn',
    'entry_low:numeric:n',
    'entry_high:numeric:n',
    'window_start:date:n',
    'window_end:date:n',
    'stop_initial:numeric:n',
    'fill_date:date:n',
    'fill_price:numeric:n',
    'qty_initial:integer:n',
    'qty_open:integer:nn',
    'avg_cost:numeric:n',
    'gross_bought:numeric:nn',
    'stop_at_fill:numeric:n',
    'stop_current:numeric:n',
    'trim_price:numeric:n',
    'trimmed:boolean:nn',
    'exit_date:date:n',
    'exit_price:numeric:n',
    'exit_reason:text:n',
    'realized_pnl:numeric:nn',
    'costs:numeric:nn'
  ]::text[],
  'table positions: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.price_bars'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'symbol:text:nn',
    'bar_date:date:nn',
    'open:numeric:nn',
    'high:numeric:nn',
    'low:numeric:nn',
    'close:numeric:nn',
    'volume:bigint:n',
    'source:text:n',
    'inserted_at:timestamp with time zone:nn'
  ]::text[],
  'table price_bars: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.reviews'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'run_id:bigint:n',
    'review_date:date:nn',
    'period:text:nn',
    'stats:jsonb:n',
    'observations:text:n',
    'lessons:text:n',
    'proposed_change:text:n',
    'proposal_status:text:nn',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table reviews: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.runs'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'run_type:text:nn',
    'trigger_id:text:n',
    'session_id:text:n',
    'started_at:timestamp with time zone:nn',
    'finished_at:timestamp with time zone:n',
    'data_as_of:date:n',
    'model:text:n',
    'skill_version:text:n',
    'status:text:nn',
    'data_calls:jsonb:n',
    'summary:text:n',
    'report_ref:text:n',
    'notes:text:n'
  ]::text[],
  'table runs: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.signal_exclusions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'signal_id:bigint:nn',
    'batch:text:nn',
    'reason:text:nn',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table signal_exclusions: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.signal_rationale'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'signal_id:bigint:nn',
    'run_id:bigint:n',
    'thesis:text:nn',
    'catalyst:text:n',
    'risks:text:n',
    'invalidation:text:n',
    'alternatives:text:n',
    'data_gaps:text:n',
    'confidence:smallint:n',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table signal_rationale: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.signals'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'run_id:bigint:n',
    'created_at:timestamp with time zone:nn',
    'symbol:text:nn',
    'exchange:text:nn',
    'signal_date:date:nn',
    'source:text:nn',
    'verdict:text:nn',
    'provisional:boolean:nn',
    'setup:text:n',
    'stage:integer:n',
    'why_grade:text:n',
    'why_text:text:n',
    'signal_close:numeric:n',
    'pivot:numeric:n',
    'alert_trigger:numeric:n',
    'entry_low:numeric:n',
    'entry_high:numeric:n',
    'stop:numeric:n',
    'stop_basis:text:n',
    'trim_price:numeric:n',
    'size_pct:numeric:n',
    'risk_pct:numeric:n',
    'vol_mult:numeric:n',
    'req_vol_mult:numeric:n',
    'req_vol_abs:bigint:n',
    'sma13:numeric:n',
    'sma13_rising:boolean:n',
    'dist_sma_pct:numeric:n',
    'correction_pct:numeric:n',
    'base_range_pct:numeric:n',
    'close_loc:numeric:n',
    'liquidity_tier:text:nn',
    'priority_rank:integer:n',
    'window_start:date:n',
    'window_end:date:n',
    'skill_version:text:n',
    'retro_seeded:boolean:nn',
    'supersedes:bigint:n',
    'notes:text:n',
    'raw:jsonb:n'
  ]::text[],
  'table signals: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.skill_versions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'version:text:nn',
    'effective_from:date:nn',
    'sha256:text:n',
    'summary:text:n',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table skill_versions: columns, types and nullability match the baseline');

select is(
  (select array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || case when a.attnotnull then 'nn' else 'n' end order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.trade_reviews'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'id:bigint:nn',
    'signal_id:bigint:nn',
    'symbol:text:nn',
    'run_id:bigint:n',
    'tag:text:nn',
    'lesson:text:n',
    'author:text:nn',
    'created_at:timestamp with time zone:nn'
  ]::text[],
  'table trade_reviews: columns, types and nullability match the baseline');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:13] from pg_attribute a
    where a.attrelid = 'public.v_activity'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'ts:timestamp with time zone',
    'd:date',
    'kind:text',
    'symbol:text',
    'what:text',
    'source:text',
    'provisional:boolean',
    'price:numeric',
    'qty:integer',
    'pnl:numeric',
    'detail:text',
    'signal_id:bigint',
    'position_id:bigint'
  ]::text[],
  'view v_activity: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_activity'::regclass), 'view v_activity runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:16] from pg_attribute a
    where a.attrelid = 'public.v_book_risk'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'as_of:date',
    'capital:numeric',
    'equity:numeric',
    'cash:numeric',
    'invested:numeric',
    'cash_pct:numeric',
    'open_positions:bigint',
    'max_open_positions:integer',
    'open_risk_rupees:numeric',
    'open_risk_pct:numeric',
    'risk_vs_cost_rupees:numeric',
    'avg_dist_to_stop_pct:numeric',
    'avg_dist_to_trim_pct:numeric',
    'pending_entries:bigint',
    'pending_committed_rupees:numeric',
    'cash_after_pending:numeric'
  ]::text[],
  'view v_book_risk: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_book_risk'::regclass), 'view v_book_risk runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:11] from pg_attribute a
    where a.attrelid = 'public.v_equity_daily'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'as_of:date',
    'capital:numeric',
    'cash:numeric',
    'invested:numeric',
    'market_value:numeric',
    'realized_cum:numeric',
    'unrealized:numeric',
    'equity:numeric',
    'day_pnl:numeric',
    'return_pct:numeric',
    'open_positions:bigint'
  ]::text[],
  'view v_equity_daily: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_equity_daily'::regclass), 'view v_equity_daily runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:43] from pg_attribute a
    where a.attrelid = 'public.v_open_positions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'position_id:bigint',
    'signal_id:bigint',
    'symbol:text',
    'verdict:text',
    'why_grade:text',
    'setup:text',
    'source:text',
    'skill_version:text',
    'signal_date:date',
    'signal_close:numeric',
    'pivot:numeric',
    'vol_mult:numeric',
    'correction_pct:numeric',
    'base_range_pct:numeric',
    'dist_sma_pct:numeric',
    'retro_seeded:boolean',
    'status:text',
    'planned_size_pct:numeric',
    'fill_date:date',
    'fill_price:numeric',
    'qty_initial:integer',
    'qty_open:integer',
    'avg_cost:numeric',
    'gross_bought:numeric',
    'stop_at_fill:numeric',
    'stop_current:numeric',
    'trim_price:numeric',
    'trimmed:boolean',
    'exit_date:date',
    'exit_price:numeric',
    'exit_reason:text',
    'realized_pnl:numeric',
    'costs:numeric',
    'realized_return_pct:numeric',
    'r_multiple:numeric',
    'days_held:integer',
    'mark_date:date',
    'last_close:numeric',
    'market_value:numeric',
    'unrealized_pnl:numeric',
    'unrealized_pct:numeric',
    'dist_to_stop_pct:numeric',
    'dist_to_trim_pct:numeric'
  ]::text[],
  'view v_open_positions: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_open_positions'::regclass), 'view v_open_positions runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:7] from pg_attribute a
    where a.attrelid = 'public.v_pnl_monthly'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'month:date',
    'equity_end:numeric',
    'pnl:numeric',
    'return_pct:numeric',
    'realized:numeric',
    'trades_closed:bigint',
    'winners:bigint'
  ]::text[],
  'view v_pnl_monthly: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_pnl_monthly'::regclass), 'view v_pnl_monthly runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:5] from pg_attribute a
    where a.attrelid = 'public.v_pnl_yearly'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'year:integer',
    'equity_end:numeric',
    'pnl:numeric',
    'return_pct:numeric',
    'trades_closed:bigint'
  ]::text[],
  'view v_pnl_yearly: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_pnl_yearly'::regclass), 'view v_pnl_yearly runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:36] from pg_attribute a
    where a.attrelid = 'public.v_positions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'position_id:bigint',
    'signal_id:bigint',
    'symbol:text',
    'verdict:text',
    'why_grade:text',
    'setup:text',
    'source:text',
    'skill_version:text',
    'signal_date:date',
    'signal_close:numeric',
    'pivot:numeric',
    'vol_mult:numeric',
    'correction_pct:numeric',
    'base_range_pct:numeric',
    'dist_sma_pct:numeric',
    'retro_seeded:boolean',
    'status:text',
    'planned_size_pct:numeric',
    'fill_date:date',
    'fill_price:numeric',
    'qty_initial:integer',
    'qty_open:integer',
    'avg_cost:numeric',
    'gross_bought:numeric',
    'stop_at_fill:numeric',
    'stop_current:numeric',
    'trim_price:numeric',
    'trimmed:boolean',
    'exit_date:date',
    'exit_price:numeric',
    'exit_reason:text',
    'realized_pnl:numeric',
    'costs:numeric',
    'realized_return_pct:numeric',
    'r_multiple:numeric',
    'days_held:integer'
  ]::text[],
  'view v_positions: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_positions'::regclass), 'view v_positions runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:7] from pg_attribute a
    where a.attrelid = 'public.v_rule_effectiveness'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'ord:integer',
    'rule:text',
    'status:text',
    'trades:bigint',
    'winners:bigint',
    'avg_r:numeric',
    'avg_return_pct:numeric'
  ]::text[],
  'view v_rule_effectiveness: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_rule_effectiveness'::regclass), 'view v_rule_effectiveness runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:16] from pg_attribute a
    where a.attrelid = 'public.v_run_log'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'run_id:bigint',
    'run_type:text',
    'data_as_of:date',
    'started_at:timestamp with time zone',
    'skill_version:text',
    'model:text',
    'status:text',
    'summary:text',
    'data_calls:jsonb',
    'notes:text',
    'verdicts:jsonb',
    'observations:text',
    'lessons:text',
    'proposed_change:text',
    'proposal_status:text',
    'review_stats:jsonb'
  ]::text[],
  'view v_run_log: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_run_log'::regclass), 'view v_run_log runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:10] from pg_attribute a
    where a.attrelid = 'public.v_signal_checklist'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'signal_id:bigint',
    'symbol:text',
    'verdict:text',
    'signal_date:date',
    'excluded:boolean',
    'ord:integer',
    'rule:text',
    'measured:text',
    'target:text',
    'status:text'
  ]::text[],
  'view v_signal_checklist: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_signal_checklist'::regclass), 'view v_signal_checklist runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:20] from pg_attribute a
    where a.attrelid = 'public.v_signal_outcomes'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'signal_id:bigint',
    'symbol:text',
    'signal_date:date',
    'source:text',
    'verdict:text',
    'provisional:boolean',
    'why_grade:text',
    'skill_version:text',
    'retro_seeded:boolean',
    'signal_close:numeric',
    'alert_trigger:numeric',
    'stop:numeric',
    'trigger_hit_date:date',
    'stop_touch_date:date',
    'ret_1w_pct:numeric',
    'ret_4w_pct:numeric',
    'ret_13w_pct:numeric',
    'max_up_4w_pct:numeric',
    'max_down_4w_pct:numeric',
    'last_bar:date'
  ]::text[],
  'view v_signal_outcomes: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_signal_outcomes'::regclass), 'view v_signal_outcomes runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:32] from pg_attribute a
    where a.attrelid = 'public.v_signal_plan'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'signal_id:bigint',
    'run_id:bigint',
    'symbol:text',
    'signal_date:date',
    'verdict:text',
    'setup:text',
    'stage:integer',
    'why_grade:text',
    'priority_rank:integer',
    'excluded:boolean',
    'retro_seeded:boolean',
    'skill_version:text',
    'entry_ref:numeric',
    'entry_high:numeric',
    'stop_ref:numeric',
    'trim_ref:numeric',
    'size_pct:numeric',
    'risk_pct_plan:numeric',
    'reward_pct_plan:numeric',
    'rr_plan:numeric',
    'position_value:numeric',
    'rupee_risk:numeric',
    'rupee_reward_at_trim:numeric',
    'capital_risk_pct:numeric',
    'passes:bigint',
    'weak:bigint',
    'fails:bigint',
    'failed_rules:text',
    'book_status:text',
    'book_reason:text',
    'fill_price:numeric',
    'fill_date:date'
  ]::text[],
  'view v_signal_plan: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_signal_plan'::regclass), 'view v_signal_plan runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:50] from pg_attribute a
    where a.attrelid = 'public.v_suggestions'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'bucket:text',
    'signal_id:bigint',
    'run_id:bigint',
    'symbol:text',
    'signal_date:date',
    'verdict:text',
    'setup:text',
    'stage:integer',
    'why_grade:text',
    'priority_rank:integer',
    'excluded:boolean',
    'retro_seeded:boolean',
    'skill_version:text',
    'entry_ref:numeric',
    'entry_high:numeric',
    'stop_ref:numeric',
    'trim_ref:numeric',
    'size_pct:numeric',
    'risk_pct_plan:numeric',
    'reward_pct_plan:numeric',
    'rr_plan:numeric',
    'position_value:numeric',
    'rupee_risk:numeric',
    'rupee_reward_at_trim:numeric',
    'capital_risk_pct:numeric',
    'passes:bigint',
    'weak:bigint',
    'fails:bigint',
    'failed_rules:text',
    'book_status:text',
    'book_reason:text',
    'fill_price:numeric',
    'fill_date:date',
    'why_text:text',
    'notes:text',
    'pivot:numeric',
    'alert_trigger:numeric',
    'req_vol_abs:bigint',
    'vol_mult:numeric',
    'window_start:date',
    'window_end:date',
    'thesis:text',
    'catalyst:text',
    'risks:text',
    'invalidation:text',
    'alternatives:text',
    'data_gaps:text',
    'confidence:smallint',
    'book_cash:numeric',
    'fundable_now:boolean'
  ]::text[],
  'view v_suggestions: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_suggestions'::regclass), 'view v_suggestions runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:36] from pg_attribute a
    where a.attrelid = 'public.v_trade_review'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'position_id:bigint',
    'signal_id:bigint',
    'symbol:text',
    'verdict:text',
    'why_grade:text',
    'setup:text',
    'vol_mult:numeric',
    'dist_sma_pct:numeric',
    'correction_pct:numeric',
    'status:text',
    'fill_date:date',
    'fill_price:numeric',
    'stop_at_fill:numeric',
    'trim_price:numeric',
    'exit_date:date',
    'exit_price:numeric',
    'exit_reason:text',
    'realized_pnl:numeric',
    'r_multiple:numeric',
    'days_held:integer',
    'rr_plan:numeric',
    'passes:bigint',
    'weak:bigint',
    'fails:bigint',
    'failed_rules:text',
    'ledger_risk_pct:numeric',
    'skill_stop:numeric',
    'mfe_pct:numeric',
    'mae_pct:numeric',
    'worst_since_fill_pct:numeric',
    'skill_stop_still_intact:boolean',
    'post_exit_run_pct:numeric',
    'auto_tag:text',
    'review_tag:text',
    'review_lesson:text',
    'review_author:text'
  ]::text[],
  'view v_trade_review: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_trade_review'::regclass), 'view v_trade_review runs with security_invoker');

select is(
  (select (array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) order by a.attnum))[1:14] from pg_attribute a
    where a.attrelid = 'public.v_trade_stats'::regclass and a.attnum > 0 and not a.attisdropped),
  array[
    'grp:integer',
    'verdict:text',
    'why_grade:text',
    'setup:text',
    'skill_version:text',
    'closed:bigint',
    'open:bigint',
    'not_filled:bigint',
    'win_rate_pct:numeric',
    'avg_return_pct:numeric',
    'avg_r:numeric',
    'avg_days_held:numeric',
    'realized_pnl:numeric',
    'dimension:text'
  ]::text[],
  'view v_trade_stats: baseline columns present, in baseline order, with baseline types');

select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.v_trade_stats'::regclass), 'view v_trade_stats runs with security_invoker');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.config'::regclass),
  array[
    'config_pkey PRIMARY KEY (key)'
  ]::text[],
  'table config: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'config'),
  array[
    'CREATE UNIQUE INDEX config_pkey ON public.config USING btree (key)'
  ]::text[],
  'table config: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.events'::regclass),
  array[
    'events_event_type_check CHECK ((event_type = ANY (ARRAY[''fill''::text, ''add''::text, ''trim''::text, ''reduce''::text, ''stop_raise''::text, ''stop_hit''::text, ''exit''::text, ''expire''::text, ''skip''::text])))',
    'events_pkey PRIMARY KEY (id)',
    'events_position_id_fkey FOREIGN KEY (position_id) REFERENCES positions(id) ON DELETE CASCADE',
    'events_signal_id_fkey FOREIGN KEY (signal_id) REFERENCES signals(id)',
    'events_trigger_signal_id_fkey FOREIGN KEY (trigger_signal_id) REFERENCES signals(id)'
  ]::text[],
  'table events: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'events'),
  array[
    'CREATE INDEX events_date_idx ON public.events USING btree (event_date)',
    'CREATE UNIQUE INDEX events_pkey ON public.events USING btree (id)',
    'CREATE INDEX events_position_idx ON public.events USING btree (position_id)',
    'CREATE INDEX events_signal_idx ON public.events USING btree (signal_id)',
    'CREATE INDEX events_trigger_sig_idx ON public.events USING btree (trigger_signal_id)'
  ]::text[],
  'table events: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.marks'::regclass),
  array[
    'marks_pkey PRIMARY KEY (position_id, mark_date)',
    'marks_position_id_fkey FOREIGN KEY (position_id) REFERENCES positions(id) ON DELETE CASCADE'
  ]::text[],
  'table marks: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'marks'),
  array[
    'CREATE INDEX marks_date_idx ON public.marks USING btree (mark_date)',
    'CREATE UNIQUE INDEX marks_pkey ON public.marks USING btree (position_id, mark_date)'
  ]::text[],
  'table marks: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.positions'::regclass),
  array[
    'positions_pkey PRIMARY KEY (id)',
    'positions_signal_id_fkey FOREIGN KEY (signal_id) REFERENCES signals(id)',
    'positions_signal_id_key UNIQUE (signal_id)',
    'positions_status_check CHECK ((status = ANY (ARRAY[''pending''::text, ''open''::text, ''closed''::text, ''expired''::text, ''skipped''::text])))'
  ]::text[],
  'table positions: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'positions'),
  array[
    'CREATE UNIQUE INDEX positions_pkey ON public.positions USING btree (id)',
    'CREATE UNIQUE INDEX positions_signal_id_key ON public.positions USING btree (signal_id)',
    'CREATE INDEX positions_symbol_idx ON public.positions USING btree (symbol)'
  ]::text[],
  'table positions: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.price_bars'::regclass),
  array[
    'price_bars_pkey PRIMARY KEY (symbol, bar_date)'
  ]::text[],
  'table price_bars: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'price_bars'),
  array[
    'CREATE UNIQUE INDEX price_bars_pkey ON public.price_bars USING btree (symbol, bar_date)'
  ]::text[],
  'table price_bars: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.reviews'::regclass),
  array[
    'reviews_period_check CHECK ((period = ANY (ARRAY[''weekly''::text, ''monthly''::text, ''quarterly''::text, ''adhoc''::text])))',
    'reviews_pkey PRIMARY KEY (id)',
    'reviews_proposal_status_check CHECK ((proposal_status = ANY (ARRAY[''none''::text, ''proposed''::text, ''approved''::text, ''rejected''::text, ''applied''::text])))',
    'reviews_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id)'
  ]::text[],
  'table reviews: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'reviews'),
  array[
    'CREATE UNIQUE INDEX reviews_pkey ON public.reviews USING btree (id)',
    'CREATE INDEX reviews_run_idx ON public.reviews USING btree (run_id)'
  ]::text[],
  'table reviews: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.runs'::regclass),
  array[
    'runs_pkey PRIMARY KEY (id)',
    'runs_run_type_check CHECK ((run_type = ANY (ARRAY[''weekly_scan''::text, ''midweek_checkin''::text, ''adhoc''::text, ''backfill''::text, ''processing''::text])))',
    'runs_skill_version_fkey FOREIGN KEY (skill_version) REFERENCES skill_versions(version)',
    'runs_status_check CHECK ((status = ANY (ARRAY[''running''::text, ''succeeded''::text, ''partial''::text, ''failed''::text])))'
  ]::text[],
  'table runs: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'runs'),
  array[
    'CREATE UNIQUE INDEX runs_pkey ON public.runs USING btree (id)',
    'CREATE INDEX runs_skill_idx ON public.runs USING btree (skill_version)'
  ]::text[],
  'table runs: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.signal_exclusions'::regclass),
  array[
    'signal_exclusions_pkey PRIMARY KEY (signal_id)',
    'signal_exclusions_signal_id_fkey FOREIGN KEY (signal_id) REFERENCES signals(id)'
  ]::text[],
  'table signal_exclusions: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'signal_exclusions'),
  array[
    'CREATE UNIQUE INDEX signal_exclusions_pkey ON public.signal_exclusions USING btree (signal_id)'
  ]::text[],
  'table signal_exclusions: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.signal_rationale'::regclass),
  array[
    'signal_rationale_confidence_check CHECK (((confidence >= 1) AND (confidence <= 5)))',
    'signal_rationale_pkey PRIMARY KEY (signal_id)',
    'signal_rationale_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id)',
    'signal_rationale_signal_id_fkey FOREIGN KEY (signal_id) REFERENCES signals(id)'
  ]::text[],
  'table signal_rationale: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'signal_rationale'),
  array[
    'CREATE UNIQUE INDEX signal_rationale_pkey ON public.signal_rationale USING btree (signal_id)'
  ]::text[],
  'table signal_rationale: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.signals'::regclass),
  array[
    'signals_liquidity_tier_check CHECK ((liquidity_tier = ANY (ARRAY[''liquid''::text, ''thin''::text])))',
    'signals_pkey PRIMARY KEY (id)',
    'signals_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id)',
    'signals_setup_check CHECK ((setup = ANY (ARRAY[''A_base''::text, ''B_flag''::text, ''holding''::text, ''other''::text])))',
    'signals_skill_version_fkey FOREIGN KEY (skill_version) REFERENCES skill_versions(version)',
    'signals_source_check CHECK ((source = ANY (ARRAY[''weekly_scan''::text, ''midweek_checkin''::text, ''adhoc''::text, ''backfill''::text])))',
    'signals_stage_check CHECK (((stage >= 1) AND (stage <= 4)))',
    'signals_stop_basis_check CHECK ((stop_basis = ANY (ARRAY[''structural''::text, ''cap8''::text, ''higher_low''::text, ''sma''::text, ''other''::text])))',
    'signals_supersedes_fkey FOREIGN KEY (supersedes) REFERENCES signals(id)',
    'signals_verdict_check CHECK ((verdict = ANY (ARRAY[''ENTRY''::text, ''ENTRY_REDUCED''::text, ''WAIT''::text, ''WAIT_ALERT''::text, ''NO_GO''::text, ''TRIM''::text, ''ADD''::text, ''HOLD''::text, ''REDUCE''::text, ''EXIT''::text])))',
    'signals_why_grade_check CHECK ((why_grade = ANY (ARRAY[''A''::text, ''B''::text, ''C''::text, ''D''::text])))'
  ]::text[],
  'table signals: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'signals'),
  array[
    'CREATE UNIQUE INDEX signals_pkey ON public.signals USING btree (id)',
    'CREATE INDEX signals_run_idx ON public.signals USING btree (run_id)',
    'CREATE INDEX signals_skill_idx ON public.signals USING btree (skill_version)',
    'CREATE INDEX signals_supersedes_idx ON public.signals USING btree (supersedes)',
    'CREATE INDEX signals_symbol_date_idx ON public.signals USING btree (symbol, signal_date)',
    'CREATE INDEX signals_verdict_idx ON public.signals USING btree (verdict)'
  ]::text[],
  'table signals: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.skill_versions'::regclass),
  array[
    'skill_versions_pkey PRIMARY KEY (version)'
  ]::text[],
  'table skill_versions: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'skill_versions'),
  array[
    'CREATE UNIQUE INDEX skill_versions_pkey ON public.skill_versions USING btree (version)'
  ]::text[],
  'table skill_versions: indexes match the baseline');

select is(
  (select array_agg(conname || ' ' || pg_get_constraintdef(oid) order by conname) from pg_constraint
    where conrelid = 'public.trade_reviews'::regclass),
  array[
    'trade_reviews_author_check CHECK ((author = ANY (ARRAY[''agent''::text, ''rajat''::text])))',
    'trade_reviews_pkey PRIMARY KEY (id)',
    'trade_reviews_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id)',
    'trade_reviews_signal_id_fkey FOREIGN KEY (signal_id) REFERENCES signals(id)',
    'trade_reviews_tag_check CHECK ((tag = ANY (ARRAY[''good_call''::text, ''winner''::text, ''valid_stop''::text, ''whipsaw_tight_stop''::text, ''gap_through_stop''::text, ''missed_runner''::text, ''avoided_loser''::text, ''bad_entry''::text, ''rule_violation''::text, ''data_gap''::text, ''removed_fresh_start''::text, ''other''::text])))'
  ]::text[],
  'table trade_reviews: constraints match the baseline');

select is(
  (select array_agg(indexdef order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'trade_reviews'),
  array[
    'CREATE UNIQUE INDEX trade_reviews_pkey ON public.trade_reviews USING btree (id)',
    'CREATE INDEX trade_reviews_signal_idx ON public.trade_reviews USING btree (signal_id)'
  ]::text[],
  'table trade_reviews: indexes match the baseline');

select is(
  (select pg_get_triggerdef(oid) from pg_trigger where tgname = 'signals_append_only' and tgrelid = 'signals'::regclass),
  'CREATE TRIGGER signals_append_only BEFORE DELETE OR UPDATE ON public.signals FOR EACH ROW EXECUTE FUNCTION block_signal_mutation()',
  'trigger signals_append_only on signals matches the baseline');

select * from finish();
rollback;
