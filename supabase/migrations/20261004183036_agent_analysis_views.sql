
create or replace view v_signal_checklist with (security_invoker = true) as
select s.id as signal_id, s.symbol, s.verdict, s.signal_date, (ex.signal_id is not null) as excluded,
       c.ord, c.rule, c.measured, c.target, c.status
  from signals s
  left join signal_exclusions ex on ex.signal_id = s.id
  cross join lateral (values
   (1, 'Weekly close above pivot',
       case when s.pivot > 0 and s.signal_close is not null then round((s.signal_close / s.pivot - 1) * 100, 2)::text || '% vs pivot ' || s.pivot::text end,
       'close > 52w-high pivot',
       case when s.pivot is null or s.signal_close is null then 'n/a'
            when s.signal_close > s.pivot then 'pass'
            when s.verdict in ('WAIT','WAIT_ALERT') then 'pending' else 'fail' end),
   (2, 'Breakout volume',
       s.vol_mult::text || 'x (needed ' || coalesce(s.req_vol_mult, 2)::text || 'x)',
       '>= 2x 20w median; 2-3x best, 5-10x weaker, >10x weakest',
       case when s.vol_mult is null then 'n/a'
            when s.vol_mult < coalesce(s.req_vol_mult, 2) then case when s.verdict in ('WAIT','WAIT_ALERT') then 'pending' else 'fail' end
            when s.vol_mult > 5 then 'weak' else 'pass' end),
   (3, '13w SMA rising',
       case when s.sma13_rising then 'rising' when not s.sma13_rising then 'flat/falling' end,
       'rising',
       case when s.sma13_rising is null then 'n/a' when s.sma13_rising then 'pass' else 'fail' end),
   (4, 'Distance above 13w SMA',
       s.dist_sma_pct::text || '%',
       '<= 10% best; 10-30% weaker; > 30% extended',
       case when s.dist_sma_pct is null then 'n/a' when s.dist_sma_pct <= 10 then 'pass' when s.dist_sma_pct <= 30 then 'weak' else 'fail' end),
   (5, 'Prior correction depth',
       s.correction_pct::text || '%',
       '>= 35% best (Setup A); Setup B needs none',
       case when s.correction_pct is null then 'n/a' when s.correction_pct >= 35 or s.setup like 'B%' then 'pass'
            when s.correction_pct >= 20 then 'weak' else 'fail' end),
   (6, 'Close location in weekly range',
       s.close_loc::text,
       '>= 0.7 strong; < 0.5 weak close',
       case when s.close_loc is null then 'n/a' when s.close_loc >= 0.7 then 'pass' when s.close_loc >= 0.5 then 'weak' else 'fail' end),
   (7, 'Fundamental why (grade)',
       coalesce(s.why_grade, '-'),
       'A/B full size; C half; D none or token',
       case when s.why_grade is null then 'n/a' when s.why_grade in ('A','B') then 'pass' when s.why_grade = 'C' then 'weak' else 'fail' end),
   (8, 'Risk to stop',
       s.risk_pct::text || '%',
       '<= 8% of fill',
       case when s.risk_pct is null then 'n/a' when s.risk_pct <= 8 then 'pass' else 'fail' end),
   (9, 'Liquidity',
       coalesce(s.liquidity_tier, '-'),
       'liquid (stop can execute)',
       case when s.liquidity_tier is null then 'n/a' when s.liquidity_tier = 'liquid' then 'pass' else 'weak' end)
  ) as c(ord, rule, measured, target, status);

