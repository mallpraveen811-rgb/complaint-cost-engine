# Complaint Cost Engine
*by Aarsh Mall*

**Live dashboard:** https://claude.ai/artifact/8Aigg5dmh2LewG3iXuuijX  
**Full report:** [docs/Complaint_Cost_Engine_Report.pdf](docs/Complaint_Cost_Engine_Report.pdf)

### Which customer problems cost an e-commerce business the most money?

**SQL (PostgreSQL) · GenAI (Gemini LLM) · Power BI · Python**

Online marketplaces collect thousands of written reviews, but most teams only look at the star rating.
This project uses an LLM to turn ~40,000 Portuguese reviews into structured complaint data, joins that
data with orders, sellers and deliveries in a SQL star schema, and ranks every type of complaint by the
**revenue it puts at risk**. The result is a Power BI dashboard that tells operations *what to fix first*
and *which team owns it*.

> Typical review projects stop at "62% positive". This one answers: *"Late delivery puts R$ X at risk,
> mostly in the North region; damaged items are concentrated in 12 sellers; fix logistics first."*

---

## Architecture

```
 Kaggle CSVs ──► PostgreSQL                         Python + Gemini              PostgreSQL            Power BI
 (9 files)       raw ─► stg ─► dw (star schema) ──► tag_reviews.py ──────────►   ai.review_insights ─► mart.* ─► pbi.* ─► 5-page report
                         (clean, type, dedupe)      (Portuguese text → JSON)     (joined to orders)     (analysis)  (views)   + AI summary
                                                    exec_summary.py  ◄── KPI snapshot JSON ──┘
```

| Layer | What it does | Files |
|---|---|---|
| raw | exact copy of the CSVs (all text, never fails to load) | `sql/01`, `sql/02` |
| stg | cleaning: types, NULLs, trimming, one review per order | `sql/03` |
| dw | star schema: `fact_orders`, `fact_order_items`, 5 dimensions | `sql/04` |
| ai | LLM output: review tags, exec summaries, manual labels | `sql/05`, `genai/*.py` |
| mart | business questions as SQL views (window functions, ranking) | `sql/06` |
| pbi | clean views Power BI connects to | `sql/07` |

## Folder structure
```
complaint-cost-engine/
├── data/raw/            ← put the 9 Kaggle CSV files here
├── data/work/           ← files passed between SQL and Python (created automatically)
├── sql/                 ← 00–13 run in order (+ 99 reset)
├── genai/               ← LLM tagging, validation, executive summary
├── powerbi/             ← DAX measures, theme, click-by-click build guide
├── scripts/             ← one-command pipeline (Windows .ps1, Mac/Linux .sh)
├── tests/               ← synthetic sample generator + offline mock of the LLM
└── docs/                ← project guide PDF
```

---

## Setup (Windows)

1. **Install** (all free): [PostgreSQL](https://www.postgresql.org/download/windows/) (remember the password),
   [Python 3.11+](https://www.python.org/downloads/) (tick *Add to PATH*), and
   [Power BI Desktop](https://powerbi.microsoft.com/desktop/).
2. **Dataset**: download *Brazilian E-Commerce Public Dataset by Olist* from Kaggle. Unzip the 9 CSVs into `data\raw\`.
3. **Python packages**: `pip install -r requirements.txt`
4. **API key**: copy `.env.example` to `.env` and paste a free key from Google AI Studio.
   Check your free-tier limits there and set `GEMINI_RPM` below them.
5. **First, a small test run** (about 8 API calls):
   ```powershell
   .\scripts\run_pipeline.ps1 -Sample 300
   ```
6. **The real run** (10,000 reviews, about 250 API calls at 40 reviews per call):
   ```powershell
   .\scripts\run_pipeline.ps1 -Sample 10000
   ```
   If it stops on a quota limit, run `.\scripts\run_pipeline.ps1 -Stage tag` later. It resumes where it stopped.
   Then run `-Stage finish`.
7. **Validate the AI** (see below), then **build the dashboard** with `powerbi/dashboard_build_guide.md`.

No API key? Run `-Mode baseline` to try everything with keyword rules first.
Before the real LLM run, clear those tags with `psql -U postgres -d complaint_cost -f sql\99_reset_ai_tags.sql`.

## Measuring the LLM's accuracy (do not skip this)
```powershell
python genai\build_validation_sample.py --n 200     # blind sheet: data\work\validation_to_label.csv
#   open it in Excel and fill manual_category for each review (about 1 hour)
python genai\tag_reviews.py --mode baseline --input data\work\reviews_to_tag.csv --output data\work\review_insights_baseline.csv
python genai\validate_tags.py --baseline data\work\review_insights_baseline.csv
psql -U postgres -d complaint_cost -f sql\11_import_validation.sql
```
`data/work/validation_report.md` reports accuracy, per-category precision/recall, a confusion table,
and **LLM vs keyword rules**, which shows why an LLM is worth using here.

Allowed labels: `late_delivery, not_delivered, damaged_item, wrong_item, missing_parts, poor_quality,
not_as_described, seller_communication, refund_return_issue, price_value, positive_feedback, other`

---

## Key definitions
- **Complaint order**: the LLM tagged the order's review with a complaint category.
- **Exposed revenue**: total value of complaint orders.
- **Revenue at risk**: value of complaint orders where the customer says they won't buy again **or** the LLM rated the problem *high* severity.
- **Coverage factor**: written reviews ÷ tagged reviews. Used to scale a 10k sample up to all ~40k written reviews.

## Results (real Olist data; LLM tags on a random sample of 1,196 written reviews)
| Question | Answer |
|---|---|
| #1 complaint by revenue at risk | Not delivered: ≈ R$ 390,222 (est. for all 40,766 written reviews) |
| #2 and #3 | Missing items / parts ≈ R$ 344,452 · Late delivery ≈ R$ 279,240 |
| Avg review score: 7+ days early vs 15+ days late | 4.32 vs 1.71 (78.7% of the late ones get 1–2 stars) |
| Missing-items complaints on multi-item orders | 68.5% vs 9.9% of all orders (split shipments) |
| Seller next-month sales change: <10% vs 25%+ bad-review months | −5.2% vs −13.5% |
| AI "late delivery" tags that were really late/undelivered | 60.6% (all orders: 8.4%) |
| Keyword rules agreeing with the AI | 45.5% (they call 25.2% of happy reviews "late") |

The results above were produced with Claude as the LLM; the scripts call Gemini through its API, and any LLM with JSON output works.
The real-run outputs are in `results/` (tags, English summaries, KPI snapshot, executive summary), the dashboard's
data and the SQL behind each number are in `dashboard/data/`, and the full write-up is
`docs/Complaint_Cost_Engine_End_to_End_Report.pdf`. To reload the tags into a fresh database: copy
`results/review_insights.csv` to `data/work/` and run `sql/10_import_ai_results.sql`, then `sql/06` and `sql/07`.

## Limitations
- Revenue at risk is a **proxy**, not a measured loss. The seller-level "next month" analysis gives supporting evidence, not proof of cause.
- Only ~40% of orders have written reviews, and people who write reviews skew negative.
- Most Olist customers buy only once, so customer-level retention is weak. That's why the impact is measured at seller level.
- LLM tags carry errors. That's why accuracy is measured and published.

## Testing without the real data
```bash
python tests/make_sample_data.py           # synthetic Olist-shaped CSVs in data/raw (TEST ONLY)
MODE=baseline bash scripts/run_pipeline.sh
python tests/mock_gemini_run.py             # exercises the LLM code path with a fake API
```
