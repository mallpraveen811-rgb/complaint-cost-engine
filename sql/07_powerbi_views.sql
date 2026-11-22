-- =====================================================================
-- 07_powerbi_views.sql  |  The ONLY objects Power BI connects to (schema "pbi")
-- Why a separate layer? Power BI gets clean names and stable columns; you can
-- change the SQL underneath without breaking the report.
-- In Power BI: Get Data -> PostgreSQL -> server localhost, db complaint_cost ->
-- tick everything in the "pbi" schema -> Load (Import mode).
-- =====================================================================
DROP VIEW IF EXISTS pbi.fact_orders, pbi.dim_date, pbi.dim_seller, pbi.dim_product,
  pbi.dim_customer, pbi.dim_complaint_category, pbi.complaint_impact, pbi.seller_scorecard,
  pbi.kpi_monthly, pbi.delivery_vs_review, pbi.complaint_effect_on_sellers,
  pbi.repeat_purchase, pbi.exec_summary, pbi.review_examples, pbi.category_complaint_matrix,
  pbi.tagging_coverage, pbi.model_quality CASCADE;

-- fact table for the model (relationships are made on the *_key columns)
CREATE VIEW pbi.fact_orders AS
SELECT order_id, order_date, order_month, customer_key, seller_key, product_key,
       customer_state, order_status, order_value, delivery_days, delay_days, is_late,
       review_score, has_comment, is_tagged, sentiment,
       COALESCE(primary_category, CASE WHEN has_comment THEN 'not_tagged' ELSE 'no_text' END) AS complaint_category,
       severity, wont_buy_again, is_complaint, is_at_risk
FROM mart.order_complaints;

CREATE VIEW pbi.dim_date     AS SELECT * FROM dw.dim_date;
CREATE VIEW pbi.dim_seller   AS
SELECT s.seller_key, s.city AS seller_city, s.state AS seller_state, st.state_name AS seller_state_name
FROM dw.dim_seller s LEFT JOIN dw.dim_state st ON st.state = s.state;
CREATE VIEW pbi.dim_product  AS SELECT product_key, category AS product_category FROM dw.dim_product;
CREATE VIEW pbi.dim_customer AS
SELECT c.customer_key, c.city AS customer_city, c.state AS customer_state, st.state_name,
       st.region, st.state_name || ', Brazil' AS map_location
FROM dw.dim_customer c LEFT JOIN dw.dim_state st ON st.state = c.state;

CREATE VIEW pbi.dim_complaint_category AS
SELECT category AS complaint_category, display_name, is_complaint, owner_team, description
FROM ai.complaint_categories
UNION ALL SELECT 'not_tagged', 'Text not tagged (outside sample)', false, '-', 'Review has text but was not in the tagged sample'
UNION ALL SELECT 'no_text',    'No written review', false, '-', 'Customer gave only a star score';

-- pre-aggregated analysis tables (simple visuals, no heavy DAX needed)
CREATE VIEW pbi.complaint_impact            AS SELECT * FROM mart.complaint_category_impact;
CREATE VIEW pbi.seller_scorecard            AS SELECT * FROM mart.seller_scorecard;
CREATE VIEW pbi.kpi_monthly                 AS SELECT * FROM mart.kpi_monthly;
CREATE VIEW pbi.delivery_vs_review          AS SELECT * FROM mart.delivery_vs_review;
CREATE VIEW pbi.complaint_effect_on_sellers AS SELECT * FROM mart.complaint_effect_on_sellers;
CREATE VIEW pbi.repeat_purchase             AS SELECT * FROM mart.repeat_purchase_by_first_experience;
CREATE VIEW pbi.category_complaint_matrix   AS SELECT * FROM mart.category_complaint_matrix;
CREATE VIEW pbi.tagging_coverage            AS SELECT * FROM mart.tagging_coverage;

-- AI-written monthly summary, shown as text on the front page
CREATE VIEW pbi.exec_summary AS
SELECT period_month, headline, summary, action_1, action_2, action_3, model, created_at,
       (period_month = (SELECT max(period_month) FROM ai.exec_summary)) AS is_latest
FROM ai.exec_summary;

-- real customer quotes (translated by the LLM) for the drill-through page
CREATE VIEW pbi.review_examples AS
SELECT o.order_id, o.seller_key, o.order_date, o.primary_category AS complaint_category,
       o.severity, o.review_score, o.summary_en, r.comment_text AS original_text_pt
FROM mart.order_complaints o
JOIN stg.reviews r ON r.order_id = o.order_id
WHERE o.is_tagged;

-- model quality (only filled after you label a validation sample)
CREATE VIEW pbi.model_quality AS
SELECT count(*) AS labelled_reviews,
       round(avg((v.manual_category = t.primary_category)::int), 4) AS llm_accuracy,
       max(t.model) AS model
FROM ai.validation_labels v
JOIN ai.review_insights t USING (review_id);
