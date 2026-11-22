"""Run each dashboard query against PostgreSQL and save {rows, meta} JSON, where meta
carries the exact SQL that produced the rows (so every number on the dashboard can be traced)."""
import csv, io, json, re, subprocess, sys
from pathlib import Path

OUT = Path(__file__).parent / "data"
Q = {
"totals": """
SELECT (SELECT count(*) FROM dw.fact_orders) AS orders,
       (SELECT count(DISTINCT customer_key) FROM dw.fact_orders) AS customers,
       (SELECT count(*) FROM dw.dim_seller) AS sellers,
       (SELECT round(sum(order_value)) FROM dw.fact_orders) AS revenue_brl,
       (SELECT round(100.0*avg(is_late::int),1) FROM dw.fact_orders) AS late_pct,
       (SELECT round(avg(review_score),2) FROM dw.fact_orders) AS avg_review_score,
       (SELECT round(100.0*avg((n>1)::int),1) FROM (SELECT count(*) n FROM dw.fact_orders GROUP BY customer_key) x) AS repeat_customer_pct,
       c.reviews_with_text, (SELECT count(*) FROM ai.review_insights) AS reviews_tagged, c.coverage_factor,
       (SELECT min(order_date)::text FROM dw.fact_orders) AS first_order,
       (SELECT max(order_date)::text FROM dw.fact_orders) AS last_order
FROM mart.tagging_coverage c""",
"complaint_impact": """
SELECT i.display_name, i.owner_team, i.complaints, i.share_of_complaints_pct, i.exposed_revenue,
       i.revenue_at_risk, i.est_revenue_at_risk_full_data AS est_revenue_at_risk, i.avg_review_score,
       i.wont_buy_again_pct, i.high_severity_pct, i.late_pct, i.fix_priority_rank
FROM mart.complaint_category_impact i ORDER BY i.fix_priority_rank""",
"delivery_vs_review": """
SELECT delay_bucket, orders, avg_review_score, bad_review_pct
FROM mart.delivery_vs_review ORDER BY bucket_order""",
"seller_effect": """
SELECT bad_review_band, seller_months, avg_next_month_change_pct, median_next_month_change_pct
FROM mart.complaint_effect_on_sellers ORDER BY bad_review_band""",
"monthly": """
SELECT order_month::text AS month, orders, round(revenue) AS revenue_brl, late_pct, avg_review_score, bad_review_pct
FROM mart.kpi_monthly
WHERE order_month BETWEEN '2017-01-01' AND '2018-08-01' ORDER BY order_month""",
"missing_items": """
SELECT 'Orders with a missing-items complaint' AS order_group,
       round(100.0*avg((f.item_count>1)::int),1) AS multi_item_pct,
       round(100.0*avg((f.seller_count>1)::int),1) AS multi_seller_pct
FROM dw.fact_orders f JOIN ai.review_insights t ON t.review_id = f.review_id
WHERE t.primary_category = 'missing_parts'
UNION ALL
SELECT 'All orders with items', round(100.0*avg((item_count>1)::int),1), round(100.0*avg((seller_count>1)::int),1)
FROM dw.fact_orders WHERE item_count > 0""",
"states": """
SELECT s.customer_state AS state, st.state_name, st.region, s.orders, s.avg_delivery_days, s.late_pct, s.avg_review_score
FROM mart.state_summary s JOIN dw.dim_state st ON st.state = s.customer_state
ORDER BY s.late_pct DESC""",
"validation": """
WITH t AS (
  SELECT ti.primary_category, coalesce(f.is_late, true) AS late_or_missing
  FROM dw.fact_orders f JOIN ai.review_insights ti ON ti.review_id = f.review_id)
SELECT 'Reviews the AI tagged "Late delivery"' AS ai_tag, count(*) AS reviews,
       round(100.0*avg(late_or_missing::int),1) AS actually_late_or_undelivered_pct FROM t WHERE primary_category='late_delivery'
UNION ALL SELECT 'Reviews the AI tagged "Not delivered"', count(*), round(100.0*avg(late_or_missing::int),1) FROM t WHERE primary_category='not_delivered'
UNION ALL SELECT 'Reviews the AI tagged "Positive feedback"', count(*), round(100.0*avg(late_or_missing::int),1) FROM t WHERE primary_category='positive_feedback'
UNION ALL SELECT 'All orders (baseline)', count(*), round(100.0*avg(coalesce(is_late,true)::int),1) FROM dw.fact_orders WHERE order_status NOT IN ('canceled','unavailable')""",
"seller_watchlist": """
SELECT left(s.seller_key, 8) AS seller_id, s.seller_state, s.orders, round(s.revenue) AS revenue_brl, s.avg_review_score,
       s.late_pct, round(100.0*b.bad,1) AS bad_review_pct, s.health_status
FROM mart.seller_scorecard s
JOIN (SELECT seller_key, avg((review_score<=2)::int) bad FROM dw.fact_orders GROUP BY 1) b USING (seller_key)
WHERE s.orders >= 50 ORDER BY b.bad DESC LIMIT 12""",
"exec_summary": """
SELECT to_char(period_month,'Mon YYYY') AS period, headline, summary, action_1, action_2, action_3, model
FROM ai.exec_summary ORDER BY period_month DESC LIMIT 1""",
"review_examples": """
SELECT cc.display_name AS complaint, t.severity, r.review_score AS stars, t.summary_en AS summary_english,
       r.comment_text AS original_portuguese
FROM ai.review_insights t
JOIN (SELECT DISTINCT ON (review_id) review_id, review_score, comment_text FROM stg.reviews) r USING (review_id)
JOIN ai.complaint_categories cc ON cc.category = t.primary_category
WHERE t.summary_en <> '' ORDER BY cc.display_name, t.severity""",
"category_counts": """
SELECT cc.display_name AS ai_category, count(*) AS reviews, round(100.0*count(*)/sum(count(*)) OVER (),1) AS share_pct
FROM ai.review_insights t JOIN ai.complaint_categories cc ON cc.category = t.primary_category
GROUP BY 1 ORDER BY 2 DESC""",
}
EXTRA = {
"keyword_vs_ai": None,  # filled from python comparison below
}

