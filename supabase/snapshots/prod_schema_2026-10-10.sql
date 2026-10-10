


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."_ledger_manage"("v_pid" bigint, "d" "date") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_capital numeric := cfg_num('paper_capital');
  v_cap_pct numeric := cfg_num('position_cap_pct');
  v_trim_frac numeric := cfg_num('trim_fraction');
  b price_bars%rowtype; po positions%rowtype; s signals%rowtype;
  v_cash numeric; v_add int; v_c numeric;
begin
  select * into po from positions where id = v_pid;
  if po.status <> 'open' then return; end if;
  select * into b from price_bars where symbol = po.symbol and bar_date = d;
  if not found then return; end if;

  for s in select * from signals z
            where z.symbol = po.symbol and not z.provisional
              and z.verdict in ('TRIM','ADD','REDUCE','EXIT','HOLD')
              and z.signal_date >= po.fill_date and z.signal_date < d
              and not exists (select 1 from signals y where y.supersedes = z.id)
              and not exists (select 1 from events e where e.trigger_signal_id = z.id and e.position_id = v_pid)
            order by z.signal_date, z.id loop
    select * into po from positions where id = v_pid;
    exit when po.status <> 'open';
    if s.verdict = 'EXIT' then
      perform _ledger_sell(v_pid, d, b.open, po.qty_open, 'exit', 'EXIT verdict: sell all at next session open', s.id);
    elsif s.verdict = 'REDUCE' then
      perform _ledger_sell(v_pid, d, b.open, greatest(1, floor(po.qty_open / 2.0)::int), 'reduce', 'REDUCE verdict: sell half at next open', s.id);
    elsif s.verdict = 'TRIM' and not po.trimmed then
      perform _ledger_sell(v_pid, d, b.open, greatest(1, floor(po.qty_open * v_trim_frac)::int), 'trim', 'TRIM verdict: next open', s.id);
      update positions set trimmed = true where id = v_pid;
    elsif s.verdict = 'ADD' then
      v_cash := v_capital + coalesce((select sum(pnl) from events), 0)
                - coalesce((select sum(qty_open * avg_cost) from positions where status = 'open'), 0);
      v_add := floor(greatest(0, least(v_capital * coalesce(s.size_pct, v_cap_pct / 2) / 100,
                                       v_capital * v_cap_pct / 100 - po.qty_open * b.open, v_cash)) / b.open);
      if v_add >= 1 then
        v_c := round(v_add * b.open * po.cost_pct / 200, 2);
        update positions set avg_cost = round((qty_open * avg_cost + v_add * b.open) / (qty_open + v_add), 4),
               qty_open = qty_open + v_add, gross_bought = gross_bought + v_add * b.open,
               costs = costs + v_c, realized_pnl = realized_pnl - v_c
         where id = v_pid;
        insert into events(position_id, signal_id, trigger_signal_id, symbol, event_date, event_type, price, qty, pnl, cost, rule)
        values (v_pid, po.signal_id, s.id, po.symbol, d, 'add', b.open, v_add, -v_c, v_c, 'ADD verdict: buy at next open within the 10% cap');
      end if;
    end if;
    select * into po from positions where id = v_pid;
    if po.status = 'open' and s.stop is not null and s.stop > po.stop_current then
      update positions set stop_current = s.stop where id = v_pid;
      insert into events(position_id, signal_id, trigger_signal_id, symbol, event_date, event_type, price, rule)
      values (v_pid, po.signal_id, s.id, po.symbol, d, 'stop_raise', s.stop, concat(s.verdict, ' signal raised the stop; stops are never lowered'));
    end if;
  end loop;

  select * into po from positions where id = v_pid;
  if po.status = 'open' and b.low <= po.stop_current then
    perform _ledger_sell(v_pid, d, least(b.open, po.stop_current), po.qty_open, 'stop_hit',
      case when b.open < po.stop_current then 'gapped through stop: filled at open'
           else 'daily low touched stop (stop assumed before trim)' end, null);
  elsif po.status = 'open' and not po.trimmed and b.high >= po.trim_price then
    perform _ledger_sell(v_pid, d, greatest(b.open, po.trim_price), greatest(1, floor(po.qty_open * v_trim_frac)::int),
      'trim', 'daily high reached trim level (fill x 1.25)', null);
    update positions set trimmed = true where id = v_pid;
  end if;
end $$;


ALTER FUNCTION "public"."_ledger_manage"("v_pid" bigint, "d" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_ledger_pending"("v_pid" bigint, "d" "date") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_capital numeric := cfg_num('paper_capital');
  v_max_open int := cfg_num('max_open_positions')::int;
  v_trim_mult numeric := cfg_num('trim_multiple');
  v_stop_cap numeric := cfg_num('stop_cap_pct');
  b price_bars%rowtype; po positions%rowtype; sg signals%rowtype;
  v_fill numeric; v_qty int; v_stop numeric; v_cash numeric; v_c numeric; v_budget numeric;
begin
  select * into po from positions where id = v_pid;
  if po.status <> 'pending' then return; end if;
  if d > po.window_end then
    update positions set status = 'expired', exit_reason = 'no fill in window' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'expire', 'window ended without a fill');
    return;
  end if;
  if d < po.window_start then return; end if;
  select * into b from price_bars where symbol = po.symbol and bar_date = d;
  if not found then return; end if;
  select * into sg from signals where id = po.signal_id;
  if b.open <= po.stop_initial then
    update positions set status = 'skipped', exit_reason = 'opened at/below stop' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, price, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'skip', b.open, 'session opened at or below the stop before any fill');
    return;
  end if;
  if b.low > po.entry_high then return; end if;
  if exists (select 1 from positions where status = 'open' and symbol = po.symbol) then
    update positions set status = 'skipped', exit_reason = 'already holding' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'skip', 'already holding this symbol');
    return;
  end if;
  if (select count(*) from positions where status = 'open') >= v_max_open then
    update positions set status = 'skipped', exit_reason = 'max open positions' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'skip', 'max open positions reached');
    return;
  end if;
  v_fill := least(b.open, po.entry_high);
  -- planned size cannot buy a single share at this price (small paper capital vs high-priced stock)
  v_budget := v_capital * po.planned_size_pct / 100;
  if floor(v_budget / v_fill) < 1 then
    update positions set status = 'skipped', exit_reason = 'size_below_1_share' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, price, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'skip', v_fill,
            concat('planned size Rs ', round(v_budget, 2), ' is below one share at Rs ', v_fill));
    return;
  end if;
  v_cash := v_capital + coalesce((select sum(pnl) from events), 0)
            - coalesce((select sum(qty_open * avg_cost) from positions where status = 'open'), 0);
  v_qty := floor(least(v_budget, v_cash) / v_fill);
  if v_qty < 1 then
    update positions set status = 'skipped', exit_reason = 'insufficient cash' where id = v_pid;
    insert into events(position_id, signal_id, symbol, event_date, event_type, rule)
    values (v_pid, po.signal_id, po.symbol, d, 'skip', 'insufficient paper cash');
    return;
  end if;
  v_stop := greatest(coalesce(round(sg.pivot * 0.99, 2), po.stop_initial), round(v_fill * (1 - v_stop_cap / 100), 2));
  v_c := round(v_qty * v_fill * po.cost_pct / 200, 2);
  update positions set status = 'open', fill_date = d, fill_price = v_fill, qty_initial = v_qty, qty_open = v_qty,
         avg_cost = v_fill, gross_bought = v_qty * v_fill, stop_at_fill = v_stop, stop_current = v_stop,
         trim_price = round(v_fill * v_trim_mult, 2), costs = v_c, realized_pnl = -v_c
   where id = v_pid;
  insert into events(position_id, signal_id, symbol, event_date, event_type, price, qty, pnl, cost, rule)
  values (v_pid, po.signal_id, po.symbol, d, 'fill', v_fill, v_qty, -v_c, v_c,
          'limit buy at entry_high; fill = min(open, entry_high); stop = max(pivot*0.99, fill*0.92)');
end $$;


