-- =====================================================================
-- 03_staging.sql  |  Clean + type the raw data
-- Cleaning rules:
--   1. Empty strings become NULL (NULLIF(x, '')).
--   2. Text dates -> timestamp, numbers -> numeric/int.
--   3. Text is trimmed; city names lower-cased; states upper-cased.
--   4. Reviews: the real file has duplicate review_ids and some orders with
--      more than one review. We keep ONE review per order: the latest answered.
--   5. Products with no category -> 'unknown'; categories missing from the
--      translation file keep their Portuguese name instead of becoming NULL.
-- =====================================================================
DROP TABLE IF EXISTS stg.customers, stg.orders, stg.order_items, stg.payments_by_order,
  stg.reviews, stg.products, stg.sellers CASCADE;

-- customers --------------------------------------------------------------
CREATE TABLE stg.customers AS
SELECT DISTINCT ON (customer_id)
  trim(customer_id)                      AS customer_id,        -- one per ORDER in Olist
  trim(customer_unique_id)               AS customer_unique_id, -- the real person
  NULLIF(trim(customer_zip_code_prefix), '') AS zip_prefix,
  lower(trim(customer_city))             AS city,
  upper(trim(customer_state))            AS state
FROM raw.customers
WHERE NULLIF(trim(customer_id), '') IS NOT NULL
ORDER BY customer_id;
ALTER TABLE stg.customers ADD PRIMARY KEY (customer_id);

-- orders ------------------------------------------------------------------
CREATE TABLE stg.orders AS
SELECT DISTINCT ON (order_id)
  trim(order_id)                                       AS order_id,
  trim(customer_id)                                    AS customer_id,
  lower(trim(order_status))                            AS order_status,
  NULLIF(order_purchase_timestamp, '')::timestamp      AS purchased_at,
  NULLIF(order_approved_at, '')::timestamp             AS approved_at,
  NULLIF(order_delivered_carrier_date, '')::timestamp  AS shipped_at,
  NULLIF(order_delivered_customer_date, '')::timestamp AS delivered_at,
  NULLIF(order_estimated_delivery_date, '')::timestamp AS estimated_delivery_at
FROM raw.orders
WHERE NULLIF(trim(order_id), '') IS NOT NULL
ORDER BY order_id;
ALTER TABLE stg.orders ADD PRIMARY KEY (order_id);

-- order items ---------------------------------------------------------------
CREATE TABLE stg.order_items AS
SELECT
  trim(order_id)                   AS order_id,
  order_item_id::int               AS order_item_id,
  trim(product_id)                 AS product_id,
  trim(seller_id)                  AS seller_id,
  NULLIF(shipping_limit_date, '')::timestamp AS shipping_limit_at,
  price::numeric(12,2)             AS price,
  freight_value::numeric(12,2)     AS freight_value
FROM raw.order_items;
ALTER TABLE stg.order_items ADD PRIMARY KEY (order_id, order_item_id);

-- payments: an order can be paid in several parts -> roll up to one row per order
CREATE TABLE stg.payments_by_order AS
SELECT
  trim(order_id)                                   AS order_id,
  sum(payment_value::numeric(12,2))                AS payment_value,
  max(payment_installments::int)                   AS max_installments,
  -- the payment type that covered the largest share of the order
  (array_agg(payment_type ORDER BY payment_value::numeric DESC))[1] AS main_payment_type,
  count(*)                                         AS payment_parts
FROM raw.order_payments
GROUP BY trim(order_id);
ALTER TABLE stg.payments_by_order ADD PRIMARY KEY (order_id);

-- reviews: one per order (latest answer wins) -------------------------------
CREATE TABLE stg.reviews AS
SELECT DISTINCT ON (order_id)
  trim(review_id)                                   AS review_id,
  trim(order_id)                                    AS order_id,
  review_score::int                                 AS review_score,
  NULLIF(trim(review_comment_title), '')            AS comment_title,
  NULLIF(regexp_replace(trim(review_comment_message), '\s+', ' ', 'g'), '') AS comment_text,
  NULLIF(review_creation_date, '')::timestamp       AS created_at,
  NULLIF(review_answer_timestamp, '')::timestamp    AS answered_at
FROM raw.order_reviews
WHERE NULLIF(trim(order_id), '') IS NOT NULL
ORDER BY order_id, NULLIF(review_answer_timestamp, '')::timestamp DESC NULLS LAST;
ALTER TABLE stg.reviews ADD PRIMARY KEY (order_id);
CREATE INDEX ON stg.reviews (review_id);

-- products -----------------------------------------------------------------
CREATE TABLE stg.products AS
SELECT DISTINCT ON (p.product_id)
  trim(p.product_id)                                                    AS product_id,
  COALESCE(NULLIF(trim(p.product_category_name), ''), 'unknown')        AS category_pt,
  COALESCE(NULLIF(trim(t.product_category_name_english), ''),
           NULLIF(trim(p.product_category_name), ''), 'unknown')        AS category,
  NULLIF(p.product_photos_qty, '')::int                                 AS photos_qty,
  NULLIF(p.product_weight_g, '')::numeric                               AS weight_g,
  NULLIF(p.product_length_cm, '')::numeric * NULLIF(p.product_height_cm, '')::numeric
    * NULLIF(p.product_width_cm, '')::numeric                           AS volume_cm3
FROM raw.products p
LEFT JOIN raw.category_translation t
       ON trim(t.product_category_name) = trim(p.product_category_name)
ORDER BY p.product_id;
ALTER TABLE stg.products ADD PRIMARY KEY (product_id);

-- sellers ------------------------------------------------------------------
CREATE TABLE stg.sellers AS
SELECT DISTINCT ON (seller_id)
  trim(seller_id)                 AS seller_id,
  NULLIF(trim(seller_zip_code_prefix), '') AS zip_prefix,
  lower(trim(seller_city))        AS city,
  upper(trim(seller_state))       AS state
FROM raw.sellers
ORDER BY seller_id;
ALTER TABLE stg.sellers ADD PRIMARY KEY (seller_id);
