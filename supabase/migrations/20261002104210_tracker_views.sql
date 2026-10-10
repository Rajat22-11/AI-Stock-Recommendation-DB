
create view public.v_positions with (security_invoker = true) as
select po.id as position_id, po.signal_id, sg.symbol, sg.verdict, sg.why_grade, sg.setup, sg.source, sg.skill_version,
       sg.signal_date, sg.signal_close, sg.pivot, sg.vol_mult, sg.correction_pct, sg.base_range_pct, sg.dist_sma_pct, sg.retro_seeded,
       po.status, po.planned_size_pct, po.fill_date, po.fill_price, po.qty_initial, po.qty_open, po.avg_cost, po.gross_bought,
       po.stop_at_fill, po.stop_current, po.trim_price, po.trimmed, po.exit_date, po.exit_price, po.exit_reason,
       po.realized_pnl, po.costs,
       case when po.gross_bought > 0 then round(po.realized_pnl / po.gross_bought * 100, 2) end as realized_return_pct,
       case when po.fill_price > po.stop_at_fill and po.qty_initial > 0
            then round(po.realized_pnl / (po.qty_initial * (po.fill_price - po.stop_at_fill)), 2) end as r_multiple,
       case when po.fill_date is not null then coalesce(po.exit_date, current_date) - po.fill_date end as days_held
  from public.positions po join public.signals sg on sg.id = po.signal_id;

create view public.v_open_positions with (security_invoker = true) as
select vp.*, m.mark_date, m.close as last_close, m.market_value, m.unrealized_pnl, m.unrealized_pct, m.dist_to_stop_pct,
       round((vp.trim_price / nullif(m.close, 0) - 1) * 100, 2) as dist_to_trim_pct
  from public.v_positions vp
  left join lateral (select * from public.marks mk where mk.position_id = vp.position_id order by mk.mark_date desc limit 1) m on true
 where vp.status = 'open';

create view public.v_equity_daily with (security_invoker = true) as
with cap as (select public.cfg_num('paper_capital') as c),
dates as (select distinct mark_date as d from public.marks),
lm as (
  select dt.d, m.qty_open, m.cost_basis, m.market_value, m.unrealized_pnl
    from dates dt
    cross join lateral (select distinct on (mk.position_id) mk.position_id, mk.qty_open, mk.cost_basis, mk.market_value, mk.unrealized_pnl
                          from public.marks mk where mk.mark_date <= dt.d
                         order by mk.position_id, mk.mark_date desc) m),
agg as (select d, sum(cost_basis) cb, sum(market_value) mv, sum(unrealized_pnl) unreal, count(*) filter (where qty_open > 0) n from lm group by d),
eq as (
  select a.d as as_of, cap.c as capital,
         coalesce((select sum(e.pnl) from public.events e where e.event_date <= a.d), 0) as realized_cum,
         a.cb as invested, a.mv as market_value, a.unreal as unrealized, a.n as open_positions
    from agg a cross join cap)
select as_of, capital, round(capital + realized_cum - invested, 2) as cash, invested, market_value, realized_cum, unrealized,
       round(capital + realized_cum + unrealized, 2) as equity,
       round(capital + realized_cum + unrealized - coalesce(lag(capital + realized_cum + unrealized) over (order by as_of), capital), 2) as day_pnl,
       round(((capital + realized_cum + unrealized) / capital - 1) * 100, 3) as return_pct,
       open_positions
  from eq order by as_of;

create view public.v_pnl_monthly with (security_invoker = true) as
with last_day as (select distinct on (date_trunc('month', as_of)) date_trunc('month', as_of)::date as month, equity, as_of
                    from public.v_equity_daily order by date_trunc('month', as_of), as_of desc)
select l.month, l.equity as equity_end,
       round(l.equity - coalesce(lag(l.equity) over (order by l.month), public.cfg_num('paper_capital')), 2) as pnl,
       round((l.equity / coalesce(lag(l.equity) over (order by l.month), public.cfg_num('paper_capital')) - 1) * 100, 2) as return_pct,
       (select coalesce(sum(e.pnl), 0) from public.events e where date_trunc('month', e.event_date) = l.month) as realized,
       (select count(*) from public.positions p where p.status = 'closed' and date_trunc('month', p.exit_date) = l.month) as trades_closed,
       (select count(*) from public.positions p where p.status = 'closed' and p.realized_pnl > 0 and date_trunc('month', p.exit_date) = l.month) as winners
  from last_day l order by l.month;

