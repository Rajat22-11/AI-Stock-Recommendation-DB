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
end $function$;;
