-- =====================================================================
-- 04_star_schema.sql  |  Dimensional model (star schema)
--
--                 dim_date
--                    |
--   dim_customer - fact_orders - fact_reviews ... ai.review_insights
--                    |
--   dim_product - fact_order_items - dim_seller
--
-- Grain (what one row means) is the most important decision in a star schema:
--   fact_orders      : one row per order
--   fact_order_items : one row per item inside an order
-- =====================================================================
DROP TABLE IF EXISTS dw.dim_state, dw.dim_date, dw.dim_customer, dw.dim_seller, dw.dim_product,
  dw.fact_orders, dw.fact_order_items CASCADE;

-- date dimension -------------------------------------------------------------
CREATE TABLE dw.dim_date AS
SELECT d::date                         AS date_key,
       extract(year FROM d)::int       AS year,
       extract(quarter FROM d)::int    AS quarter,
       extract(month FROM d)::int      AS month,
       to_char(d, 'Mon YYYY')          AS month_label,
       date_trunc('month', d)::date    AS month_start,
       extract(isodow FROM d)::int     AS weekday_no,
       to_char(d, 'Dy')                AS weekday_name,
       (extract(isodow FROM d) >= 6)   AS is_weekend
FROM generate_series(
       (SELECT date_trunc('year', min(purchased_at)) FROM stg.orders),
       (SELECT date_trunc('year', max(purchased_at)) + interval '1 year - 1 day' FROM stg.orders),
       interval '1 day') AS d;
ALTER TABLE dw.dim_date ADD PRIMARY KEY (date_key);

-- Brazilian states (UF code -> name) so Power BI maps can place them correctly.
-- ("PA" alone would be Pennsylvania; "Pará, Brazil" is unambiguous.)
CREATE TABLE dw.dim_state (state text PRIMARY KEY, state_name text, region text);
INSERT INTO dw.dim_state VALUES
 ('AC','Acre','North'),('AL','Alagoas','Northeast'),('AP','Amapá','North'),('AM','Amazonas','North'),
 ('BA','Bahia','Northeast'),('CE','Ceará','Northeast'),('DF','Distrito Federal','Center-West'),
 ('ES','Espírito Santo','Southeast'),('GO','Goiás','Center-West'),('MA','Maranhão','Northeast'),
 ('MT','Mato Grosso','Center-West'),('MS','Mato Grosso do Sul','Center-West'),('MG','Minas Gerais','Southeast'),
 ('PA','Pará','North'),('PB','Paraíba','Northeast'),('PR','Paraná','South'),('PE','Pernambuco','Northeast'),
 ('PI','Piauí','Northeast'),('RJ','Rio de Janeiro','Southeast'),('RN','Rio Grande do Norte','Northeast'),
 ('RS','Rio Grande do Sul','South'),('RO','Rondônia','North'),('RR','Roraima','North'),
 ('SC','Santa Catarina','South'),('SP','São Paulo','Southeast'),('SE','Sergipe','Northeast'),
 ('TO','Tocantins','North');

-- customer dimension: keyed on the PERSON (customer_unique_id) ---------------
CREATE TABLE dw.dim_customer AS
SELECT DISTINCT ON (customer_unique_id)
       customer_unique_id AS customer_key, city, state, zip_prefix
FROM stg.customers
ORDER BY customer_unique_id;
ALTER TABLE dw.dim_customer ADD PRIMARY KEY (customer_key);

CREATE TABLE dw.dim_seller AS
SELECT seller_id AS seller_key, city, state, zip_prefix FROM stg.sellers;
ALTER TABLE dw.dim_seller ADD PRIMARY KEY (seller_key);

CREATE TABLE dw.dim_product AS
SELECT product_id AS product_key, category, category_pt, photos_qty, weight_g, volume_cm3
FROM stg.products;
ALTER TABLE dw.dim_product ADD PRIMARY KEY (product_key);

-- fact_orders: one row per order ---------------------------------------------
CREATE TABLE dw.fact_orders AS
WITH items AS (
  SELECT order_id,
         count(*)                         AS item_count,
         sum(price)                       AS items_value,
         sum(freight_value)               AS freight_value,
         count(DISTINCT seller_id)        AS seller_count,
         -- "main" seller = the one with the highest value in the order
         (array_agg(seller_id ORDER BY price DESC))[1]  AS main_seller_key,
         (array_agg(product_id ORDER BY price DESC))[1] AS main_product_key
  FROM stg.order_items GROUP BY order_id
)
SELECT o.order_id,
       c.customer_unique_id                       AS customer_key,
       i.main_seller_key                          AS seller_key,
       i.main_product_key                         AS product_key,
       o.purchased_at::date                       AS order_date,
       o.purchased_at,
       o.order_status,
       COALESCE(i.item_count, 0)                  AS item_count,
       COALESCE(i.items_value, 0)                 AS items_value,
       COALESCE(i.freight_value, 0)               AS freight_value,
       COALESCE(i.items_value, 0) + COALESCE(i.freight_value, 0) AS order_value,
       p.payment_value,
       p.main_payment_type,
       p.max_installments,
       i.seller_count,
       -- delivery metrics (NULL when not delivered)
       round(extract(epoch FROM (o.delivered_at - o.purchased_at)) / 86400.0, 1)          AS delivery_days,
       round(extract(epoch FROM (o.delivered_at - o.estimated_delivery_at)) / 86400.0, 1) AS delay_days,
       CASE WHEN o.delivered_at IS NULL THEN NULL
            ELSE o.delivered_at::date > o.estimated_delivery_at::date END                 AS is_late,
       (o.order_status = 'delivered')             AS is_delivered,
       -- review (one per order after staging)
       r.review_id,
       r.review_score,
       (r.comment_text IS NOT NULL)               AS has_comment,
       -- first order of this person? (repeat-purchase analysis)
       row_number() OVER (PARTITION BY c.customer_unique_id ORDER BY o.purchased_at) AS customer_order_seq
FROM stg.orders o
JOIN stg.customers c          ON c.customer_id = o.customer_id
LEFT JOIN items i             ON i.order_id = o.order_id
LEFT JOIN stg.payments_by_order p ON p.order_id = o.order_id
LEFT JOIN stg.reviews r       ON r.order_id = o.order_id;
ALTER TABLE dw.fact_orders ADD PRIMARY KEY (order_id);
CREATE INDEX ON dw.fact_orders (seller_key);
CREATE INDEX ON dw.fact_orders (order_date);
CREATE INDEX ON dw.fact_orders (review_id);

-- fact_order_items: one row per item --------------------------------------------
CREATE TABLE dw.fact_order_items AS
SELECT i.order_id, i.order_item_id, i.product_id AS product_key, i.seller_id AS seller_key,
       o.purchased_at::date AS order_date, i.price, i.freight_value,
       i.price + i.freight_value AS item_value
FROM stg.order_items i
JOIN stg.orders o ON o.order_id = i.order_id;
ALTER TABLE dw.fact_order_items ADD PRIMARY KEY (order_id, order_item_id);
