-- =====================================================================
-- 13_import_exec_summary.sql  |  Store the LLM-written summary (one per month)
-- =====================================================================
CREATE TEMP TABLE _sum (period_month date, headline text, summary text,
  action_1 text, action_2 text, action_3 text, model text);
\copy _sum FROM 'data/work/exec_summary.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

INSERT INTO ai.exec_summary (period_month, headline, summary, action_1, action_2, action_3, model)
SELECT * FROM _sum
ON CONFLICT (period_month) DO UPDATE SET headline = EXCLUDED.headline, summary = EXCLUDED.summary,
  action_1 = EXCLUDED.action_1, action_2 = EXCLUDED.action_2, action_3 = EXCLUDED.action_3,
  model = EXCLUDED.model, created_at = now();

SELECT period_month, headline FROM ai.exec_summary ORDER BY period_month DESC LIMIT 3;