create or replace view v_signal_plan with (security_invoker = true) as
with k as (select cfg_num('paper_capital') cap, cfg_num('trim_multiple') tm, cfg_num('stop_cap_pct') sc),
b as (
  select s.*, (ex.signal_id is not null) as excluded,
         coalesce(s.entry_low, s.alert_trigger, s.signal_close) as entry_ref,
         coalesce(s.size_pct, case when s.verdict = 'ENTRY_REDUCED' or s.why_grade in ('C','D') then 5 else 10 end) as size_plan
    from signals s left join signal_exclusions ex on ex.signal_id = s.id
), c as (
  select b.*, coalesce(b.stop, round(b.entry_ref * (1 - k.sc / 100), 2)) as stop_ref,
         coalesce(b.trim_price, round(b.entry_ref * k.tm, 2)) as trim_ref, k.cap
    from b cross join k
)
select c.id as signal_id, c.run_id, c.symbol, c.signal_date, c.verdict, c.setup, c.stage, c.why_grade, c.priority_rank,
       c.excluded, c.retro_seeded, c.skill_version,
       c.entry_ref, c.entry_high, c.stop_ref, c.trim_ref, c.size_plan as size_pct,
       round((1 - c.stop_ref / nullif(c.entry_ref, 0)) * 100, 2) as risk_pct_plan,
       round((c.trim_ref / nullif(c.entry_ref, 0) - 1) * 100, 2) as reward_pct_plan,
       round((c.trim_ref - c.entry_ref) / nullif(c.entry_ref - c.stop_ref, 0), 2) as rr_plan,
       round(c.cap * c.size_plan / 100, 0) as position_value,
       round(c.cap * c.size_plan / 100 * (1 - c.stop_ref / nullif(c.entry_ref, 0)), 0) as rupee_risk,
       round(c.cap * c.size_plan / 100 * (c.trim_ref / nullif(c.entry_ref, 0) - 1), 0) as rupee_reward_at_trim,
       round(c.size_plan * (1 - c.stop_ref / nullif(c.entry_ref, 0)), 2) as capital_risk_pct,
       ck.passes, ck.weak, ck.fails, ck.failed_rules,
       po.status as book_status, po.exit_reason as book_reason, po.fill_price, po.fill_date
  from c
  left join lateral (
    select count(*) filter (where status = 'pass') passes,
           count(*) filter (where status = 'weak') weak,
           count(*) filter (where status = 'fail') fails,
           string_agg(rule, '; ' order by ord) filter (where status = 'fail') failed_rules
      from v_signal_checklist v where v.signal_id = c.id) ck on true
  left join positions po on po.signal_id = c.id;

