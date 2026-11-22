-- =====================================================================
-- 05_ai_tables.sql  |  Tables that hold GenAI output + the export for tagging
-- These tables are NOT dropped on re-run: LLM tags cost time/quota,
-- so we keep them and only send reviews that are not tagged yet.
-- =====================================================================

-- the fixed list of labels the LLM is allowed to use (a "controlled vocabulary")
CREATE TABLE IF NOT EXISTS ai.complaint_categories (
  category      text PRIMARY KEY,
  display_name  text NOT NULL,
  is_complaint  boolean NOT NULL,
  owner_team    text NOT NULL,      -- who should fix it: turns insight into action
  description   text NOT NULL
);
INSERT INTO ai.complaint_categories VALUES
 ('late_delivery',        'Late delivery',          true,  'Logistics',        'Arrived after the promised date'),
 ('not_delivered',        'Not delivered',          true,  'Logistics',        'Never arrived or marked delivered but not received'),
 ('damaged_item',         'Damaged / defective',    true,  'Seller packaging', 'Broken, damaged in transit, or defective on arrival'),
 ('wrong_item',           'Wrong item',             true,  'Seller fulfilment','Different product, colour, size or model than ordered'),
 ('missing_parts',        'Missing items / parts',  true,  'Seller fulfilment','Incomplete order, part of the order missing'),
 ('poor_quality',         'Poor quality',           true,  'Category / sourcing','Works but quality is low, breaks soon'),
 ('not_as_described',     'Not as described',       true,  'Catalogue',        'Listing photos/description do not match the product'),
 ('seller_communication', 'Seller unresponsive',    true,  'Seller support',   'Seller does not answer or support is poor'),
 ('refund_return_issue',  'Refund / return issue',  true,  'Customer service', 'Problems with cancellation, return or refund'),
 ('price_value',          'Price / freight value',  true,  'Pricing',          'Too expensive, freight too high for the value'),
 ('positive_feedback',    'Positive feedback',      false, '-',                'Happy customer, no complaint'),
 ('other',                'Other',                  false, '-',                'Anything that does not fit the list')
ON CONFLICT (category) DO UPDATE
  SET display_name = EXCLUDED.display_name, is_complaint = EXCLUDED.is_complaint,
      owner_team = EXCLUDED.owner_team, description = EXCLUDED.description;

-- one row per tagged review ----------------------------------------------------
CREATE TABLE IF NOT EXISTS ai.review_insights (
  review_id          text PRIMARY KEY,
  sentiment          text CHECK (sentiment IN ('positive','neutral','negative')),
  primary_category   text REFERENCES ai.complaint_categories(category),
  secondary_category text REFERENCES ai.complaint_categories(category),
  severity           text CHECK (severity IN ('none','low','medium','high')),
  wont_buy_again     boolean,          -- customer says they will not buy again
  summary_en         text,             -- one-line English summary (reviews are Portuguese)
  method             text,             -- 'llm' or 'keyword_baseline'
  model              text,
  tagged_at          timestamp DEFAULT now()
);

-- manual labels for measuring LLM accuracy ---------------------------------------
CREATE TABLE IF NOT EXISTS ai.validation_labels (
  review_id        text PRIMARY KEY,
  manual_category  text REFERENCES ai.complaint_categories(category),
  manual_sentiment text,
  labelled_by      text,
  labelled_at      timestamp DEFAULT now()
);

-- monthly executive summaries written by the LLM ------------------------------------
CREATE TABLE IF NOT EXISTS ai.exec_summary (
  period_month  date PRIMARY KEY,
  headline      text,
  summary       text,
  action_1      text,
  action_2      text,
  action_3      text,
  model         text,
  created_at    timestamp DEFAULT now()
);