create view public.v_pnl_yearly with (security_invoker = true) as
with last_day as (select distinct on (date_trunc('year', as_of)) date_trunc('year', as_of)::date as year, equity
                    from public.v_equity_daily order by date_trunc('year', as_of), as_of desc)
select extract(year from l.year)::int as year, l.equity as equity_end,
       round(l.equity - coalesce(lag(l.equity) over (order by l.year), public.cfg_num('paper_capital')), 2) as pnl,
       round((l.equity / coalesce(lag(l.equity) over (order by l.year), public.cfg_num('paper_capital')) - 1) * 100, 2) as return_pct,
       (select count(*) from public.positions p where p.status = 'closed' and date_trunc('year', p.exit_date) = l.year) as trades_closed
  from last_day l order by l.year;

create view public.v_trade_stats with (security_invoker = true) as
select grouping(verdict, why_grade, setup, skill_version) as grp, verdict, why_grade, setup, skill_version,
       count(*) filter (where status = 'closed') as closed,
       count(*) filter (where status = 'open') as open,
       count(*) filter (where status in ('expired','skipped')) as not_filled,
       round(avg((realized_pnl > 0)::int) filter (where status = 'closed') * 100, 1) as win_rate_pct,
       round(avg(realized_return_pct) filter (where status = 'closed'), 2) as avg_return_pct,
       round(avg(r_multiple) filter (where status = 'closed'), 2) as avg_r,
       round(avg(days_held) filter (where status = 'closed'), 1) as avg_days_held,
       round(sum(realized_pnl), 2) as realized_pnl
  from public.v_positions
 group by grouping sets ((), (verdict), (why_grade), (setup), (skill_version), (verdict, why_grade));

create view public.v_signal_outcomes with (security_invoker = true) as
select s.id as signal_id, s.symbol, s.signal_date, s.source, s.verdict, s.provisional, s.why_grade, s.skill_version, s.retro_seeded,
       s.signal_close, s.alert_trigger, s.stop,
       (select min(pb.bar_date) from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date > s.signal_date and pb.high > s.alert_trigger) as trigger_hit_date,
       (select min(pb.bar_date) from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date > s.signal_date and pb.low <= s.stop) as stop_touch_date,
       round((select pb.close from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date >= s.signal_date + 7 order by pb.bar_date limit 1) / s.signal_close * 100 - 100, 2) as ret_1w_pct,
       round((select pb.close from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date >= s.signal_date + 28 order by pb.bar_date limit 1) / s.signal_close * 100 - 100, 2) as ret_4w_pct,
       round((select pb.close from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date >= s.signal_date + 91 order by pb.bar_date limit 1) / s.signal_close * 100 - 100, 2) as ret_13w_pct,
       round((select max(pb.high) from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date > s.signal_date and pb.bar_date <= s.signal_date + 28) / s.signal_close * 100 - 100, 2) as max_up_4w_pct,
       round((select min(pb.low) from public.price_bars pb where pb.symbol = s.symbol and pb.bar_date > s.signal_date and pb.bar_date <= s.signal_date + 28) / s.signal_close * 100 - 100, 2) as max_down_4w_pct,
       (select max(pb.bar_date) from public.price_bars pb where pb.symbol = s.symbol) as last_bar
  from public.signals s
 where not exists (select 1 from public.signals x where x.supersedes = s.id);

create view public.v_activity with (security_invoker = true) as
select s.created_at as ts, s.signal_date as d, 'signal' as kind, s.symbol, s.verdict as what, s.source, s.provisional,
       s.stop as price, null::int as qty, null::numeric as pnl, coalesce(s.why_text, s.notes) as detail, s.id as signal_id, null::bigint as position_id
  from public.signals s
union all
select e.created_at, e.event_date, 'event', e.symbol, e.event_type, null, false, e.price, e.qty, e.pnl, e.rule, e.signal_id, e.position_id
  from public.events e;

grant execute on function public.cfg_num(text) to anon, authenticated;
;
