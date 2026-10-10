
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
       '>= 0.7 strong; < 0.5 weak close (judged on the breakout week)',
       case when s.close_loc is null then 'n/a' when s.close_loc >= 0.7 then 'pass'
            when s.verdict in ('WAIT','WAIT_ALERT') then 'pending'
            when s.close_loc >= 0.5 then 'weak' else 'fail' end),
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
;
