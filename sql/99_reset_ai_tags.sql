-- =====================================================================
-- 99_reset_ai_tags.sql  |  Delete AI tags (e.g. after a baseline/test run,
-- before the real LLM run). Your manual validation labels are kept.
-- =====================================================================
TRUNCATE ai.review_insights, ai.exec_summary;
SELECT 'AI tags cleared' AS status;
