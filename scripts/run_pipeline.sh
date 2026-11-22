#!/usr/bin/env bash
# =====================================================================
# run_pipeline.sh  |  Mac / Linux version of the full pipeline
# Usage (from the project root):
#   bash scripts/run_pipeline.sh                 # everything, LLM tagging of 10,000 reviews
#   SAMPLE=500 bash scripts/run_pipeline.sh      # smaller, faster test
#   MODE=baseline bash scripts/run_pipeline.sh   # no API key needed (keyword rules)
#   STAGE=sql | tag | finish                     # run only one part
# Connection: set PGHOST / PGUSER / PGPASSWORD / PGPORT as usual for psql.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${DB:-complaint_cost}"
SAMPLE="${SAMPLE:-10000}"
MODE="${MODE:-llm}"
STAGE="${STAGE:-all}"
PY="${PY:-python3}"
export PGOPTIONS='-c client_min_messages=warning'
PSQL="psql -v ON_ERROR_STOP=1 -q -d $DB"
mkdir -p data/work

if [[ "$STAGE" == "all" || "$STAGE" == "sql" ]]; then
  psql -q -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
    || psql -q -d postgres -c "CREATE DATABASE $DB"
  echo "[1/6] Build warehouse (raw -> staging -> star schema)"
  for f in 00_setup 01_raw_tables 02_load_raw 03_staging 04_star_schema 05_ai_tables; do
    $PSQL -f "sql/$f.sql" > /dev/null
  done
  $PSQL -f sql/06_analysis_views.sql && $PSQL -f sql/07_powerbi_views.sql
  echo "[2/6] Data quality checks"; $PSQL -f sql/08_data_quality_checks.sql
  echo "[3/6] Export reviews for the LLM (sample=$SAMPLE)"
  $PSQL -v sample="$SAMPLE" -f sql/09_export_reviews_for_ai.sql
fi

if [[ "$STAGE" == "all" || "$STAGE" == "tag" ]]; then
  echo "[4/6] Tag reviews (mode=$MODE)"
  $PY genai/tag_reviews.py --mode "$MODE"
fi

if [[ "$STAGE" == "all" || "$STAGE" == "finish" ]]; then
  echo "[5/6] Load AI results and rebuild analysis views"
  $PSQL -f sql/10_import_ai_results.sql
  $PSQL -f sql/06_analysis_views.sql && $PSQL -f sql/07_powerbi_views.sql
  echo "[6/6] Executive summary"
  $PSQL -f sql/12_export_kpi_snapshot.sql
  if [[ "$MODE" == "llm" ]]; then $PY genai/exec_summary.py; else $PY genai/exec_summary.py --mode template; fi
  $PSQL -f sql/13_import_exec_summary.sql
  echo; echo "Done. Open Power BI and refresh (or build it with powerbi/dashboard_build_guide.md)."
fi
