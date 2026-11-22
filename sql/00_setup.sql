-- =====================================================================
-- 00_setup.sql  |  Create the schemas (layers) of the warehouse
-- Run:  psql -U postgres -d complaint_cost -f sql/00_setup.sql
-- =====================================================================
-- raw   : exact copy of the Kaggle CSVs, every column stored as TEXT
-- stg   : cleaned, typed, de-duplicated tables
-- dw    : star schema (facts + dimensions) used for analysis
-- ai    : everything produced by the LLM (review tags, summaries, labels)
-- mart  : business analysis views (answers to business questions)
-- pbi   : thin views shaped exactly for Power BI import
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dw;
CREATE SCHEMA IF NOT EXISTS ai;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS pbi;
