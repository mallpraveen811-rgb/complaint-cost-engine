-- =====================================================================
-- 06_analysis_views.sql  |  The business analysis layer ("mart")
-- Each view answers one business question. Re-run any time after new tags.
--
-- KEY DEFINITIONS:
--   Complaint order    : an order whose review the LLM tagged with a complaint category
--   Exposed revenue    : total value of complaint orders
--   Revenue at risk    : value of complaint orders where the customer says they won't
--                        buy again OR the LLM rated the problem 'high' severity
--   Coverage factor    : commented reviews / tagged reviews. If you tag a 10k sample out
--                        of 40k, totals are multiplied by ~4 to estimate the full picture.
-- =====================================================================
DROP VIEW IF EXISTS mart.order_complaints, mart.kpi_monthly, mart.complaint_category_impact,
  mart.seller_monthly, mart.complaint_effect_on_sellers, mart.seller_scorecard,
  mart.delivery_vs_review, mart.repeat_purchase_by_first_experience, mart.state_summary,
  mart.category_complaint_matrix, mart.tagging_coverage CASCADE;

-- 0. coverage of the LLM step --------------------------------------------------------
CREATE VIEW mart.tagging_coverage AS
SELECT count(*) FILTER (WHERE r.comment_text IS NOT NULL)                AS reviews_with_text,
       count(t.review_id)                                               AS reviews_tagged,
       round(count(*) FILTER (WHERE r.comment_text IS NOT NULL)::numeric
             / NULLIF(count(t.review_id), 0), 3)                         AS coverage_factor
FROM stg.reviews r
LEFT JOIN ai.review_insights t ON t.review_id = r.review_id;

-- 1. one row per order, enriched with the AI tag ------------------------------------
CREATE VIEW mart.order_complaints AS
SELECT f.order_id, f.order_date, date_trunc('month', f.order_date)::date AS order_month,
       f.customer_key, f.seller_key, f.product_key, p.category AS product_category,
       c.state AS customer_state, f.order_status, f.order_value, f.delivery_days,
       f.delay_days, f.is_late, f.review_score, f.has_comment,
       (t.review_id IS NOT NULL)                       AS is_tagged,
       t.sentiment, t.primary_category, t.secondary_category, t.severity,
       t.wont_buy_again, t.summary_en,
       COALESCE(cc.is_complaint, false)                AS is_complaint,
       (COALESCE(cc.is_complaint, false)
        AND (t.wont_buy_again OR t.severity = 'high')) AS is_at_risk
FROM dw.fact_orders f
LEFT JOIN dw.dim_product p           ON p.product_key = f.product_key
LEFT JOIN dw.dim_customer c          ON c.customer_key = f.customer_key
LEFT JOIN ai.review_insights t       ON t.review_id = f.review_id
LEFT JOIN ai.complaint_categories cc ON cc.category = t.primary_category;

-- 2. monthly KPIs with month-over-month change (window function LAG) -----------------
CREATE VIEW mart.kpi_monthly AS
WITH m AS (
  SELECT order_month,
         count(*)                                                    AS orders,
         round(sum(order_value), 2)                                  AS revenue,
         round(avg(order_value), 2)                                  AS avg_order_value,
         round(avg(delivery_days), 1)                                AS avg_delivery_days,
         round(100.0 * avg(is_late::int), 1)                         AS late_pct,
         round(avg(review_score), 2)                                 AS avg_review_score,
         round(100.0 * avg((review_score <= 2)::int), 1)             AS bad_review_pct,
         count(*) FILTER (WHERE is_tagged)                           AS tagged_reviews,
         count(*) FILTER (WHERE is_complaint)                        AS complaint_orders,
         round(100.0 * count(*) FILTER (WHERE is_complaint)
               / NULLIF(count(*) FILTER (WHERE is_tagged), 0), 1)    AS complaint_share_pct,
         round(COALESCE(sum(order_value) FILTER (WHERE is_at_risk), 0), 2) AS revenue_at_risk
  FROM mart.order_complaints
  GROUP BY order_month
)
SELECT m.*,
       round(100.0 * (revenue - lag(revenue) OVER w) / NULLIF(lag(revenue) OVER w, 0), 1) AS revenue_mom_pct,
       round(late_pct - lag(late_pct) OVER w, 1)                     AS late_pct_change_pts,
       round(complaint_share_pct - lag(complaint_share_pct) OVER w, 1) AS complaint_share_change_pts
FROM m
WINDOW w AS (ORDER BY order_month);

