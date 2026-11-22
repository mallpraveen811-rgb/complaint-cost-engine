-- =====================================================================
-- 08_data_quality_checks.sql  |  Tests for the data, written in SQL
-- Every row should show status = 'PASS'. A 'WARN' row is something to
-- look at and mention in the README, not necessarily an error.
-- =====================================================================
WITH checks AS (
  SELECT 'orders have a customer' AS check_name,
         (SELECT count(*) FROM stg.orders o LEFT JOIN stg.customers c USING (customer_id)
          WHERE c.customer_id IS NULL) AS bad_rows, 'FAIL' AS level
  UNION ALL
  SELECT 'order items point to a known product',
         (SELECT count(*) FROM stg.order_items i LEFT JOIN stg.products p USING (product_id)
          WHERE p.product_id IS NULL), 'FAIL'
  UNION ALL
  SELECT 'order items point to a known seller',
         (SELECT count(*) FROM stg.order_items i LEFT JOIN stg.sellers s USING (seller_id)
          WHERE s.seller_id IS NULL), 'FAIL'
  UNION ALL
  SELECT 'review scores are between 1 and 5',
         (SELECT count(*) FROM stg.reviews WHERE review_score NOT BETWEEN 1 AND 5), 'FAIL'
  UNION ALL
  SELECT 'no negative prices or freight',
         (SELECT count(*) FROM stg.order_items WHERE price < 0 OR freight_value < 0), 'FAIL'
  UNION ALL
  SELECT 'delivered orders have a delivery date',
         (SELECT count(*) FROM stg.orders WHERE order_status = 'delivered' AND delivered_at IS NULL), 'WARN'
  UNION ALL
  SELECT 'delivery date is not before purchase date',
         (SELECT count(*) FROM stg.orders WHERE delivered_at < purchased_at), 'WARN'
  UNION ALL
  SELECT 'orders with no items (canceled/unavailable)',
         (SELECT count(*) FROM dw.fact_orders WHERE item_count = 0), 'WARN'
  UNION ALL
  SELECT 'payment total differs from items+freight by > 1',
         (SELECT count(*) FROM dw.fact_orders WHERE abs(payment_value - order_value) > 1), 'WARN'
  UNION ALL
  SELECT 'raw reviews dropped as duplicates (kept 1 per order)',
         (SELECT (SELECT count(*) FROM raw.order_reviews) - (SELECT count(*) FROM stg.reviews)), 'WARN'
  UNION ALL
  SELECT 'AI tags use only allowed categories',
         (SELECT count(*) FROM ai.review_insights t LEFT JOIN ai.complaint_categories c
            ON c.category = t.primary_category WHERE c.category IS NULL), 'FAIL'
)
SELECT check_name, bad_rows,
       CASE WHEN bad_rows = 0 THEN 'PASS' ELSE level END AS status
FROM checks;
