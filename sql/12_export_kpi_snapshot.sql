-- =====================================================================
-- 12_export_kpi_snapshot.sql  |  Package the month's numbers as JSON for the LLM
-- The LLM never queries the database. It only sees this small, checked JSON,
-- so it cannot "make up" data - it can only explain these numbers.
-- Month chosen = the latest month with at least half the average order volume
-- (the last months of the Olist file are almost empty and would mislead).
-- Override:  psql ... -v month=2018-06-01 -f sql/12_export_kpi_snapshot.sql
-- =====================================================================
\if :{?month}
\else
  SELECT max(order_month)::text AS month FROM mart.kpi_monthly
  WHERE orders >= 0.5 * (SELECT avg(orders) FROM mart.kpi_monthly) \gset
\endif

\encoding UTF8
\t on
\a
\o data/work/kpi_snapshot.json
WITH p AS (SELECT :'month'::date AS m, (:'month'::date - interval '1 month')::date AS prev),
cat AS (
  SELECT o.primary_category, cc.display_name, cc.owner_team,
         count(*) FILTER (WHERE o.order_month = p.m)    AS complaints_this_month,
         count(*) FILTER (WHERE o.order_month = p.prev) AS complaints_prev_month,
         round(COALESCE(sum(o.order_value) FILTER (WHERE o.order_month = p.m AND o.is_at_risk), 0), 2)
                                                        AS revenue_at_risk_this_month
  FROM mart.order_complaints o
  JOIN ai.complaint_categories cc ON cc.category = o.primary_category
  CROSS JOIN p
  WHERE o.is_complaint AND o.order_month IN (p.m, p.prev)
  GROUP BY 1, 2, 3
), sel AS (
  SELECT o.seller_key, count(*) AS orders, count(*) FILTER (WHERE o.is_complaint) AS complaints,
         round(COALESCE(sum(o.order_value) FILTER (WHERE o.is_at_risk), 0), 2) AS revenue_at_risk,
         mode() WITHIN GROUP (ORDER BY o.primary_category) FILTER (WHERE o.is_complaint) AS top_complaint
  FROM mart.order_complaints o CROSS JOIN p
  WHERE o.order_month = p.m
  GROUP BY 1
)
SELECT json_build_object(
  'period_month', (SELECT m FROM p),
  'currency', 'BRL',
  'note', 'Complaint counts come from the tagged sample of written reviews; multiply by coverage_factor to estimate the full total.',
  'coverage_factor', (SELECT coverage_factor FROM mart.tagging_coverage),
  'this_month', (SELECT row_to_json(k) FROM mart.kpi_monthly k, p WHERE k.order_month = p.m),
  'previous_month', (SELECT row_to_json(k) FROM mart.kpi_monthly k, p WHERE k.order_month = p.prev),
  'complaints_by_category', (SELECT json_agg(c ORDER BY revenue_at_risk_this_month DESC, complaints_this_month DESC) FROM cat c),
  'top_risk_sellers', (SELECT json_agg(s) FROM (SELECT left(seller_key, 8) AS seller_id_short, orders,
                         complaints, revenue_at_risk, top_complaint
                       FROM sel WHERE complaints > 0
                       ORDER BY revenue_at_risk DESC LIMIT 5) s)
);
\o
\t off
\a
\echo 'Snapshot written to data/work/kpi_snapshot.json for month' :month
