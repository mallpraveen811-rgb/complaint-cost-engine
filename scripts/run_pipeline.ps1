# =====================================================================
# run_pipeline.ps1  |  Windows version of the full pipeline
# Open PowerShell in the project folder and run, for example:
#   .\scripts\run_pipeline.ps1                         # everything, LLM tags 10,000 reviews
#   .\scripts\run_pipeline.ps1 -Sample 300             # small first test (uses ~8 API calls)
#   .\scripts\run_pipeline.ps1 -Mode baseline          # no API key needed (keyword rules)
#   .\scripts\run_pipeline.ps1 -Stage tag              # only re-run the tagging step
# If PowerShell blocks the script once:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# =====================================================================
param(
  [string]$Db = "complaint_cost",
  [string]$PgUser = "postgres",
  [int]$Sample = 10000,
  [ValidateSet("llm", "baseline")][string]$Mode = "llm",
  [ValidateSet("all", "sql", "tag", "finish")][string]$Stage = "all"
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force -Path "data\work" | Out-Null

# find psql even if PostgreSQL's bin folder is not on PATH
$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) {
  $psql = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
          Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $psql) { throw "psql not found. Install PostgreSQL or add its bin folder to PATH." }
if (-not $env:PGPASSWORD) {
  $sec = Read-Host "PostgreSQL password for user $PgUser" -AsSecureString
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$env:PGOPTIONS = "-c client_min_messages=warning"
$env:PGCLIENTENCODING = "UTF8"

function Run-Sql([string]$file, [string[]]$extra = @()) {
  & $psql -U $PgUser -d $Db -v ON_ERROR_STOP=1 -q @extra -f $file
  if ($LASTEXITCODE -ne 0) { throw "SQL failed: $file" }
}
function Run-Py([string[]]$args_) {
  & python @args_
  if ($LASTEXITCODE -ne 0) { throw "Python failed: $($args_ -join ' ')" }
}

if ($Stage -in "all", "sql") {
  $exists = & $psql -U $PgUser -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$Db'"
  if ($exists -ne "1") { & $psql -U $PgUser -d postgres -q -c "CREATE DATABASE $Db" }
  Write-Host "[1/6] Build warehouse (raw -> staging -> star schema)" -ForegroundColor Cyan
  foreach ($f in "00_setup", "01_raw_tables", "02_load_raw", "03_staging", "04_star_schema", "05_ai_tables",
                 "06_analysis_views", "07_powerbi_views") { Run-Sql "sql\$f.sql" | Out-Null }
  Write-Host "[2/6] Data quality checks" -ForegroundColor Cyan
  Run-Sql "sql\08_data_quality_checks.sql"
  Write-Host "[3/6] Export reviews for the LLM (sample=$Sample)" -ForegroundColor Cyan
  Run-Sql "sql\09_export_reviews_for_ai.sql" @("-v", "sample=$Sample")
}
if ($Stage -in "all", "tag") {
  Write-Host "[4/6] Tag reviews (mode=$Mode)" -ForegroundColor Cyan
  Run-Py @("genai\tag_reviews.py", "--mode", $Mode)
}
if ($Stage -in "all", "finish") {
  Write-Host "[5/6] Load AI results and rebuild analysis views" -ForegroundColor Cyan
  Run-Sql "sql\10_import_ai_results.sql"
  Run-Sql "sql\06_analysis_views.sql"; Run-Sql "sql\07_powerbi_views.sql"
  Write-Host "[6/6] Executive summary" -ForegroundColor Cyan
  Run-Sql "sql\12_export_kpi_snapshot.sql"
  if ($Mode -eq "llm") { Run-Py @("genai\exec_summary.py") } else { Run-Py @("genai\exec_summary.py", "--mode", "template") }
  Run-Sql "sql\13_import_exec_summary.sql"
  Write-Host "`nDone. Open Power BI Desktop and press Refresh." -ForegroundColor Green
}