create or replace view v_suggestions with (security_invoker = true) as
with thru as (select coalesce((select (value #>> '{}')::date from config where key = 'processed_through'), current_date) d),
latest as (
  select distinct on (s.symbol) s.*
    from signals s
   where s.signal_date >= (select d from thru) - 31
     and not exists (select 1 from signals y where y.supersedes = s.id)
     and not exists (select 1 from signal_exclusions ex where ex.signal_id = s.id)
   order by s.symbol, s.signal_date desc, s.id desc
), cash as (select cash from v_equity_daily order by as_of desc limit 1)
select case when l.verdict in ('ENTRY','ENTRY_REDUCED') then 'entry' else 'watch' end as bucket,
       p.*, l.why_text, l.notes, l.pivot, l.alert_trigger, l.req_vol_abs, l.vol_mult, l.window_start, l.window_end,
       r.thesis, r.catalyst, r.risks, r.invalidation, r.alternatives, r.data_gaps, r.confidence,
       (select cash from cash) as book_cash,
       (p.position_value <= coalesce((select cash from cash), 0)) as fundable_now
  from latest l
  join v_signal_plan p on p.signal_id = l.id
  left join signal_rationale r on r.signal_id = l.id
 where l.verdict in ('ENTRY','ENTRY_REDUCED','WAIT_ALERT','WAIT')
 order by case when l.verdict in ('ENTRY','ENTRY_REDUCED') then 0 else 1 end, l.priority_rank nulls last, p.rr_plan desc nulls last;

create or replace view v_trade_review with (security_invoker = true) as
with thru as (select coalesce((select (value #>> '{}')::date from config where key = 'processed_through'), current_date) d)
select vp.position_id, vp.signal_id, vp.symbol, vp.verdict, vp.why_grade, vp.setup, vp.vol_mult, vp.dist_sma_pct, vp.correction_pct,
       vp.status, vp.fill_date, vp.fill_price, vp.stop_at_fill, vp.trim_price, vp.exit_date, vp.exit_price, vp.exit_reason,
       vp.realized_pnl, vp.r_multiple, vp.days_held,
       pl.rr_plan, pl.passes, pl.weak, pl.fails, pl.failed_rules,
       round((1 - vp.stop_at_fill / nullif(vp.fill_price, 0)) * 100, 2) as ledger_risk_pct,
       round(vp.fill_price * 0.92, 2) as skill_stop,
       round((h.max_high / vp.fill_price - 1) * 100, 2) as mfe_pct,
       round((h.min_low / vp.fill_price - 1) * 100, 2) as mae_pct,
       round((a.low_since_fill / vp.fill_price - 1) * 100, 2) as worst_since_fill_pct,
       (a.low_since_fill > round(vp.fill_price * 0.92, 2)) as skill_stop_still_intact,
       round((x.high_after / nullif(vp.exit_price, 0) - 1) * 100, 2) as post_exit_run_pct,
       case
         when vp.status in ('pending','expired','skipped') then vp.status
         when vp.status = 'open' then 'open'
         when vp.exit_reason = 'stop_hit' and vp.exit_price < vp.stop_at_fill then 'gap_through_stop'
         when vp.exit_reason = 'stop_hit' and a.low_since_fill > round(vp.fill_price * 0.92, 2) then 'whipsaw_tight_stop'
         when vp.exit_reason = 'stop_hit' and coalesce(x.high_after / nullif(vp.exit_price, 0), 0) >= 1.15 then 'missed_runner'
         when vp.exit_reason = 'stop_hit' then 'valid_stop'
         when vp.realized_pnl > 0 then 'winner'
         else 'loser'
       end as auto_tag,
       tr.tag as review_tag, tr.lesson as review_lesson, tr.author as review_author
  from v_positions vp
  cross join thru
  left join v_signal_plan pl on pl.signal_id = vp.signal_id
  left join lateral (select max(high) max_high, min(low) min_low from price_bars pb
                      where pb.symbol = vp.symbol and pb.bar_date between vp.fill_date and coalesce(vp.exit_date, thru.d)) h on true
  left join lateral (select min(low) low_since_fill from price_bars pb
                      where pb.symbol = vp.symbol and pb.bar_date between vp.fill_date and thru.d) a on true
  left join lateral (select max(high) high_after from price_bars pb
                      where pb.symbol = vp.symbol and vp.exit_date is not null and pb.bar_date > vp.exit_date and pb.bar_date <= vp.exit_date + 30) x on true
  left join lateral (select * from trade_reviews t where t.signal_id = vp.signal_id order by t.id desc limit 1) tr on true;

create or replace view v_book_risk with (security_invoker = true) as
with e as (select * from v_equity_daily order by as_of desc limit 1),
o as (select count(*) n,
             coalesce(sum(greatest(0, qty_open * (last_close - stop_current))), 0) as risk_from_price,
             coalesce(sum(qty_open * (avg_cost - stop_current)), 0) as risk_from_cost,
             round(avg(dist_to_stop_pct), 2) as avg_dist_to_stop_pct,
             round(avg(dist_to_trim_pct), 2) as avg_dist_to_trim_pct
        from v_open_positions),
pe as (select count(*) n, coalesce(sum(cfg_num('paper_capital') * planned_size_pct / 100), 0) as committed
         from positions where status = 'pending')
select e.as_of, e.capital, e.equity, e.cash, e.invested, round(e.cash / nullif(e.equity, 0) * 100, 2) as cash_pct,
       o.n as open_positions, cfg_num('max_open_positions')::int as max_open_positions,
       round(o.risk_from_price, 0) as open_risk_rupees, round(o.risk_from_price / nullif(e.equity, 0) * 100, 2) as open_risk_pct,
       round(o.risk_from_cost, 0) as risk_vs_cost_rupees, o.avg_dist_to_stop_pct, o.avg_dist_to_trim_pct,
       pe.n as pending_entries, round(pe.committed, 0) as pending_committed_rupees,
       round(e.cash - pe.committed, 0) as cash_after_pending
  from e cross join o cross join pe;

create or replace view v_run_log with (security_invoker = true) as
select r.id as run_id, r.run_type, r.data_as_of, r.started_at, r.skill_version, r.model, r.status, r.summary, r.data_calls, r.notes,
       (select jsonb_object_agg(verdict, n) from (select verdict, count(*) n from signals where run_id = r.id group by verdict) t) as verdicts,
       rv.observations, rv.lessons, rv.proposed_change, rv.proposal_status, rv.stats as review_stats
  from runs r
  left join lateral (select * from reviews where run_id = r.id order by id desc limit 1) rv on true;

create or replace view v_rule_effectiveness with (security_invoker = true) as
select ck.ord, ck.rule, ck.status,
       count(*) as trades,
       count(*) filter (where vp.realized_pnl > 0) as winners,
       round(avg(vp.r_multiple), 2) as avg_r,
       round(avg(vp.realized_return_pct), 2) as avg_return_pct
  from v_positions vp join v_signal_checklist ck on ck.signal_id = vp.signal_id
 where vp.status = 'closed'
 group by ck.ord, ck.rule, ck.status;

grant select on v_signal_checklist, v_signal_plan, v_suggestions, v_trade_review, v_book_risk, v_run_log, v_rule_effectiveness to anon, authenticated;
;
