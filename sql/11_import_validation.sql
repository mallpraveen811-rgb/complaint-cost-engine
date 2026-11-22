-- =====================================================================
-- 11_import_validation.sql  |  Load your manual labels into SQL (optional)
-- Lets you show model accuracy inside Power BI too.
-- =====================================================================
CREATE TEMP TABLE _lab (review_id text, manual_category text, manual_sentiment text, labelled_by text);
\copy _lab FROM 'data/work/validation_labels.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

INSERT INTO ai.validation_labels (review_id, manual_category, manual_sentiment, labelled_by)
SELECT review_id, manual_category, NULLIF(manual_sentiment, ''), labelled_by FROM _lab
ON CONFLICT (review_id) DO UPDATE SET manual_category = EXCLUDED.manual_category,
  manual_sentiment = EXCLUDED.manual_sentiment, labelled_by = EXCLUDED.labelled_by, labelled_at = now();

-- accuracy computed in SQL (same number as validate_tags.py)
SELECT count(*) AS labelled,
       round(100.0 * avg((v.manual_category = t.primary_category)::int), 1) AS llm_accuracy_pct
FROM ai.validation_labels v
JOIN ai.review_insights t USING (review_id);
