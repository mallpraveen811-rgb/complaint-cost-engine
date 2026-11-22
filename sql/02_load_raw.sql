-- =====================================================================
-- 02_load_raw.sql  |  Bulk-load the Kaggle CSVs with psql's \copy
-- Run from the PROJECT ROOT folder (paths are relative):
--   psql -U postgres -d complaint_cost -f sql/02_load_raw.sql
-- \copy runs on your machine (client side), so no server file access is needed.
-- ENCODING 'UTF8' matters on Windows: Portuguese accents (ã, ç, é) load correctly.
-- =====================================================================
TRUNCATE raw.customers, raw.orders, raw.order_items, raw.order_payments,
  raw.order_reviews, raw.products, raw.sellers, raw.category_translation;

\copy raw.customers            FROM 'data/raw/olist_customers_dataset.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.orders               FROM 'data/raw/olist_orders_dataset.csv'           WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.order_items          FROM 'data/raw/olist_order_items_dataset.csv'      WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.order_payments       FROM 'data/raw/olist_order_payments_dataset.csv'   WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.order_reviews        FROM 'data/raw/olist_order_reviews_dataset.csv'    WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.products             FROM 'data/raw/olist_products_dataset.csv'         WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.sellers              FROM 'data/raw/olist_sellers_dataset.csv'          WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.category_translation FROM 'data/raw/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- quick sanity check: row counts per table
SELECT 'customers' AS tbl, count(*) FROM raw.customers UNION ALL
SELECT 'orders', count(*) FROM raw.orders UNION ALL
SELECT 'order_items', count(*) FROM raw.order_items UNION ALL
SELECT 'order_payments', count(*) FROM raw.order_payments UNION ALL
SELECT 'order_reviews', count(*) FROM raw.order_reviews UNION ALL
SELECT 'products', count(*) FROM raw.products UNION ALL
SELECT 'sellers', count(*) FROM raw.sellers UNION ALL
SELECT 'category_translation', count(*) FROM raw.category_translation;
