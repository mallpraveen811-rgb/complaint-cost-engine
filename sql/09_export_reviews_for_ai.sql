-- =====================================================================
-- 09_export_reviews_for_ai.sql  |  SQL -> CSV hand-off to the Python/LLM step
-- Exports only reviews that HAVE text and are NOT tagged yet (so re-runs are cheap).
-- Optional sample size:  psql ... -v sample=10000 -f sql/09_export_reviews_for_ai.sql
-- (default = all untagged reviews)
-- =====================================================================
\if :{?sample}
\else
  \set sample 1000000000
\endif

DROP TABLE IF EXISTS ai._to_tag;
CREATE TABLE ai._to_tag AS
SELECT * FROM (
  -- a few reviews are attached to more than one order in Olist: send each text once
  SELECT DISTINCT ON (r.review_id) r.review_id, r.review_score, r.comment_title, r.comment_text
  FROM stg.reviews r
  LEFT JOIN ai.review_insights t ON t.review_id = r.review_id
  WHERE r.comment_text IS NOT NULL
    AND t.review_id IS NULL
  ORDER BY r.review_id
) u
-- md5 ordering = a repeatable "random" sample (same rows every run)
ORDER BY md5(review_id)
LIMIT :sample;

\copy ai._to_tag TO 'data/work/reviews_to_tag.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
SELECT count(*) AS reviews_exported FROM ai._to_tag;
