-- Dates: a cash-only baseline the day before the first fill, then every price_bars session
-- through processed_through (flat days included); one cash-only row when nothing has filled.
create or replace view public.v_equity_daily
with (security_invoker = true) as
 WITH cap AS (
         SELECT cfg_num('paper_capital'::text) AS c
        ), thru AS (
         SELECT (config.value #>> '{}'::text[])::date AS d
           FROM config
          WHERE config.key = 'processed_through'::text
        ), ff AS (
         SELECT min(positions.fill_date) AS d
           FROM positions
        ), dates AS (
         SELECT ff.d - 1 AS d
           FROM ff
          WHERE ff.d IS NOT NULL
        UNION
         SELECT pb.bar_date
           FROM price_bars pb, ff, thru
          WHERE ff.d IS NOT NULL AND pb.bar_date >= ff.d AND pb.bar_date <= thru.d
        UNION
         SELECT thru.d
           FROM thru, ff
          WHERE ff.d IS NULL
        ), agg AS (
         SELECT dt.d,
            COALESCE(sum(m.cost_basis), 0::numeric) AS cb,
            COALESCE(sum(m.market_value), 0::numeric) AS mv,
            COALESCE(sum(m.unrealized_pnl), 0::numeric) AS unreal,
            count(*) FILTER (WHERE m.qty_open > 0) AS n
           FROM dates dt
             LEFT JOIN LATERAL ( SELECT DISTINCT ON (mk.position_id) mk.position_id,
                    mk.qty_open,
                    mk.cost_basis,
                    mk.market_value,
                    mk.unrealized_pnl
                   FROM marks mk
                  WHERE mk.mark_date <= dt.d
                  ORDER BY mk.position_id, mk.mark_date DESC) m ON true
          GROUP BY dt.d
        ), eq AS (
         SELECT a.d AS as_of,
            cap.c AS capital,
            COALESCE(( SELECT sum(e.pnl) AS sum
                   FROM events e
                  WHERE e.event_date <= a.d), 0::numeric) AS realized_cum,
            a.cb AS invested,
            a.mv AS market_value,
            a.unreal AS unrealized,
            a.n AS open_positions
           FROM agg a
             CROSS JOIN cap
        )
 SELECT as_of,
    capital,
    round(capital + realized_cum - invested, 2) AS cash,
    invested,
    market_value,
    realized_cum,
    unrealized,
    round(capital + realized_cum + unrealized, 2) AS equity,
    round(capital + realized_cum + unrealized - COALESCE(lag(capital + realized_cum + unrealized) OVER (ORDER BY as_of), capital), 2) AS day_pnl,
    round(((capital + realized_cum + unrealized) / capital - 1::numeric) * 100::numeric, 3) AS return_pct,
    open_positions
   FROM eq
  ORDER BY as_of;;