-- 3. THE HEADLINE TABLE: which complaint costs the most? (ranked) --------------------
CREATE VIEW mart.complaint_category_impact AS
WITH base AS (
  SELECT o.primary_category AS category,
         count(*)                                         AS complaints,
         round(sum(o.order_value), 2)                     AS exposed_revenue,
         round(sum(o.order_value) FILTER (WHERE o.is_at_risk), 2) AS revenue_at_risk,
         round(avg(o.review_score), 2)                    AS avg_review_score,
         round(100.0 * avg(o.wont_buy_again::int), 1)     AS wont_buy_again_pct,
         round(100.0 * avg((o.severity = 'high')::int), 1) AS high_severity_pct,
         round(100.0 * avg(o.is_late::int), 1)            AS late_pct,
         round(avg(o.delay_days) FILTER (WHERE o.is_late), 1) AS avg_days_late_when_late
  FROM mart.order_complaints o
  WHERE o.is_complaint
  GROUP BY o.primary_category
)
SELECT b.category, cc.display_name, cc.owner_team, b.complaints,
       round(100.0 * b.complaints / sum(b.complaints) OVER (), 1) AS share_of_complaints_pct,
       b.exposed_revenue, COALESCE(b.revenue_at_risk, 0) AS revenue_at_risk,
       round(COALESCE(b.revenue_at_risk, 0) * cov.coverage_factor, 2) AS est_revenue_at_risk_full_data,
       b.avg_review_score, b.wont_buy_again_pct, b.high_severity_pct, b.late_pct,
       b.avg_days_late_when_late,
       rank() OVER (ORDER BY COALESCE(b.revenue_at_risk, 0) DESC) AS fix_priority_rank
FROM base b
JOIN ai.complaint_categories cc ON cc.category = b.category
CROSS JOIN mart.tagging_coverage cov;

-- 4. seller x month panel, with NEXT month's revenue (window function LEAD) ----------
CREATE VIEW mart.seller_monthly AS
WITH sm AS (
  SELECT seller_key, order_month,
         count(*)                                        AS orders,
         sum(order_value)                                AS revenue,
         count(review_score)                             AS reviewed_orders,
         avg((review_score <= 2)::int)                   AS bad_review_rate,
         avg(is_late::int)                               AS late_rate,
         count(*) FILTER (WHERE is_complaint)            AS complaint_orders
  FROM mart.order_complaints
  WHERE seller_key IS NOT NULL
  GROUP BY seller_key, order_month
), full_grid AS (            -- fill months with zero sales so LEAD sees "no sales" too
  SELECT s.seller_key, d.month_start AS order_month
  FROM (SELECT seller_key, min(order_month) AS first_m, max(order_month) AS last_m
        FROM sm GROUP BY seller_key) s
  JOIN (SELECT DISTINCT month_start FROM dw.dim_date) d
    ON d.month_start BETWEEN s.first_m AND (SELECT max(order_month) FROM sm)
)
SELECT g.seller_key, g.order_month,
       COALESCE(sm.orders, 0)                AS orders,
       round(COALESCE(sm.revenue, 0), 2)     AS revenue,
       sm.reviewed_orders,
       round(sm.bad_review_rate, 3)          AS bad_review_rate,
       round(sm.late_rate, 3)                AS late_rate,
       COALESCE(sm.complaint_orders, 0)      AS complaint_orders,
       round(lead(COALESCE(sm.revenue, 0)) OVER w, 2)  AS next_month_revenue,
       round(100.0 * (lead(COALESCE(sm.revenue, 0)) OVER w - COALESCE(sm.revenue, 0))
             / NULLIF(sm.revenue, 0), 1)     AS next_month_revenue_change_pct
FROM full_grid g
LEFT JOIN sm ON sm.seller_key = g.seller_key AND sm.order_month = g.order_month
WINDOW w AS (PARTITION BY g.seller_key ORDER BY g.order_month);

-- 5. EVIDENCE: do sellers lose sales after a month with many bad reviews? -------------
-- Only seller-months with >= 5 reviewed orders and a following month to compare.
CREATE VIEW mart.complaint_effect_on_sellers AS
SELECT CASE WHEN bad_review_rate < 0.10 THEN '1. Low (<10% bad reviews)'
            WHEN bad_review_rate < 0.25 THEN '2. Medium (10-25%)'
            ELSE                             '3. High (25%+)' END       AS bad_review_band,
       count(*)                                                        AS seller_months,
       round(avg(next_month_revenue_change_pct), 1)                    AS avg_next_month_change_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY next_month_revenue_change_pct)::numeric, 1)
                                                                       AS median_next_month_change_pct,
       round(100.0 * avg((next_month_revenue = 0)::int), 1)            AS pct_zero_sales_next_month
FROM mart.seller_monthly
WHERE reviewed_orders >= 5
  AND next_month_revenue IS NOT NULL
  AND order_month < (SELECT max(order_month) FROM mart.seller_monthly)
GROUP BY 1
ORDER BY 1;

