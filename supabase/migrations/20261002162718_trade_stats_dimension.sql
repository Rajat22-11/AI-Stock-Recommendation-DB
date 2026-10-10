create or replace view public.v_trade_stats
with (security_invoker = true) as
 SELECT GROUPING(verdict, why_grade, setup, skill_version) AS grp,
    verdict,
    why_grade,
    setup,
    skill_version,
    count(*) FILTER (WHERE status = 'closed'::text) AS closed,
    count(*) FILTER (WHERE status = 'open'::text) AS open,
    count(*) FILTER (WHERE status = ANY (ARRAY['expired'::text, 'skipped'::text])) AS not_filled,
    round(avg((realized_pnl > 0::numeric)::integer) FILTER (WHERE status = 'closed'::text) * 100::numeric, 1) AS win_rate_pct,
    round(avg(realized_return_pct) FILTER (WHERE status = 'closed'::text), 2) AS avg_return_pct,
    round(avg(r_multiple) FILTER (WHERE status = 'closed'::text), 2) AS avg_r,
    round(avg(days_held) FILTER (WHERE status = 'closed'::text), 1) AS avg_days_held,
    round(sum(realized_pnl), 2) AS realized_pnl,
    CASE GROUPING(verdict, why_grade, setup, skill_version)
        WHEN 15 THEN 'overall'
        WHEN 7 THEN 'verdict'
        WHEN 11 THEN 'why_grade'
        WHEN 13 THEN 'setup'
        WHEN 14 THEN 'skill_version'
        WHEN 3 THEN 'verdict_why_grade'
        ELSE NULL::text
    END AS dimension
   FROM v_positions
  GROUP BY GROUPING SETS ((), (verdict), (why_grade), (setup), (skill_version), (verdict, why_grade));;
