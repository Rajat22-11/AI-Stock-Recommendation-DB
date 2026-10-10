-- _ledger_manage(v_pid bigint, d date)  acl: postgres=X/postgres,service_role=X/postgres
CREATE OR REPLACE FUNCTION public._ledger_manage(v_pid bigint, d date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
end $function$
;

-- _ledger_pending(v_pid bigint, d date)  acl: postgres=X/postgres,service_role=X/postgres
CREATE OR REPLACE FUNCTION public._ledger_pending(v_pid bigint, d date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
end $function$
;

-- _ledger_sell(p_id bigint, d date, px numeric, q integer, etype text, why text, trig bigint)  acl: postgres=X/postgres,service_role=X/postgres
CREATE OR REPLACE FUNCTION public._ledger_sell(p_id bigint, d date, px numeric, q integer, etype text, why text, trig bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
end $function$
;

-- block_signal_mutation()  acl: =X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres
CREATE OR REPLACE FUNCTION public.block_signal_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(current_setting('tracker.allow_signal_edit', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'signals are append-only: insert a new row with supersedes = % instead', old.id;
end $function$
;

-- cfg_num(k text)  acl: postgres=X/postgres,service_role=X/postgres,anon=X/postgres,authenticated=X/postgres
CREATE OR REPLACE FUNCTION public.cfg_num(k text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$ select (value #>> '{}')::numeric from public.config where key = k $function$
;

-- process_ledger(p_through date)  acl: postgres=X/postgres,service_role=X/postgres
CREATE OR REPLACE FUNCTION public.process_ledger(p_through date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
end $function$
;
