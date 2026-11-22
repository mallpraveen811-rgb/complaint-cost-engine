-- =====================================================================
-- 10_import_ai_results.sql  |  CSV -> SQL: load the LLM output back in
-- Loads into a temp table first, then UPSERTs, so a re-run never duplicates rows
-- and a bad row cannot half-load the real table.
-- =====================================================================
CREATE TEMP TABLE _in (
  review_id text, sentiment text, primary_category text, secondary_category text,
  severity text, wont_buy_again boolean, summary_en text, method text, model text);

\copy _in FROM 'data/work/review_insights.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

INSERT INTO ai.review_insights AS t
  (review_id, sentiment, primary_category, secondary_category, severity,
   wont_buy_again, summary_en, method, model)
SELECT review_id, sentiment, primary_category, NULLIF(secondary_category, ''), severity,
       wont_buy_again, summary_en, method, model
FROM _in
WHERE review_id IN (SELECT review_id FROM stg.reviews)
ON CONFLICT (review_id) DO UPDATE SET
  sentiment = EXCLUDED.sentiment, primary_category = EXCLUDED.primary_category,
  secondary_category = EXCLUDED.secondary_category, severity = EXCLUDED.severity,
  wont_buy_again = EXCLUDED.wont_buy_again, summary_en = EXCLUDED.summary_en,
  method = EXCLUDED.method, model = EXCLUDED.model, tagged_at = now();

SELECT method, count(*) AS tagged_reviews FROM ai.review_insights GROUP BY method;
