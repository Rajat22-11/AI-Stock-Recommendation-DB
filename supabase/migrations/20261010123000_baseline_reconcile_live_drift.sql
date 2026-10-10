-- Baseline reconcile: brings migration history in line with production as of 2026-10-10.
--
-- process_ledger and _ledger_manage were created in production outside migration history, and
-- EXECUTE on process_ledger, _ledger_manage and _ledger_pending was revoked from public roles
-- outside migrations as well. A database rebuilt from the 11 earlier migrations therefore had
-- no ledger simulator and over-broad function grants.
--
-- Every statement below reproduces the current production state exactly (function bodies are
-- pg_get_functiondef output captured from prod, see supabase/snapshots/
-- prod_functions_2026-10-10.sql), so applying this migration to production changes nothing.
-- See openspec/changes/establish-baseline/design.md (D2).
--
-- NOTE: process_ledger's body has CRLF line endings in production (it was created from a
-- Windows client). They are kept byte-for-byte here; .gitattributes marks this file -text so
-- git never normalises them.

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

-- Ledger execution is privileged (access-control spec): owner and service_role only.
revoke all on function public._ledger_manage(bigint, date) from public, anon, authenticated;
revoke all on function public._ledger_pending(bigint, date) from public, anon, authenticated;
revoke all on function public.process_ledger(date) from public, anon, authenticated;
grant execute on function public._ledger_manage(bigint, date) to service_role;
grant execute on function public._ledger_pending(bigint, date) to service_role;
grant execute on function public.process_ledger(date) to service_role;