ALTER FUNCTION "public"."_ledger_pending"("v_pid" bigint, "d" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_ledger_sell"("p_id" bigint, "d" "date", "px" numeric, "q" integer, "etype" "text", "why" "text", "trig" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare p positions%rowtype; c numeric; pl numeric;
begin
  select * into p from positions where id = p_id;
  if q is null or q < 1 or p.qty_open < 1 then return; end if;
  q := least(q, p.qty_open);
  c  := round(q * px * p.cost_pct / 200, 2);
  pl := round(q * (px - p.avg_cost), 2) - c;
  update positions set qty_open = qty_open - q, realized_pnl = realized_pnl + pl, costs = costs + c,
         status = case when qty_open - q = 0 then 'closed' else status end,
         exit_date = case when qty_open - q = 0 then d end,
         exit_price = case when qty_open - q = 0 then px end,
         exit_reason = case when qty_open - q = 0 then etype end
   where id = p_id;
  insert into events(position_id, signal_id, trigger_signal_id, symbol, event_date, event_type, price, qty, pnl, cost, rule)
  values (p_id, p.signal_id, trig, p.symbol, d, etype, px, q, pl, c, why);
end $$;


ALTER FUNCTION "public"."_ledger_sell"("p_id" bigint, "d" "date", "px" numeric, "q" integer, "etype" "text", "why" "text", "trig" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_signal_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if coalesce(current_setting('tracker.allow_signal_edit', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'signals are append-only: insert a new row with supersedes = % instead', old.id;
end $$;


ALTER FUNCTION "public"."block_signal_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cfg_num"("k" "text") RETURNS numeric
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$ select (value #>> '{}')::numeric from public.config where key = k $$;


ALTER FUNCTION "public"."cfg_num"("k" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_ledger"("p_through" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_cap_pct numeric := cfg_num('position_cap_pct');
  v_risk numeric := cfg_num('risk_per_trade_pct');
  v_red numeric := cfg_num('reduced_size_multiple');
  v_cl numeric := cfg_num('cost_roundtrip_pct_liquid');
  v_ct numeric := cfg_num('cost_roundtrip_pct_thin');
  d date; p record;
begin
  -- derived tables are rebuilt from signals + price_bars on every call
  delete from marks where true;
  delete from events where true;
  delete from positions where true;

  insert into positions(signal_id, symbol, planned_size_pct, cost_pct, entry_low, entry_high, window_start, window_end, stop_initial)
  select x.id, x.symbol,
         coalesce(x.size_pct,
           least(v_cap_pct, case when coalesce(x.risk_pct, 0) > 0 then v_risk / x.risk_pct * 100 else v_cap_pct end)
           * case when x.verdict = 'ENTRY_REDUCED' then v_red else 1 end),
         case x.liquidity_tier when 'thin' then v_ct else v_cl end,
         x.entry_low, x.entry_high, x.window_start, x.window_end, x.stop
    from signals x
   where x.verdict in ('ENTRY','ENTRY_REDUCED') and not x.provisional
     and not exists (select 1 from signals y where y.supersedes = x.id)
   order by x.signal_date, x.id;

  for d in select distinct pb.bar_date from price_bars pb
            where pb.bar_date <= p_through
              and pb.bar_date >= coalesce((select min(window_start) from positions), p_through)
            order by 1 loop
    for p in select q.id, q.status from positions q join signals g on g.id = q.signal_id
              where q.status in ('pending','open')
              order by g.priority_rank nulls last, q.id loop
      if p.status = 'pending' then perform _ledger_pending(p.id, d); end if;
      perform _ledger_manage(p.id, d);
      insert into marks(position_id, mark_date, symbol, close, qty_open, cost_basis, market_value, unrealized_pnl, unrealized_pct,
                        realized_to_date, stop_current, dist_to_stop_pct)
      select q.id, d, q.symbol, b.close, q.qty_open, round(q.qty_open * q.avg_cost, 2), round(q.qty_open * b.close, 2),
             round(q.qty_open * (b.close - q.avg_cost), 2),
             case when q.qty_open > 0 then round((b.close / q.avg_cost - 1) * 100, 2) end,
             q.realized_pnl, q.stop_current,
             case when q.qty_open > 0 then round((b.close / q.stop_current - 1) * 100, 2) end
        from positions q join price_bars b on b.symbol = q.symbol and b.bar_date = d
       where q.id = p.id and (q.status = 'open' or (q.status = 'closed' and q.exit_date = d));
    end loop;
  end loop;

  insert into events(position_id, signal_id, symbol, event_date, event_type, rule)
  select id, signal_id, symbol, window_end, 'expire', 'window ended without a fill (no price data in window)'
    from positions where status = 'pending' and window_end < p_through;
  update positions set status = 'expired', exit_reason = 'no fill in window (no price data)'
   where status = 'pending' and window_end < p_through;

  insert into config(key, value, description) values ('processed_through', to_jsonb(p_through::text), 'last date process_ledger replayed to')
  on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object(
    'through', p_through,
    'positions', (select jsonb_object_agg(status, n) from (select status, count(*) n from positions group by status) t),
    'events', (select count(*) from events),
    'realized_pnl', (select coalesce(sum(pnl), 0) from events),
    'open_without_recent_bars', (select coalesce(jsonb_agg(distinct q.symbol), '[]'::jsonb) from positions q
        where q.status = 'open'
          and not exists (select 1 from price_bars pb where pb.symbol = q.symbol and pb.bar_date >= p_through - 4)));
end $$;


ALTER FUNCTION "public"."process_ledger"("p_through" "date") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."config" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" bigint NOT NULL,
    "position_id" bigint,
    "signal_id" bigint,
    "trigger_signal_id" bigint,
    "symbol" "text" NOT NULL,
    "event_date" "date" NOT NULL,
    "event_type" "text" NOT NULL,
    "price" numeric,
    "qty" integer,
    "pnl" numeric DEFAULT 0 NOT NULL,
    "cost" numeric DEFAULT 0 NOT NULL,
    "rule" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "events_event_type_check" CHECK (("event_type" = ANY (ARRAY['fill'::"text", 'add'::"text", 'trim'::"text", 'reduce'::"text", 'stop_raise'::"text", 'stop_hit'::"text", 'exit'::"text", 'expire'::"text", 'skip'::"text"])))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


ALTER TABLE "public"."events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."marks" (
    "position_id" bigint NOT NULL,
    "mark_date" "date" NOT NULL,
    "symbol" "text" NOT NULL,
    "close" numeric,
    "qty_open" integer,
    "cost_basis" numeric,
    "market_value" numeric,
    "unrealized_pnl" numeric,
    "unrealized_pct" numeric,
    "realized_to_date" numeric,
    "stop_current" numeric,
    "dist_to_stop_pct" numeric
);


ALTER TABLE "public"."marks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."positions" (
    "id" bigint NOT NULL,
    "signal_id" bigint NOT NULL,
    "symbol" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "planned_size_pct" numeric NOT NULL,
    "cost_pct" numeric NOT NULL,
    "entry_low" numeric,
    "entry_high" numeric,
    "window_start" "date",
    "window_end" "date",
    "stop_initial" numeric,
    "fill_date" "date",
    "fill_price" numeric,
    "qty_initial" integer,
    "qty_open" integer DEFAULT 0 NOT NULL,
    "avg_cost" numeric,
    "gross_bought" numeric DEFAULT 0 NOT NULL,
    "stop_at_fill" numeric,
    "stop_current" numeric,
    "trim_price" numeric,
    "trimmed" boolean DEFAULT false NOT NULL,
    "exit_date" "date",
    "exit_price" numeric,
    "exit_reason" "text",
    "realized_pnl" numeric DEFAULT 0 NOT NULL,
    "costs" numeric DEFAULT 0 NOT NULL,
    CONSTRAINT "positions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'open'::"text", 'closed'::"text", 'expired'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."positions" OWNER TO "postgres";


ALTER TABLE "public"."positions" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."positions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."price_bars" (
    "symbol" "text" NOT NULL,
    "bar_date" "date" NOT NULL,
    "open" numeric NOT NULL,
    "high" numeric NOT NULL,
    "low" numeric NOT NULL,
    "close" numeric NOT NULL,
    "volume" bigint,
    "source" "text",
    "inserted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."price_bars" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reviews" (
    "id" bigint NOT NULL,
    "run_id" bigint,
    "review_date" "date" NOT NULL,
    "period" "text" NOT NULL,
    "stats" "jsonb",
    "observations" "text",
    "lessons" "text",
    "proposed_change" "text",
    "proposal_status" "text" DEFAULT 'none'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "reviews_period_check" CHECK (("period" = ANY (ARRAY['weekly'::"text", 'monthly'::"text", 'quarterly'::"text", 'adhoc'::"text"]))),
    CONSTRAINT "reviews_proposal_status_check" CHECK (("proposal_status" = ANY (ARRAY['none'::"text", 'proposed'::"text", 'approved'::"text", 'rejected'::"text", 'applied'::"text"])))
);


ALTER TABLE "public"."reviews" OWNER TO "postgres";


ALTER TABLE "public"."reviews" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."reviews_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."runs" (
    "id" bigint NOT NULL,
    "run_type" "text" NOT NULL,
    "trigger_id" "text",
    "session_id" "text",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "data_as_of" "date",
    "model" "text",
    "skill_version" "text",
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "data_calls" "jsonb",
    "summary" "text",
    "report_ref" "text",
    "notes" "text",
    CONSTRAINT "runs_run_type_check" CHECK (("run_type" = ANY (ARRAY['weekly_scan'::"text", 'midweek_checkin'::"text", 'adhoc'::"text", 'backfill'::"text", 'processing'::"text"]))),
    CONSTRAINT "runs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'succeeded'::"text", 'partial'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."runs" OWNER TO "postgres";


ALTER TABLE "public"."runs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."runs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."signal_exclusions" (
    "signal_id" bigint NOT NULL,
    "batch" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."signal_exclusions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."signal_rationale" (
    "signal_id" bigint NOT NULL,
    "run_id" bigint,
    "thesis" "text" NOT NULL,
    "catalyst" "text",
    "risks" "text",
    "invalidation" "text",
    "alternatives" "text",
    "data_gaps" "text",
    "confidence" smallint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "signal_rationale_confidence_check" CHECK ((("confidence" >= 1) AND ("confidence" <= 5)))
);


ALTER TABLE "public"."signal_rationale" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."signals" (
    "id" bigint NOT NULL,
    "run_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "symbol" "text" NOT NULL,
    "exchange" "text" DEFAULT 'NSE'::"text" NOT NULL,
    "signal_date" "date" NOT NULL,
    "source" "text" NOT NULL,
    "verdict" "text" NOT NULL,
    "provisional" boolean DEFAULT false NOT NULL,
    "setup" "text",
    "stage" integer,
    "why_grade" "text",
    "why_text" "text",
    "signal_close" numeric,
    "pivot" numeric,
    "alert_trigger" numeric,
    "entry_low" numeric,
    "entry_high" numeric,
    "stop" numeric,
    "stop_basis" "text",
    "trim_price" numeric,
    "size_pct" numeric,
    "risk_pct" numeric,
    "vol_mult" numeric,
    "req_vol_mult" numeric,
    "req_vol_abs" bigint,
    "sma13" numeric,
    "sma13_rising" boolean,
    "dist_sma_pct" numeric,
    "correction_pct" numeric,
    "base_range_pct" numeric,
    "close_loc" numeric,
    "liquidity_tier" "text" DEFAULT 'liquid'::"text" NOT NULL,
    "priority_rank" integer,
    "window_start" "date",
    "window_end" "date",
    "skill_version" "text",
    "retro_seeded" boolean DEFAULT false NOT NULL,
    "supersedes" bigint,
    "notes" "text",
    "raw" "jsonb",
    CONSTRAINT "signals_liquidity_tier_check" CHECK (("liquidity_tier" = ANY (ARRAY['liquid'::"text", 'thin'::"text"]))),
    CONSTRAINT "signals_setup_check" CHECK (("setup" = ANY (ARRAY['A_base'::"text", 'B_flag'::"text", 'holding'::"text", 'other'::"text"]))),
    CONSTRAINT "signals_source_check" CHECK (("source" = ANY (ARRAY['weekly_scan'::"text", 'midweek_checkin'::"text", 'adhoc'::"text", 'backfill'::"text"]))),
    CONSTRAINT "signals_stage_check" CHECK ((("stage" >= 1) AND ("stage" <= 4))),
    CONSTRAINT "signals_stop_basis_check" CHECK (("stop_basis" = ANY (ARRAY['structural'::"text", 'cap8'::"text", 'higher_low'::"text", 'sma'::"text", 'other'::"text"]))),
    CONSTRAINT "signals_verdict_check" CHECK (("verdict" = ANY (ARRAY['ENTRY'::"text", 'ENTRY_REDUCED'::"text", 'WAIT'::"text", 'WAIT_ALERT'::"text", 'NO_GO'::"text", 'TRIM'::"text", 'ADD'::"text", 'HOLD'::"text", 'REDUCE'::"text", 'EXIT'::"text"]))),
    CONSTRAINT "signals_why_grade_check" CHECK (("why_grade" = ANY (ARRAY['A'::"text", 'B'::"text", 'C'::"text", 'D'::"text"])))
);


ALTER TABLE "public"."signals" OWNER TO "postgres";


ALTER TABLE "public"."signals" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."signals_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."skill_versions" (
    "version" "text" NOT NULL,
    "effective_from" "date" NOT NULL,
    "sha256" "text",
    "summary" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."skill_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trade_reviews" (
    "id" bigint NOT NULL,
    "signal_id" bigint NOT NULL,
    "symbol" "text" NOT NULL,
    "run_id" bigint,
    "tag" "text" NOT NULL,
    "lesson" "text",
    "author" "text" DEFAULT 'agent'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trade_reviews_author_check" CHECK (("author" = ANY (ARRAY['agent'::"text", 'rajat'::"text"]))),
    CONSTRAINT "trade_reviews_tag_check" CHECK (("tag" = ANY (ARRAY['good_call'::"text", 'winner'::"text", 'valid_stop'::"text", 'whipsaw_tight_stop'::"text", 'gap_through_stop'::"text", 'missed_runner'::"text", 'avoided_loser'::"text", 'bad_entry'::"text", 'rule_violation'::"text", 'data_gap'::"text", 'removed_fresh_start'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."trade_reviews" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."trade_reviews_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."trade_reviews_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."trade_reviews_id_seq" OWNED BY "public"."trade_reviews"."id";



CREATE OR REPLACE VIEW "public"."v_activity" WITH ("security_invoker"='true') AS
 SELECT "s"."created_at" AS "ts",
    "s"."signal_date" AS "d",
    'signal'::"text" AS "kind",
    "s"."symbol",
    "s"."verdict" AS "what",
    "s"."source",
    "s"."provisional",
    "s"."stop" AS "price",
    NULL::integer AS "qty",
    NULL::numeric AS "pnl",
    COALESCE("s"."why_text", "s"."notes") AS "detail",
    "s"."id" AS "signal_id",
    NULL::bigint AS "position_id"
   FROM "public"."signals" "s"
UNION ALL
 SELECT "e"."created_at" AS "ts",
    "e"."event_date" AS "d",
    'event'::"text" AS "kind",
    "e"."symbol",
    "e"."event_type" AS "what",
    NULL::"text" AS "source",
    false AS "provisional",
    "e"."price",
    "e"."qty",
    "e"."pnl",
    "e"."rule" AS "detail",
    "e"."signal_id",
    "e"."position_id"
   FROM "public"."events" "e";


ALTER VIEW "public"."v_activity" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_equity_daily" WITH ("security_invoker"='true') AS
 WITH "cap" AS (
         SELECT "public"."cfg_num"('paper_capital'::"text") AS "c"
        ), "thru" AS (
         SELECT (("config"."value" #>> '{}'::"text"[]))::"date" AS "d"
           FROM "public"."config"
          WHERE ("config"."key" = 'processed_through'::"text")
        ), "ff" AS (
         SELECT "min"("positions"."fill_date") AS "d"
           FROM "public"."positions"
        ), "dates" AS (
         SELECT ("ff"."d" - 1) AS "d"
           FROM "ff"
          WHERE ("ff"."d" IS NOT NULL)
        UNION
         SELECT "pb"."bar_date"
           FROM "public"."price_bars" "pb",
            "ff",
            "thru"
          WHERE (("ff"."d" IS NOT NULL) AND ("pb"."bar_date" >= "ff"."d") AND ("pb"."bar_date" <= "thru"."d"))
        UNION
         SELECT "thru"."d"
           FROM "thru",
            "ff"
          WHERE ("ff"."d" IS NULL)
        ), "agg" AS (
         SELECT "dt"."d",
            COALESCE("sum"("m"."cost_basis"), (0)::numeric) AS "cb",
            COALESCE("sum"("m"."market_value"), (0)::numeric) AS "mv",
            COALESCE("sum"("m"."unrealized_pnl"), (0)::numeric) AS "unreal",
            "count"(*) FILTER (WHERE ("m"."qty_open" > 0)) AS "n"
           FROM ("dates" "dt"
             LEFT JOIN LATERAL ( SELECT DISTINCT ON ("mk"."position_id") "mk"."position_id",
                    "mk"."qty_open",
                    "mk"."cost_basis",
                    "mk"."market_value",
                    "mk"."unrealized_pnl"
                   FROM "public"."marks" "mk"
                  WHERE ("mk"."mark_date" <= "dt"."d")
                  ORDER BY "mk"."position_id", "mk"."mark_date" DESC) "m" ON (true))
          GROUP BY "dt"."d"
        ), "eq" AS (
         SELECT "a"."d" AS "as_of",
            "cap"."c" AS "capital",
            COALESCE(( SELECT "sum"("e"."pnl") AS "sum"
                   FROM "public"."events" "e"
                  WHERE ("e"."event_date" <= "a"."d")), (0)::numeric) AS "realized_cum",
            "a"."cb" AS "invested",
            "a"."mv" AS "market_value",
            "a"."unreal" AS "unrealized",
            "a"."n" AS "open_positions"
           FROM ("agg" "a"
             CROSS JOIN "cap")
        )
 SELECT "as_of",
    "capital",
    "round"((("capital" + "realized_cum") - "invested"), 2) AS "cash",
    "invested",
    "market_value",
    "realized_cum",
    "unrealized",
    "round"((("capital" + "realized_cum") + "unrealized"), 2) AS "equity",
    "round"(((("capital" + "realized_cum") + "unrealized") - COALESCE("lag"((("capital" + "realized_cum") + "unrealized")) OVER (ORDER BY "as_of"), "capital")), 2) AS "day_pnl",
    "round"(((((("capital" + "realized_cum") + "unrealized") / "capital") - (1)::numeric) * (100)::numeric), 3) AS "return_pct",
    "open_positions"
   FROM "eq"
  ORDER BY "as_of";


ALTER VIEW "public"."v_equity_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_positions" WITH ("security_invoker"='true') AS
 SELECT "po"."id" AS "position_id",
    "po"."signal_id",
    "sg"."symbol",
    "sg"."verdict",
    "sg"."why_grade",
    "sg"."setup",
    "sg"."source",
    "sg"."skill_version",
    "sg"."signal_date",
    "sg"."signal_close",
    "sg"."pivot",
    "sg"."vol_mult",
    "sg"."correction_pct",
    "sg"."base_range_pct",
    "sg"."dist_sma_pct",
    "sg"."retro_seeded",
    "po"."status",
    "po"."planned_size_pct",
    "po"."fill_date",
    "po"."fill_price",
    "po"."qty_initial",
    "po"."qty_open",
    "po"."avg_cost",
    "po"."gross_bought",
    "po"."stop_at_fill",
    "po"."stop_current",
    "po"."trim_price",
    "po"."trimmed",
    "po"."exit_date",
    "po"."exit_price",
    "po"."exit_reason",
    "po"."realized_pnl",
    "po"."costs",
        CASE
            WHEN ("po"."gross_bought" > (0)::numeric) THEN "round"((("po"."realized_pnl" / "po"."gross_bought") * (100)::numeric), 2)
            ELSE NULL::numeric
        END AS "realized_return_pct",
        CASE
            WHEN (("po"."fill_price" > "po"."stop_at_fill") AND ("po"."qty_initial" > 0)) THEN "round"(("po"."realized_pnl" / (("po"."qty_initial")::numeric * ("po"."fill_price" - "po"."stop_at_fill"))), 2)
            ELSE NULL::numeric
        END AS "r_multiple",
        CASE
            WHEN ("po"."fill_date" IS NOT NULL) THEN (COALESCE("po"."exit_date", CURRENT_DATE) - "po"."fill_date")
            ELSE NULL::integer
        END AS "days_held"
   FROM ("public"."positions" "po"
     JOIN "public"."signals" "sg" ON (("sg"."id" = "po"."signal_id")));


ALTER VIEW "public"."v_positions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_open_positions" WITH ("security_invoker"='true') AS
 SELECT "vp"."position_id",
    "vp"."signal_id",
    "vp"."symbol",
    "vp"."verdict",
    "vp"."why_grade",
    "vp"."setup",
    "vp"."source",
    "vp"."skill_version",
    "vp"."signal_date",
    "vp"."signal_close",
    "vp"."pivot",
    "vp"."vol_mult",
    "vp"."correction_pct",
    "vp"."base_range_pct",
    "vp"."dist_sma_pct",
    "vp"."retro_seeded",
    "vp"."status",
    "vp"."planned_size_pct",
    "vp"."fill_date",
    "vp"."fill_price",
    "vp"."qty_initial",
    "vp"."qty_open",
    "vp"."avg_cost",
    "vp"."gross_bought",
    "vp"."stop_at_fill",
    "vp"."stop_current",
    "vp"."trim_price",
    "vp"."trimmed",
    "vp"."exit_date",
    "vp"."exit_price",
    "vp"."exit_reason",
    "vp"."realized_pnl",
    "vp"."costs",
    "vp"."realized_return_pct",
    "vp"."r_multiple",
    "vp"."days_held",
    "m"."mark_date",
    "m"."close" AS "last_close",
    "m"."market_value",
    "m"."unrealized_pnl",
    "m"."unrealized_pct",
    "m"."dist_to_stop_pct",
    "round"(((("vp"."trim_price" / NULLIF("m"."close", (0)::numeric)) - (1)::numeric) * (100)::numeric), 2) AS "dist_to_trim_pct"
   FROM ("public"."v_positions" "vp"
     LEFT JOIN LATERAL ( SELECT "mk"."position_id",
            "mk"."mark_date",
            "mk"."symbol",
            "mk"."close",
            "mk"."qty_open",
            "mk"."cost_basis",
            "mk"."market_value",
            "mk"."unrealized_pnl",
            "mk"."unrealized_pct",
            "mk"."realized_to_date",
            "mk"."stop_current",
            "mk"."dist_to_stop_pct"
           FROM "public"."marks" "mk"
          WHERE ("mk"."position_id" = "vp"."position_id")
          ORDER BY "mk"."mark_date" DESC
         LIMIT 1) "m" ON (true))
  WHERE ("vp"."status" = 'open'::"text");


ALTER VIEW "public"."v_open_positions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_book_risk" WITH ("security_invoker"='true') AS
 WITH "e" AS (
         SELECT "v_equity_daily"."as_of",
            "v_equity_daily"."capital",
            "v_equity_daily"."cash",
            "v_equity_daily"."invested",
            "v_equity_daily"."market_value",
            "v_equity_daily"."realized_cum",
            "v_equity_daily"."unrealized",
            "v_equity_daily"."equity",
            "v_equity_daily"."day_pnl",
            "v_equity_daily"."return_pct",
            "v_equity_daily"."open_positions"
           FROM "public"."v_equity_daily"
          ORDER BY "v_equity_daily"."as_of" DESC
         LIMIT 1
        ), "o" AS (
         SELECT "count"(*) AS "n",
            COALESCE("sum"(GREATEST((0)::numeric, (("v_open_positions"."qty_open")::numeric * ("v_open_positions"."last_close" - "v_open_positions"."stop_current")))), (0)::numeric) AS "risk_from_price",
            COALESCE("sum"((("v_open_positions"."qty_open")::numeric * ("v_open_positions"."avg_cost" - "v_open_positions"."stop_current"))), (0)::numeric) AS "risk_from_cost",
            "round"("avg"("v_open_positions"."dist_to_stop_pct"), 2) AS "avg_dist_to_stop_pct",
            "round"("avg"("v_open_positions"."dist_to_trim_pct"), 2) AS "avg_dist_to_trim_pct"
           FROM "public"."v_open_positions"
        ), "pe" AS (
         SELECT "count"(*) AS "n",
            COALESCE("sum"((("public"."cfg_num"('paper_capital'::"text") * "positions"."planned_size_pct") / (100)::numeric)), (0)::numeric) AS "committed"
           FROM "public"."positions"
          WHERE ("positions"."status" = 'pending'::"text")
        )
 SELECT "e"."as_of",
    "e"."capital",
    "e"."equity",
    "e"."cash",
    "e"."invested",
    "round"((("e"."cash" / NULLIF("e"."equity", (0)::numeric)) * (100)::numeric), 2) AS "cash_pct",
    "o"."n" AS "open_positions",
    ("public"."cfg_num"('max_open_positions'::"text"))::integer AS "max_open_positions",
    "round"("o"."risk_from_price", 0) AS "open_risk_rupees",
    "round"((("o"."risk_from_price" / NULLIF("e"."equity", (0)::numeric)) * (100)::numeric), 2) AS "open_risk_pct",
    "round"("o"."risk_from_cost", 0) AS "risk_vs_cost_rupees",
    "o"."avg_dist_to_stop_pct",
    "o"."avg_dist_to_trim_pct",
    "pe"."n" AS "pending_entries",
    "round"("pe"."committed", 0) AS "pending_committed_rupees",
    "round"(("e"."cash" - "pe"."committed"), 0) AS "cash_after_pending"
   FROM (("e"
     CROSS JOIN "o")
     CROSS JOIN "pe");


ALTER VIEW "public"."v_book_risk" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_pnl_monthly" WITH ("security_invoker"='true') AS
 WITH "last_day" AS (
         SELECT DISTINCT ON (("date_trunc"('month'::"text", ("v_equity_daily"."as_of")::timestamp with time zone))) ("date_trunc"('month'::"text", ("v_equity_daily"."as_of")::timestamp with time zone))::"date" AS "month",
            "v_equity_daily"."equity",
            "v_equity_daily"."as_of"
           FROM "public"."v_equity_daily"
          ORDER BY ("date_trunc"('month'::"text", ("v_equity_daily"."as_of")::timestamp with time zone)), "v_equity_daily"."as_of" DESC
        )
 SELECT "month",
    "equity" AS "equity_end",
    "round"(("equity" - COALESCE("lag"("equity") OVER (ORDER BY "month"), "public"."cfg_num"('paper_capital'::"text"))), 2) AS "pnl",
    "round"(((("equity" / COALESCE("lag"("equity") OVER (ORDER BY "month"), "public"."cfg_num"('paper_capital'::"text"))) - (1)::numeric) * (100)::numeric), 2) AS "return_pct",
    ( SELECT COALESCE("sum"("e"."pnl"), (0)::numeric) AS "coalesce"
           FROM "public"."events" "e"
          WHERE ("date_trunc"('month'::"text", ("e"."event_date")::timestamp with time zone) = "l"."month")) AS "realized",
    ( SELECT "count"(*) AS "count"
           FROM "public"."positions" "p"
          WHERE (("p"."status" = 'closed'::"text") AND ("date_trunc"('month'::"text", ("p"."exit_date")::timestamp with time zone) = "l"."month"))) AS "trades_closed",
    ( SELECT "count"(*) AS "count"
           FROM "public"."positions" "p"
          WHERE (("p"."status" = 'closed'::"text") AND ("p"."realized_pnl" > (0)::numeric) AND ("date_trunc"('month'::"text", ("p"."exit_date")::timestamp with time zone) = "l"."month"))) AS "winners"
   FROM "last_day" "l"
  ORDER BY "month";


ALTER VIEW "public"."v_pnl_monthly" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_pnl_yearly" WITH ("security_invoker"='true') AS
 WITH "last_day" AS (
         SELECT DISTINCT ON (("date_trunc"('year'::"text", ("v_equity_daily"."as_of")::timestamp with time zone))) ("date_trunc"('year'::"text", ("v_equity_daily"."as_of")::timestamp with time zone))::"date" AS "year",
            "v_equity_daily"."equity"
           FROM "public"."v_equity_daily"
          ORDER BY ("date_trunc"('year'::"text", ("v_equity_daily"."as_of")::timestamp with time zone)), "v_equity_daily"."as_of" DESC
        )
 SELECT (EXTRACT("year" FROM "year"))::integer AS "year",
    "equity" AS "equity_end",
    "round"(("equity" - COALESCE("lag"("equity") OVER (ORDER BY "l"."year"), "public"."cfg_num"('paper_capital'::"text"))), 2) AS "pnl",
    "round"(((("equity" / COALESCE("lag"("equity") OVER (ORDER BY "l"."year"), "public"."cfg_num"('paper_capital'::"text"))) - (1)::numeric) * (100)::numeric), 2) AS "return_pct",
    ( SELECT "count"(*) AS "count"
           FROM "public"."positions" "p"
          WHERE (("p"."status" = 'closed'::"text") AND ("date_trunc"('year'::"text", ("p"."exit_date")::timestamp with time zone) = "l"."year"))) AS "trades_closed"
   FROM "last_day" "l"
  ORDER BY "l"."year";


ALTER VIEW "public"."v_pnl_yearly" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_signal_checklist" WITH ("security_invoker"='true') AS
 SELECT "s"."id" AS "signal_id",
    "s"."symbol",
    "s"."verdict",
    "s"."signal_date",
    ("ex"."signal_id" IS NOT NULL) AS "excluded",
    "c"."ord",
    "c"."rule",
    "c"."measured",
    "c"."target",
    "c"."status"
   FROM (("public"."signals" "s"
     LEFT JOIN "public"."signal_exclusions" "ex" ON (("ex"."signal_id" = "s"."id")))
     CROSS JOIN LATERAL ( VALUES (1,'Weekly close above pivot'::"text",
                CASE
                    WHEN (("s"."pivot" > (0)::numeric) AND ("s"."signal_close" IS NOT NULL)) THEN ((("round"(((("s"."signal_close" / "s"."pivot") - (1)::numeric) * (100)::numeric), 2))::"text" || '% vs pivot '::"text") || ("s"."pivot")::"text")
                    ELSE NULL::"text"
                END,'close > 52w-high pivot'::"text",
                CASE
                    WHEN (("s"."pivot" IS NULL) OR ("s"."signal_close" IS NULL)) THEN 'n/a'::"text"
                    WHEN ("s"."signal_close" > "s"."pivot") THEN 'pass'::"text"
                    WHEN ("s"."verdict" = ANY (ARRAY['WAIT'::"text", 'WAIT_ALERT'::"text"])) THEN 'pending'::"text"
                    ELSE 'fail'::"text"
                END), (2,'Breakout volume'::"text",(((("s"."vol_mult")::"text" || 'x (needed '::"text") || (COALESCE("s"."req_vol_mult", (2)::numeric))::"text") || 'x)'::"text"),'>= 2x 20w median; 2-3x best, 5-10x weaker, >10x weakest'::"text",
                CASE
                    WHEN ("s"."vol_mult" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."vol_mult" < COALESCE("s"."req_vol_mult", (2)::numeric)) THEN
                    CASE
                        WHEN ("s"."verdict" = ANY (ARRAY['WAIT'::"text", 'WAIT_ALERT'::"text"])) THEN 'pending'::"text"
                        ELSE 'fail'::"text"
                    END
                    WHEN ("s"."vol_mult" > (5)::numeric) THEN 'weak'::"text"
                    ELSE 'pass'::"text"
                END), (3,'13w SMA rising'::"text",
                CASE
                    WHEN "s"."sma13_rising" THEN 'rising'::"text"
                    WHEN (NOT "s"."sma13_rising") THEN 'flat/falling'::"text"
                    ELSE NULL::"text"
                END,'rising'::"text",
                CASE
                    WHEN ("s"."sma13_rising" IS NULL) THEN 'n/a'::"text"
                    WHEN "s"."sma13_rising" THEN 'pass'::"text"
                    ELSE 'fail'::"text"
                END), (4,'Distance above 13w SMA'::"text",(("s"."dist_sma_pct")::"text" || '%'::"text"),'<= 10% best; 10-30% weaker; > 30% extended'::"text",
                CASE
                    WHEN ("s"."dist_sma_pct" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."dist_sma_pct" <= (10)::numeric) THEN 'pass'::"text"
                    WHEN ("s"."dist_sma_pct" <= (30)::numeric) THEN 'weak'::"text"
                    ELSE 'fail'::"text"
                END), (5,'Prior correction depth'::"text",(("s"."correction_pct")::"text" || '%'::"text"),'>= 35% best (Setup A); Setup B needs none'::"text",
                CASE
                    WHEN ("s"."correction_pct" IS NULL) THEN 'n/a'::"text"
                    WHEN (("s"."correction_pct" >= (35)::numeric) OR ("s"."setup" ~~ 'B%'::"text")) THEN 'pass'::"text"
                    WHEN ("s"."correction_pct" >= (20)::numeric) THEN 'weak'::"text"
                    ELSE 'fail'::"text"
                END), (6,'Close location in weekly range'::"text",("s"."close_loc")::"text",'>= 0.7 strong; < 0.5 weak close (judged on the breakout week)'::"text",
                CASE
                    WHEN ("s"."close_loc" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."close_loc" >= 0.7) THEN 'pass'::"text"
                    WHEN ("s"."verdict" = ANY (ARRAY['WAIT'::"text", 'WAIT_ALERT'::"text"])) THEN 'pending'::"text"
                    WHEN ("s"."close_loc" >= 0.5) THEN 'weak'::"text"
                    ELSE 'fail'::"text"
                END), (7,'Fundamental why (grade)'::"text",COALESCE("s"."why_grade", '-'::"text"),'A/B full size; C half; D none or token'::"text",
                CASE
                    WHEN ("s"."why_grade" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."why_grade" = ANY (ARRAY['A'::"text", 'B'::"text"])) THEN 'pass'::"text"
                    WHEN ("s"."why_grade" = 'C'::"text") THEN 'weak'::"text"
                    ELSE 'fail'::"text"
                END), (8,'Risk to stop'::"text",(("s"."risk_pct")::"text" || '%'::"text"),'<= 8% of fill'::"text",
                CASE
                    WHEN ("s"."risk_pct" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."risk_pct" <= (8)::numeric) THEN 'pass'::"text"
                    ELSE 'fail'::"text"
                END), (9,'Liquidity'::"text",COALESCE("s"."liquidity_tier", '-'::"text"),'liquid (stop can execute)'::"text",
                CASE
                    WHEN ("s"."liquidity_tier" IS NULL) THEN 'n/a'::"text"
                    WHEN ("s"."liquidity_tier" = 'liquid'::"text") THEN 'pass'::"text"
                    ELSE 'weak'::"text"
                END)) "c"("ord", "rule", "measured", "target", "status"));


ALTER VIEW "public"."v_signal_checklist" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_rule_effectiveness" WITH ("security_invoker"='true') AS
 SELECT "ck"."ord",
    "ck"."rule",
    "ck"."status",
    "count"(*) AS "trades",
    "count"(*) FILTER (WHERE ("vp"."realized_pnl" > (0)::numeric)) AS "winners",
    "round"("avg"("vp"."r_multiple"), 2) AS "avg_r",
    "round"("avg"("vp"."realized_return_pct"), 2) AS "avg_return_pct"
   FROM ("public"."v_positions" "vp"
     JOIN "public"."v_signal_checklist" "ck" ON (("ck"."signal_id" = "vp"."signal_id")))
  WHERE ("vp"."status" = 'closed'::"text")
  GROUP BY "ck"."ord", "ck"."rule", "ck"."status";


ALTER VIEW "public"."v_rule_effectiveness" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_run_log" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "run_id",
    "r"."run_type",
    "r"."data_as_of",
    "r"."started_at",
    "r"."skill_version",
    "r"."model",
    "r"."status",
    "r"."summary",
    "r"."data_calls",
    "r"."notes",
    ( SELECT "jsonb_object_agg"("t"."verdict", "t"."n") AS "jsonb_object_agg"
           FROM ( SELECT "signals"."verdict",
                    "count"(*) AS "n"
                   FROM "public"."signals"
                  WHERE ("signals"."run_id" = "r"."id")
                  GROUP BY "signals"."verdict") "t") AS "verdicts",
    "rv"."observations",
    "rv"."lessons",
    "rv"."proposed_change",
    "rv"."proposal_status",
    "rv"."stats" AS "review_stats"
   FROM ("public"."runs" "r"
     LEFT JOIN LATERAL ( SELECT "reviews"."id",
            "reviews"."run_id",
            "reviews"."review_date",
            "reviews"."period",
            "reviews"."stats",
            "reviews"."observations",
            "reviews"."lessons",
            "reviews"."proposed_change",
            "reviews"."proposal_status",
            "reviews"."created_at"
           FROM "public"."reviews"
          WHERE ("reviews"."run_id" = "r"."id")
          ORDER BY "reviews"."id" DESC
         LIMIT 1) "rv" ON (true));


ALTER VIEW "public"."v_run_log" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_signal_outcomes" WITH ("security_invoker"='true') AS
 SELECT "id" AS "signal_id",
    "symbol",
    "signal_date",
    "source",
    "verdict",
    "provisional",
    "why_grade",
    "skill_version",
    "retro_seeded",
    "signal_close",
    "alert_trigger",
    "stop",
    ( SELECT "min"("pb"."bar_date") AS "min"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" > "s"."signal_date") AND ("pb"."high" > "s"."alert_trigger"))) AS "trigger_hit_date",
    ( SELECT "min"("pb"."bar_date") AS "min"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" > "s"."signal_date") AND ("pb"."low" <= "s"."stop"))) AS "stop_touch_date",
    "round"((((( SELECT "pb"."close"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" >= ("s"."signal_date" + 7)))
          ORDER BY "pb"."bar_date"
         LIMIT 1) / "signal_close") * (100)::numeric) - (100)::numeric), 2) AS "ret_1w_pct",
    "round"((((( SELECT "pb"."close"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" >= ("s"."signal_date" + 28)))
          ORDER BY "pb"."bar_date"
         LIMIT 1) / "signal_close") * (100)::numeric) - (100)::numeric), 2) AS "ret_4w_pct",
    "round"((((( SELECT "pb"."close"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" >= ("s"."signal_date" + 91)))
          ORDER BY "pb"."bar_date"
         LIMIT 1) / "signal_close") * (100)::numeric) - (100)::numeric), 2) AS "ret_13w_pct",
    "round"((((( SELECT "max"("pb"."high") AS "max"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" > "s"."signal_date") AND ("pb"."bar_date" <= ("s"."signal_date" + 28)))) / "signal_close") * (100)::numeric) - (100)::numeric), 2) AS "max_up_4w_pct",
    "round"((((( SELECT "min"("pb"."low") AS "min"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "s"."symbol") AND ("pb"."bar_date" > "s"."signal_date") AND ("pb"."bar_date" <= ("s"."signal_date" + 28)))) / "signal_close") * (100)::numeric) - (100)::numeric), 2) AS "max_down_4w_pct",
    ( SELECT "max"("pb"."bar_date") AS "max"
           FROM "public"."price_bars" "pb"
          WHERE ("pb"."symbol" = "s"."symbol")) AS "last_bar"
   FROM "public"."signals" "s"
  WHERE (NOT (EXISTS ( SELECT 1
           FROM "public"."signals" "x"
          WHERE ("x"."supersedes" = "s"."id"))));


ALTER VIEW "public"."v_signal_outcomes" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_signal_plan" WITH ("security_invoker"='true') AS
 WITH "k" AS (
         SELECT "public"."cfg_num"('paper_capital'::"text") AS "cap",
            "public"."cfg_num"('trim_multiple'::"text") AS "tm",
            "public"."cfg_num"('stop_cap_pct'::"text") AS "sc"
        ), "b" AS (
         SELECT "s"."id",
            "s"."run_id",
            "s"."created_at",
            "s"."symbol",
            "s"."exchange",
            "s"."signal_date",
            "s"."source",
            "s"."verdict",
            "s"."provisional",
            "s"."setup",
            "s"."stage",
            "s"."why_grade",
            "s"."why_text",
            "s"."signal_close",
            "s"."pivot",
            "s"."alert_trigger",
            "s"."entry_low",
            "s"."entry_high",
            "s"."stop",
            "s"."stop_basis",
            "s"."trim_price",
            "s"."size_pct",
            "s"."risk_pct",
            "s"."vol_mult",
            "s"."req_vol_mult",
            "s"."req_vol_abs",
            "s"."sma13",
            "s"."sma13_rising",
            "s"."dist_sma_pct",
            "s"."correction_pct",
            "s"."base_range_pct",
            "s"."close_loc",
            "s"."liquidity_tier",
            "s"."priority_rank",
            "s"."window_start",
            "s"."window_end",
            "s"."skill_version",
            "s"."retro_seeded",
            "s"."supersedes",
            "s"."notes",
            "s"."raw",
            ("ex"."signal_id" IS NOT NULL) AS "excluded",
            COALESCE("s"."entry_low", "s"."alert_trigger", "s"."signal_close") AS "entry_ref",
            COALESCE("s"."size_pct", (
                CASE
                    WHEN (("s"."verdict" = 'ENTRY_REDUCED'::"text") OR ("s"."why_grade" = ANY (ARRAY['C'::"text", 'D'::"text"]))) THEN 5
                    ELSE 10
                END)::numeric) AS "size_plan"
           FROM ("public"."signals" "s"
             LEFT JOIN "public"."signal_exclusions" "ex" ON (("ex"."signal_id" = "s"."id")))
        ), "c" AS (
         SELECT "b"."id",
            "b"."run_id",
            "b"."created_at",
            "b"."symbol",
            "b"."exchange",
            "b"."signal_date",
            "b"."source",
            "b"."verdict",
            "b"."provisional",
            "b"."setup",
            "b"."stage",
            "b"."why_grade",
            "b"."why_text",
            "b"."signal_close",
            "b"."pivot",
            "b"."alert_trigger",
            "b"."entry_low",
            "b"."entry_high",
            "b"."stop",
            "b"."stop_basis",
            "b"."trim_price",
            "b"."size_pct",
            "b"."risk_pct",
            "b"."vol_mult",
            "b"."req_vol_mult",
            "b"."req_vol_abs",
            "b"."sma13",
            "b"."sma13_rising",
            "b"."dist_sma_pct",
            "b"."correction_pct",
            "b"."base_range_pct",
            "b"."close_loc",
            "b"."liquidity_tier",
            "b"."priority_rank",
            "b"."window_start",
            "b"."window_end",
            "b"."skill_version",
            "b"."retro_seeded",
            "b"."supersedes",
            "b"."notes",
            "b"."raw",
            "b"."excluded",
            "b"."entry_ref",
            "b"."size_plan",
            COALESCE("b"."stop", "round"(("b"."entry_ref" * ((1)::numeric - ("k"."sc" / (100)::numeric))), 2)) AS "stop_ref",
            COALESCE("b"."trim_price", "round"(("b"."entry_ref" * "k"."tm"), 2)) AS "trim_ref",
            "k"."cap"
           FROM ("b"
             CROSS JOIN "k")
        )
 SELECT "c"."id" AS "signal_id",
    "c"."run_id",
    "c"."symbol",
    "c"."signal_date",
    "c"."verdict",
    "c"."setup",
    "c"."stage",
    "c"."why_grade",
    "c"."priority_rank",
    "c"."excluded",
    "c"."retro_seeded",
    "c"."skill_version",
    "c"."entry_ref",
    "c"."entry_high",
    "c"."stop_ref",
    "c"."trim_ref",
    "c"."size_plan" AS "size_pct",
    "round"((((1)::numeric - ("c"."stop_ref" / NULLIF("c"."entry_ref", (0)::numeric))) * (100)::numeric), 2) AS "risk_pct_plan",
    "round"(((("c"."trim_ref" / NULLIF("c"."entry_ref", (0)::numeric)) - (1)::numeric) * (100)::numeric), 2) AS "reward_pct_plan",
    "round"((("c"."trim_ref" - "c"."entry_ref") / NULLIF(("c"."entry_ref" - "c"."stop_ref"), (0)::numeric)), 2) AS "rr_plan",
    "round"((("c"."cap" * "c"."size_plan") / (100)::numeric), 0) AS "position_value",
    "round"(((("c"."cap" * "c"."size_plan") / (100)::numeric) * ((1)::numeric - ("c"."stop_ref" / NULLIF("c"."entry_ref", (0)::numeric)))), 0) AS "rupee_risk",
    "round"(((("c"."cap" * "c"."size_plan") / (100)::numeric) * (("c"."trim_ref" / NULLIF("c"."entry_ref", (0)::numeric)) - (1)::numeric)), 0) AS "rupee_reward_at_trim",
    "round"(("c"."size_plan" * ((1)::numeric - ("c"."stop_ref" / NULLIF("c"."entry_ref", (0)::numeric)))), 2) AS "capital_risk_pct",
    "ck"."passes",
    "ck"."weak",
    "ck"."fails",
    "ck"."failed_rules",
    "po"."status" AS "book_status",
    "po"."exit_reason" AS "book_reason",
    "po"."fill_price",
    "po"."fill_date"
   FROM (("c"
     LEFT JOIN LATERAL ( SELECT "count"(*) FILTER (WHERE ("v"."status" = 'pass'::"text")) AS "passes",
            "count"(*) FILTER (WHERE ("v"."status" = 'weak'::"text")) AS "weak",
            "count"(*) FILTER (WHERE ("v"."status" = 'fail'::"text")) AS "fails",
            "string_agg"("v"."rule", '; '::"text" ORDER BY "v"."ord") FILTER (WHERE ("v"."status" = 'fail'::"text")) AS "failed_rules"
           FROM "public"."v_signal_checklist" "v"
          WHERE ("v"."signal_id" = "c"."id")) "ck" ON (true))
     LEFT JOIN "public"."positions" "po" ON (("po"."signal_id" = "c"."id")));


ALTER VIEW "public"."v_signal_plan" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_suggestions" WITH ("security_invoker"='true') AS
 WITH "thru" AS (
         SELECT COALESCE(( SELECT (("config"."value" #>> '{}'::"text"[]))::"date" AS "date"
                   FROM "public"."config"
                  WHERE ("config"."key" = 'processed_through'::"text")), CURRENT_DATE) AS "d"
        ), "latest" AS (
         SELECT DISTINCT ON ("s"."symbol") "s"."id",
            "s"."run_id",
            "s"."created_at",
            "s"."symbol",
            "s"."exchange",
            "s"."signal_date",
            "s"."source",
            "s"."verdict",
            "s"."provisional",
            "s"."setup",
            "s"."stage",
            "s"."why_grade",
            "s"."why_text",
            "s"."signal_close",
            "s"."pivot",
            "s"."alert_trigger",
            "s"."entry_low",
            "s"."entry_high",
            "s"."stop",
            "s"."stop_basis",
            "s"."trim_price",
            "s"."size_pct",
            "s"."risk_pct",
            "s"."vol_mult",
            "s"."req_vol_mult",
            "s"."req_vol_abs",
            "s"."sma13",
            "s"."sma13_rising",
            "s"."dist_sma_pct",
            "s"."correction_pct",
            "s"."base_range_pct",
            "s"."close_loc",
            "s"."liquidity_tier",
            "s"."priority_rank",
            "s"."window_start",
            "s"."window_end",
            "s"."skill_version",
            "s"."retro_seeded",
            "s"."supersedes",
            "s"."notes",
            "s"."raw"
           FROM "public"."signals" "s"
          WHERE (("s"."signal_date" >= (( SELECT "thru"."d"
                   FROM "thru") - 31)) AND (NOT (EXISTS ( SELECT 1
                   FROM "public"."signals" "y"
                  WHERE ("y"."supersedes" = "s"."id")))) AND (NOT (EXISTS ( SELECT 1
                   FROM "public"."signal_exclusions" "ex"
                  WHERE ("ex"."signal_id" = "s"."id")))))
          ORDER BY "s"."symbol", "s"."signal_date" DESC, "s"."id" DESC
        ), "cash" AS (
         SELECT "v_equity_daily"."cash"
           FROM "public"."v_equity_daily"
          ORDER BY "v_equity_daily"."as_of" DESC
         LIMIT 1
        )
 SELECT
        CASE
            WHEN ("l"."verdict" = ANY (ARRAY['ENTRY'::"text", 'ENTRY_REDUCED'::"text"])) THEN 'entry'::"text"
            ELSE 'watch'::"text"
        END AS "bucket",
    "p"."signal_id",
    "p"."run_id",
    "p"."symbol",
    "p"."signal_date",
    "p"."verdict",
    "p"."setup",
    "p"."stage",
    "p"."why_grade",
    "p"."priority_rank",
    "p"."excluded",
    "p"."retro_seeded",
    "p"."skill_version",
    "p"."entry_ref",
    "p"."entry_high",
    "p"."stop_ref",
    "p"."trim_ref",
    "p"."size_pct",
    "p"."risk_pct_plan",
    "p"."reward_pct_plan",
    "p"."rr_plan",
    "p"."position_value",
    "p"."rupee_risk",
    "p"."rupee_reward_at_trim",
    "p"."capital_risk_pct",
    "p"."passes",
    "p"."weak",
    "p"."fails",
    "p"."failed_rules",
    "p"."book_status",
    "p"."book_reason",
    "p"."fill_price",
    "p"."fill_date",
    "l"."why_text",
    "l"."notes",
    "l"."pivot",
    "l"."alert_trigger",
    "l"."req_vol_abs",
    "l"."vol_mult",
    "l"."window_start",
    "l"."window_end",
    "r"."thesis",
    "r"."catalyst",
    "r"."risks",
    "r"."invalidation",
    "r"."alternatives",
    "r"."data_gaps",
    "r"."confidence",
    ( SELECT "cash"."cash"
           FROM "cash") AS "book_cash",
    ("p"."position_value" <= COALESCE(( SELECT "cash"."cash"
           FROM "cash"), (0)::numeric)) AS "fundable_now"
   FROM (("latest" "l"
     JOIN "public"."v_signal_plan" "p" ON (("p"."signal_id" = "l"."id")))
     LEFT JOIN "public"."signal_rationale" "r" ON (("r"."signal_id" = "l"."id")))
  WHERE ("l"."verdict" = ANY (ARRAY['ENTRY'::"text", 'ENTRY_REDUCED'::"text", 'WAIT_ALERT'::"text", 'WAIT'::"text"]))
  ORDER BY
        CASE
            WHEN ("l"."verdict" = ANY (ARRAY['ENTRY'::"text", 'ENTRY_REDUCED'::"text"])) THEN 0
            ELSE 1
        END, "l"."priority_rank", "p"."rr_plan" DESC NULLS LAST;


ALTER VIEW "public"."v_suggestions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_trade_review" WITH ("security_invoker"='true') AS
 WITH "thru" AS (
         SELECT COALESCE(( SELECT (("config"."value" #>> '{}'::"text"[]))::"date" AS "date"
                   FROM "public"."config"
                  WHERE ("config"."key" = 'processed_through'::"text")), CURRENT_DATE) AS "d"
        )
 SELECT "vp"."position_id",
    "vp"."signal_id",
    "vp"."symbol",
    "vp"."verdict",
    "vp"."why_grade",
    "vp"."setup",
    "vp"."vol_mult",
    "vp"."dist_sma_pct",
    "vp"."correction_pct",
    "vp"."status",
    "vp"."fill_date",
    "vp"."fill_price",
    "vp"."stop_at_fill",
    "vp"."trim_price",
    "vp"."exit_date",
    "vp"."exit_price",
    "vp"."exit_reason",
    "vp"."realized_pnl",
    "vp"."r_multiple",
    "vp"."days_held",
    "pl"."rr_plan",
    "pl"."passes",
    "pl"."weak",
    "pl"."fails",
    "pl"."failed_rules",
    "round"((((1)::numeric - ("vp"."stop_at_fill" / NULLIF("vp"."fill_price", (0)::numeric))) * (100)::numeric), 2) AS "ledger_risk_pct",
    "round"(("vp"."fill_price" * 0.92), 2) AS "skill_stop",
    "round"(((("h"."max_high" / "vp"."fill_price") - (1)::numeric) * (100)::numeric), 2) AS "mfe_pct",
    "round"(((("h"."min_low" / "vp"."fill_price") - (1)::numeric) * (100)::numeric), 2) AS "mae_pct",
    "round"(((("a"."low_since_fill" / "vp"."fill_price") - (1)::numeric) * (100)::numeric), 2) AS "worst_since_fill_pct",
    ("a"."low_since_fill" > "round"(("vp"."fill_price" * 0.92), 2)) AS "skill_stop_still_intact",
    "round"(((("x"."high_after" / NULLIF("vp"."exit_price", (0)::numeric)) - (1)::numeric) * (100)::numeric), 2) AS "post_exit_run_pct",
        CASE
            WHEN ("vp"."status" = ANY (ARRAY['pending'::"text", 'expired'::"text", 'skipped'::"text"])) THEN "vp"."status"
            WHEN ("vp"."status" = 'open'::"text") THEN 'open'::"text"
            WHEN (("vp"."exit_reason" = 'stop_hit'::"text") AND ("vp"."exit_price" < "vp"."stop_at_fill")) THEN 'gap_through_stop'::"text"
            WHEN (("vp"."exit_reason" = 'stop_hit'::"text") AND ("a"."low_since_fill" > "round"(("vp"."fill_price" * 0.92), 2))) THEN 'whipsaw_tight_stop'::"text"
            WHEN (("vp"."exit_reason" = 'stop_hit'::"text") AND (COALESCE(("x"."high_after" / NULLIF("vp"."exit_price", (0)::numeric)), (0)::numeric) >= 1.15)) THEN 'missed_runner'::"text"
            WHEN ("vp"."exit_reason" = 'stop_hit'::"text") THEN 'valid_stop'::"text"
            WHEN ("vp"."realized_pnl" > (0)::numeric) THEN 'winner'::"text"
            ELSE 'loser'::"text"
        END AS "auto_tag",
    "tr"."tag" AS "review_tag",
    "tr"."lesson" AS "review_lesson",
    "tr"."author" AS "review_author"
   FROM (((((("public"."v_positions" "vp"
     CROSS JOIN "thru")
     LEFT JOIN "public"."v_signal_plan" "pl" ON (("pl"."signal_id" = "vp"."signal_id")))
     LEFT JOIN LATERAL ( SELECT "max"("pb"."high") AS "max_high",
            "min"("pb"."low") AS "min_low"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "vp"."symbol") AND (("pb"."bar_date" >= "vp"."fill_date") AND ("pb"."bar_date" <= COALESCE("vp"."exit_date", "thru"."d"))))) "h" ON (true))
     LEFT JOIN LATERAL ( SELECT "min"("pb"."low") AS "low_since_fill"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "vp"."symbol") AND (("pb"."bar_date" >= "vp"."fill_date") AND ("pb"."bar_date" <= "thru"."d")))) "a" ON (true))
     LEFT JOIN LATERAL ( SELECT "max"("pb"."high") AS "high_after"
           FROM "public"."price_bars" "pb"
          WHERE (("pb"."symbol" = "vp"."symbol") AND ("vp"."exit_date" IS NOT NULL) AND ("pb"."bar_date" > "vp"."exit_date") AND ("pb"."bar_date" <= ("vp"."exit_date" + 30)))) "x" ON (true))
     LEFT JOIN LATERAL ( SELECT "t"."id",
            "t"."signal_id",
            "t"."symbol",
            "t"."run_id",
            "t"."tag",
            "t"."lesson",
            "t"."author",
            "t"."created_at"
           FROM "public"."trade_reviews" "t"
          WHERE ("t"."signal_id" = "vp"."signal_id")
          ORDER BY "t"."id" DESC
         LIMIT 1) "tr" ON (true));


ALTER VIEW "public"."v_trade_review" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_trade_stats" WITH ("security_invoker"='true') AS
 SELECT GROUPING("verdict", "why_grade", "setup", "skill_version") AS "grp",
    "verdict",
    "why_grade",
    "setup",
    "skill_version",
    "count"(*) FILTER (WHERE ("status" = 'closed'::"text")) AS "closed",
    "count"(*) FILTER (WHERE ("status" = 'open'::"text")) AS "open",
    "count"(*) FILTER (WHERE ("status" = ANY (ARRAY['expired'::"text", 'skipped'::"text"]))) AS "not_filled",
    "round"(("avg"((("realized_pnl" > (0)::numeric))::integer) FILTER (WHERE ("status" = 'closed'::"text")) * (100)::numeric), 1) AS "win_rate_pct",
    "round"("avg"("realized_return_pct") FILTER (WHERE ("status" = 'closed'::"text")), 2) AS "avg_return_pct",
    "round"("avg"("r_multiple") FILTER (WHERE ("status" = 'closed'::"text")), 2) AS "avg_r",
    "round"("avg"("days_held") FILTER (WHERE ("status" = 'closed'::"text")), 1) AS "avg_days_held",
    "round"("sum"("realized_pnl"), 2) AS "realized_pnl",
        CASE GROUPING("verdict", "why_grade", "setup", "skill_version")
            WHEN 15 THEN 'overall'::"text"
            WHEN 7 THEN 'verdict'::"text"
            WHEN 11 THEN 'why_grade'::"text"
            WHEN 13 THEN 'setup'::"text"
            WHEN 14 THEN 'skill_version'::"text"
            WHEN 3 THEN 'verdict_why_grade'::"text"
            ELSE NULL::"text"
        END AS "dimension"
   FROM "public"."v_positions"
  GROUP BY GROUPING SETS ((), ("verdict"), ("why_grade"), ("setup"), ("skill_version"), ("verdict", "why_grade"));


ALTER VIEW "public"."v_trade_stats" OWNER TO "postgres";


ALTER TABLE ONLY "public"."trade_reviews" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."trade_reviews_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."config"
    ADD CONSTRAINT "config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."marks"
    ADD CONSTRAINT "marks_pkey" PRIMARY KEY ("position_id", "mark_date");



ALTER TABLE ONLY "public"."positions"
    ADD CONSTRAINT "positions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."positions"
    ADD CONSTRAINT "positions_signal_id_key" UNIQUE ("signal_id");



ALTER TABLE ONLY "public"."price_bars"
    ADD CONSTRAINT "price_bars_pkey" PRIMARY KEY ("symbol", "bar_date");



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."runs"
    ADD CONSTRAINT "runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."signal_exclusions"
    ADD CONSTRAINT "signal_exclusions_pkey" PRIMARY KEY ("signal_id");



ALTER TABLE ONLY "public"."signal_rationale"
    ADD CONSTRAINT "signal_rationale_pkey" PRIMARY KEY ("signal_id");



ALTER TABLE ONLY "public"."signals"
    ADD CONSTRAINT "signals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."skill_versions"
    ADD CONSTRAINT "skill_versions_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "public"."trade_reviews"
    ADD CONSTRAINT "trade_reviews_pkey" PRIMARY KEY ("id");



CREATE INDEX "events_date_idx" ON "public"."events" USING "btree" ("event_date");



CREATE INDEX "events_position_idx" ON "public"."events" USING "btree" ("position_id");



CREATE INDEX "events_signal_idx" ON "public"."events" USING "btree" ("signal_id");



CREATE INDEX "events_trigger_sig_idx" ON "public"."events" USING "btree" ("trigger_signal_id");



CREATE INDEX "marks_date_idx" ON "public"."marks" USING "btree" ("mark_date");



CREATE INDEX "positions_symbol_idx" ON "public"."positions" USING "btree" ("symbol");



CREATE INDEX "reviews_run_idx" ON "public"."reviews" USING "btree" ("run_id");



CREATE INDEX "runs_skill_idx" ON "public"."runs" USING "btree" ("skill_version");



CREATE INDEX "signals_run_idx" ON "public"."signals" USING "btree" ("run_id");



CREATE INDEX "signals_skill_idx" ON "public"."signals" USING "btree" ("skill_version");



CREATE INDEX "signals_supersedes_idx" ON "public"."signals" USING "btree" ("supersedes");



CREATE INDEX "signals_symbol_date_idx" ON "public"."signals" USING "btree" ("symbol", "signal_date");



CREATE INDEX "signals_verdict_idx" ON "public"."signals" USING "btree" ("verdict");



CREATE INDEX "trade_reviews_signal_idx" ON "public"."trade_reviews" USING "btree" ("signal_id");



CREATE OR REPLACE TRIGGER "signals_append_only" BEFORE DELETE OR UPDATE ON "public"."signals" FOR EACH ROW EXECUTE FUNCTION "public"."block_signal_mutation"();



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_position_id_fkey" FOREIGN KEY ("position_id") REFERENCES "public"."positions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_signal_id_fkey" FOREIGN KEY ("signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_trigger_signal_id_fkey" FOREIGN KEY ("trigger_signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."marks"
    ADD CONSTRAINT "marks_position_id_fkey" FOREIGN KEY ("position_id") REFERENCES "public"."positions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."positions"
    ADD CONSTRAINT "positions_signal_id_fkey" FOREIGN KEY ("signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id");



ALTER TABLE ONLY "public"."runs"
    ADD CONSTRAINT "runs_skill_version_fkey" FOREIGN KEY ("skill_version") REFERENCES "public"."skill_versions"("version");



ALTER TABLE ONLY "public"."signal_exclusions"
    ADD CONSTRAINT "signal_exclusions_signal_id_fkey" FOREIGN KEY ("signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."signal_rationale"
    ADD CONSTRAINT "signal_rationale_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id");



ALTER TABLE ONLY "public"."signal_rationale"
    ADD CONSTRAINT "signal_rationale_signal_id_fkey" FOREIGN KEY ("signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."signals"
    ADD CONSTRAINT "signals_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id");



ALTER TABLE ONLY "public"."signals"
    ADD CONSTRAINT "signals_skill_version_fkey" FOREIGN KEY ("skill_version") REFERENCES "public"."skill_versions"("version");



ALTER TABLE ONLY "public"."signals"
    ADD CONSTRAINT "signals_supersedes_fkey" FOREIGN KEY ("supersedes") REFERENCES "public"."signals"("id");



ALTER TABLE ONLY "public"."trade_reviews"
    ADD CONSTRAINT "trade_reviews_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id");



ALTER TABLE ONLY "public"."trade_reviews"
    ADD CONSTRAINT "trade_reviews_signal_id_fkey" FOREIGN KEY ("signal_id") REFERENCES "public"."signals"("id");



ALTER TABLE "public"."config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "config_read" ON "public"."config" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "events_read" ON "public"."events" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."marks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "marks_read" ON "public"."marks" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."positions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "positions_read" ON "public"."positions" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."price_bars" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "price_bars_read" ON "public"."price_bars" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reviews_read" ON "public"."reviews" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "runs_read" ON "public"."runs" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."signal_exclusions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "signal_exclusions_read" ON "public"."signal_exclusions" FOR SELECT USING (true);



ALTER TABLE "public"."signal_rationale" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "signal_rationale_read" ON "public"."signal_rationale" FOR SELECT USING (true);



ALTER TABLE "public"."signals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "signals_read" ON "public"."signals" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."skill_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "skill_versions_read" ON "public"."skill_versions" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."trade_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trade_reviews_read" ON "public"."trade_reviews" FOR SELECT USING (true);



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_ledger_manage"("v_pid" bigint, "d" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_ledger_manage"("v_pid" bigint, "d" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_ledger_pending"("v_pid" bigint, "d" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_ledger_pending"("v_pid" bigint, "d" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_ledger_sell"("p_id" bigint, "d" "date", "px" numeric, "q" integer, "etype" "text", "why" "text", "trig" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_ledger_sell"("p_id" bigint, "d" "date", "px" numeric, "q" integer, "etype" "text", "why" "text", "trig" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."block_signal_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."block_signal_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_signal_mutation"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cfg_num"("k" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cfg_num"("k" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."cfg_num"("k" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cfg_num"("k" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."process_ledger"("p_through" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_ledger"("p_through" "date") TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."config" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."config" TO "authenticated";
GRANT ALL ON TABLE "public"."config" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."events" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."marks" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."marks" TO "authenticated";
GRANT ALL ON TABLE "public"."marks" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."positions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."positions" TO "authenticated";
GRANT ALL ON TABLE "public"."positions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."positions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."positions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."positions_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."price_bars" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."price_bars" TO "authenticated";
GRANT ALL ON TABLE "public"."price_bars" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."reviews" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."reviews" TO "service_role";



GRANT ALL ON SEQUENCE "public"."reviews_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."reviews_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."reviews_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."runs" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."runs" TO "authenticated";
GRANT ALL ON TABLE "public"."runs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."runs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."runs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."runs_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signal_exclusions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signal_exclusions" TO "authenticated";
GRANT ALL ON TABLE "public"."signal_exclusions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signal_rationale" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signal_rationale" TO "authenticated";
GRANT ALL ON TABLE "public"."signal_rationale" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signals" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."signals" TO "authenticated";
GRANT ALL ON TABLE "public"."signals" TO "service_role";



GRANT ALL ON SEQUENCE "public"."signals_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."signals_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."signals_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."skill_versions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."skill_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."skill_versions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."trade_reviews" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."trade_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."trade_reviews" TO "service_role";



GRANT ALL ON SEQUENCE "public"."trade_reviews_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."trade_reviews_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."trade_reviews_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_activity" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."v_activity" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_equity_daily" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_equity_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."v_equity_daily" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_positions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_positions" TO "authenticated";
GRANT ALL ON TABLE "public"."v_positions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_open_positions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_open_positions" TO "authenticated";
GRANT ALL ON TABLE "public"."v_open_positions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_book_risk" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_book_risk" TO "authenticated";
GRANT ALL ON TABLE "public"."v_book_risk" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_pnl_monthly" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_pnl_monthly" TO "authenticated";
GRANT ALL ON TABLE "public"."v_pnl_monthly" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_pnl_yearly" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_pnl_yearly" TO "authenticated";
GRANT ALL ON TABLE "public"."v_pnl_yearly" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_checklist" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_checklist" TO "authenticated";
GRANT ALL ON TABLE "public"."v_signal_checklist" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_rule_effectiveness" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_rule_effectiveness" TO "authenticated";
GRANT ALL ON TABLE "public"."v_rule_effectiveness" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_run_log" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_run_log" TO "authenticated";
GRANT ALL ON TABLE "public"."v_run_log" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_outcomes" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_outcomes" TO "authenticated";
GRANT ALL ON TABLE "public"."v_signal_outcomes" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_plan" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_signal_plan" TO "authenticated";
GRANT ALL ON TABLE "public"."v_signal_plan" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_suggestions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_suggestions" TO "authenticated";
GRANT ALL ON TABLE "public"."v_suggestions" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_trade_review" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_trade_review" TO "authenticated";
GRANT ALL ON TABLE "public"."v_trade_review" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_trade_stats" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."v_trade_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."v_trade_stats" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