def run(sql):
    out = subprocess.run(["psql", "-h", "/tmp", "-U", "postgres", "-d", "complaint_cost", "--csv", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    rows = list(csv.DictReader(io.StringIO(out)))
    for r in rows:
        for k, v in r.items():
            if v == "":
                r[k] = None
                continue
            if re.fullmatch(r"-?\d+", v):
                r[k] = int(v)
            elif re.fullmatch(r"-?\d+\.\d+", v):
                r[k] = float(v)
    return rows

for name, sql in Q.items():
    rows = run(sql)
    meta = [{"label": "SQL (PostgreSQL 16, database complaint_cost)", "value": sql.strip(), "type": "code", "lang": "sql"},
            {"label": "Input", "value": "Olist Brazilian E-Commerce dataset (Kaggle), 9 CSV files"}]
    (OUT / f"{name}.json").write_text(json.dumps({"rows": rows, "meta": meta}, ensure_ascii=False, indent=1))
    print(name, len(rows))

# keyword baseline vs AI comparison (python, on the same reviews)
import pandas as pd
W = Path(__file__).parent.parent / "data" / "work"
l = pd.read_csv(W / "review_insights.csv", dtype={"review_id": str})
b = pd.read_csv(W / "review_insights_baseline.csv", dtype={"review_id": str}).drop_duplicates("review_id")
m = l.merge(b[["review_id", "primary_category"]], on="review_id", suffixes=("_ai", "_kw"))
pos = m[m.primary_category_ai == "positive_feedback"]
rows = [
 {"measure": "Reviews compared", "ai": int(len(m)), "keyword_rules": int(len(m))},
 {"measure": "Same category as the AI (%)", "ai": 100.0, "keyword_rules": float(round((m.primary_category_ai == m.primary_category_kw).mean() * 100, 1))},
 {"measure": "Put in \"Other\" (%)", "ai": float(round((m.primary_category_ai == "other").mean() * 100, 1)), "keyword_rules": float(round((m.primary_category_kw == "other").mean() * 100, 1))},
 {"measure": "Happy reviews wrongly called \"Late delivery\" (%)", "ai": 0.0, "keyword_rules": float(round((pos.primary_category_kw == "late_delivery").mean() * 100, 1))},
]
code = Path(__file__).read_text()
(OUT / "keyword_vs_ai.json").write_text(json.dumps({"rows": rows, "meta": [
  {"label": "export_dashboard_data.py", "value": code, "type": "code", "lang": "python"},
  {"label": "Input", "value": "data/work/review_insights.csv (AI tags) and review_insights_baseline.csv (keyword rules)"}]}, ensure_ascii=False, indent=1))
print("keyword_vs_ai", rows)