-- 6. seller scorecard: who needs help, and with what? ----------------------------
CREATE VIEW mart.seller_scorecard AS
WITH s AS (
  SELECT seller_key,
         count(*)                                         AS orders,
         round(sum(order_value), 2)                       AS revenue,
         round(avg(review_score), 2)                      AS avg_review_score,
         round(100.0 * avg(is_late::int), 1)              AS late_pct,
         count(*) FILTER (WHERE is_tagged)                AS tagged_reviews,
         count(*) FILTER (WHERE is_complaint)             AS complaints,
         round(COALESCE(sum(order_value) FILTER (WHERE is_at_risk), 0), 2) AS revenue_at_risk,
         mode() WITHIN GROUP (ORDER BY primary_category)
           FILTER (WHERE is_complaint)                    AS top_complaint
  FROM mart.order_complaints
  WHERE seller_key IS NOT NULL
  GROUP BY seller_key
)
SELECT s.*, ds.state AS seller_state, ds.city AS seller_city,
       cc.display_name AS top_complaint_name, cc.owner_team AS top_complaint_owner,
       round(100.0 * s.complaints / NULLIF(s.tagged_reviews, 0), 1) AS complaint_share_pct,
       CASE WHEN s.orders < 10 THEN 'Too few orders'
            WHEN s.avg_review_score < 3.5 OR s.late_pct > 25 THEN 'Needs action'
            WHEN s.avg_review_score < 4.0 OR s.late_pct > 12 THEN 'Watch'
            ELSE 'Healthy' END                                   AS health_status,
       rank() OVER (ORDER BY s.revenue_at_risk DESC)              AS risk_rank
FROM s
LEFT JOIN dw.dim_seller ds ON ds.seller_key = s.seller_key
LEFT JOIN ai.complaint_categories cc ON cc.category = s.top_complaint;

-- 7. delivery delay vs review score (needs no AI at all - a sanity anchor) -------------
CREATE VIEW mart.delivery_vs_review AS
SELECT CASE WHEN delay_days <= -7 THEN 1 WHEN delay_days <= 0 THEN 2 WHEN delay_days <= 3 THEN 3
            WHEN delay_days <= 7 THEN 4 WHEN delay_days <= 14 THEN 5 ELSE 6 END AS bucket_order,
       CASE WHEN delay_days <= -7 THEN 'Early by 7+ days' WHEN delay_days <= 0 THEN 'On time / early <7d'
            WHEN delay_days <= 3 THEN 'Late 1-3 days'     WHEN delay_days <= 7 THEN 'Late 4-7 days'
            WHEN delay_days <= 14 THEN 'Late 8-14 days'   ELSE 'Late 15+ days' END AS delay_bucket,
       count(*)                                          AS orders,
       round(avg(review_score), 2)                       AS avg_review_score,
       round(100.0 * avg((review_score <= 2)::int), 1)   AS bad_review_pct
FROM mart.order_complaints
WHERE delay_days IS NOT NULL AND review_score IS NOT NULL
GROUP BY 1, 2
ORDER BY 1;

-- 8. does a bad FIRST experience stop people from coming back? --------------------
CREATE VIEW mart.repeat_purchase_by_first_experience AS
WITH firsts AS (
  SELECT f.customer_key, o.primary_category, o.is_complaint, o.is_tagged
  FROM dw.fact_orders f
  JOIN mart.order_complaints o ON o.order_id = f.order_id
  WHERE f.customer_order_seq = 1
), repeaters AS (
  SELECT customer_key FROM dw.fact_orders GROUP BY customer_key HAVING count(*) > 1
)
SELECT CASE WHEN NOT fi.is_tagged THEN 'No text review'
            ELSE COALESCE(cc.display_name, 'Other') END   AS first_order_experience,
       count(*)                                           AS customers,
       round(100.0 * avg((r.customer_key IS NOT NULL)::int), 2) AS came_back_pct
FROM firsts fi
LEFT JOIN repeaters r ON r.customer_key = fi.customer_key
LEFT JOIN ai.complaint_categories cc ON cc.category = fi.primary_category
GROUP BY 1
ORDER BY customers DESC;

-- 9. state summary (for the map visual) ----------------------------------------
CREATE VIEW mart.state_summary AS
SELECT customer_state, count(*) AS orders, round(sum(order_value), 2) AS revenue,
       round(avg(delivery_days), 1) AS avg_delivery_days,
       round(100.0 * avg(is_late::int), 1) AS late_pct,
       round(avg(review_score), 2) AS avg_review_score,
       round(COALESCE(sum(order_value) FILTER (WHERE is_at_risk), 0), 2) AS revenue_at_risk
FROM mart.order_complaints
GROUP BY customer_state;

-- 10. product category x complaint type (for the heat-map matrix) ---------------------
CREATE VIEW mart.category_complaint_matrix AS
SELECT product_category, primary_category AS complaint_category, count(*) AS complaints,
       round(sum(order_value), 2) AS exposed_revenue
FROM mart.order_complaints
WHERE is_complaint
GROUP BY 1, 2;
