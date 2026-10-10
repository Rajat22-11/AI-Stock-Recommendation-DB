
create or replace function public.cfg_num(k text) returns numeric
language sql stable set search_path = public as $$ select (value #>> '{}')::numeric from public.config where key = k $$;

create or replace function public._ledger_sell(p_id bigint, d date, px numeric, q int, etype text, why text, trig bigint)
returns void language plpgsql set search_path = public as $$
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

revoke execute on function public._ledger_sell(bigint, date, numeric, int, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.cfg_num(text) from public, anon, authenticated;
;
