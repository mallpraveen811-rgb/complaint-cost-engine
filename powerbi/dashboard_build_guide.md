# Power BI build guide: Complaint Cost Engine

Step-by-step build of the report in **Power BI Desktop** (free, Windows).
Before you start, run the pipeline (`scripts\run_pipeline.ps1`) so the database has data.

---

## Step 1: Connect to PostgreSQL

1. Open Power BI Desktop and choose **Home → Get data → More… → PostgreSQL database**.
2. Enter Server `localhost` and Database `complaint_cost`. Keep **Import** selected and click OK.
3. Enter your credentials: **Database** tab → user `postgres` plus your password.
   - If you see an SSL/encryption error, click OK on the "connect without encryption" prompt. That's fine for a local database.
4. In the Navigator, tick **only the views whose names start with `pbi.`**:
   `fact_orders, dim_date, dim_customer, dim_seller, dim_product, dim_complaint_category, complaint_impact, seller_scorecard, kpi_monthly, delivery_vs_review, complaint_effect_on_sellers, repeat_purchase, category_complaint_matrix, review_examples, exec_summary, tagging_coverage, model_quality`
5. Click **Load**.

> Why connect only to `pbi.*` views? The SQL underneath can change without breaking the report, and Power BI never sees the messy raw tables.

## Step 2: Rename the tables (Model view, right-click → Rename)

| Imported name | Rename to |
|---|---|
| pbi fact_orders | **Orders** |
| pbi dim_date | **Date** |
| pbi dim_customer | **Customer** |
| pbi dim_seller | **Seller** |
| pbi dim_product | **Product** |
| pbi dim_complaint_category | **Complaint Category** |
| pbi exec_summary | **Exec Summary** |
| pbi tagging_coverage | **Tagging Coverage** |
| pbi model_quality | **Model Quality** |
| the others | drop the `pbi ` prefix |

## Step 3: Build the star schema (Model view)

Drag a column from one table onto another to create each relationship. All of them are **many-to-one, single direction**:

| From (many) | To (one) |
|---|---|
| Orders[order_date] | Date[date_key] |
| Orders[customer_key] | Customer[customer_key] |
| Orders[seller_key] | Seller[seller_key] |
| Orders[product_key] | Product[product_key] |
| Orders[complaint_category] | Complaint Category[complaint_category] |
| Seller Scorecard[seller_key] | Seller[seller_key] |
| Review Examples[seller_key] | Seller[seller_key] |

Then:
- Select the **Date** table → **Table tools → Mark as date table** → pick `date_key`. Time-intelligence DAX like `DATEADD` needs this.
- **Date[month_label]** → Column tools → **Sort by column** → `month_start`, so months sort in calendar order instead of alphabetically.
- **Delivery Vs Review[delay_bucket]** → Sort by column → `bucket_order`.
- Hide the key columns in the report view (right-click → Hide in report view). It keeps the field list clean.

## Step 4: Theme and measures

1. **View → Themes → Browse for themes** → pick `powerbi/theme.json`.
2. **Home → Enter data** → name it `_Measures` → Load. This gives your measures one home.
3. Select `_Measures`, then **New measure** for each measure in `powerbi/dax_measures.dax`. Paste one at a time.
4. Formatting: set `Total Revenue`, `Revenue at Risk`, `Exposed Revenue` and `Est Revenue at Risk (All Reviews)` to currency (R$) with 0 decimals. Set every measure ending in `%` to Percentage with 1 decimal.

---

## Step 5: Build the pages

Use a 16:9 canvas. Put a **slicer panel** on the left of every page: Date (between slider on `date_key`), Customer[region] and Product[product_category]. Then **View → Sync slicers** so the filters follow you from page to page.

### Page 1: Executive Overview ("What happened this month?")
| Visual | Fields |
|---|---|
| 6 **Card (new)** visuals in a row | Total Revenue, Order Count, Avg Order Value, Avg Review Score, Late %, Revenue at Risk |
| **Line and clustered column chart** | X: Date[month_start] · Columns: Total Revenue · Line: Revenue at Risk |
| **Text box with dynamic values** (or 3 Card visuals) | AI Summary Month, AI Headline, AI Summary, AI Actions (turn on word wrap) |
| **Card** (small, bottom) | LLM Accuracy Label |

Title the AI box "AI-generated summary (checked against the data)" so readers know where the text came from.

### Page 2: Complaint Cost ("Which problem costs the most?") ← the key page
| Visual | Fields |
|---|---|
| **Card** at the top | Page Title Complaints |
| **Clustered bar chart** | Y: Complaint Category[display_name] · X: Revenue at Risk · sort descending · filter: Complaint Category[is_complaint] = True |
| **Table** | Complaint Impact: display_name, owner_team, complaints, share_of_complaints_pct, revenue_at_risk, avg_review_score, wont_buy_again_pct, fix_priority_rank. Add data bars on revenue_at_risk. |
| **Matrix (heat map)** | Rows: Category Complaint Matrix[product_category] · Columns: complaint_category · Values: complaints → Conditional formatting → Background color (white→red) |
| **Card** | Est Revenue at Risk (All Reviews), subtitle "scaled from the tagged sample" |

### Page 3: Delivery & Reviews ("Is logistics the root cause?")
| Visual | Fields |
|---|---|
| **Clustered column chart** | X: Delivery Vs Review[delay_bucket] · Y: avg_review_score (Sum). A sharp drop after "on time" is the story. |
| **Line chart** | X: Delivery Vs Review[delay_bucket] · Y: bad_review_pct |
| **Filled map** or **Map** | Location: Customer[map_location] · Color/size: Late % |
| **Table** | Customer[state_name], Avg Delivery Days, Late %, Avg Review Score, Revenue at Risk |

### Page 4: Seller Scorecard ("Who needs help, and with what?")
| Visual | Fields |
|---|---|
| **Slicer** (tiles) | Seller Scorecard[health_status] |
| **Table** | Seller Scorecard: risk_rank, seller_key, seller_state, orders, revenue, avg_review_score, late_pct, complaint_share_pct, top_complaint_name, top_complaint_owner, revenue_at_risk. Conditional formatting: avg_review_score (red < 3.5, green ≥ 4.2), late_pct (red > 25). |
| **Clustered column chart** | Complaint Effect On Sellers: X bad_review_band · Y avg_next_month_change_pct. This is the evidence that complaints hurt sales. |
| **Donut** | Legend: health_status · Values: count of seller_key |

### Page 5: Review Explorer (drill-through page)
1. In the **Drill through** well, add Seller[seller_key] and Complaint Category[display_name].
2. Add a **Table** from Review Examples: order_date, complaint_category, severity, review_score, summary_en, original_text_pt.

Now right-clicking any seller or complaint on the other pages → **Drill through → Review Explorer** shows the real customer words behind the number.

---

## Step 6: Finishing touches
- Add a small text box on every page explaining the definitions: *Revenue at risk = value of complaint orders where the customer says they won't buy again or the problem is high-severity.*
- Turn on **tooltips**: on the bar chart in Page 2, add Wont Buy Again % and High Severity % to the Tooltips well.
- **Bookmarks + buttons**: add a "Reset filters" button (Insert → Buttons → Reset, action = bookmark of the clean state).
- Save as `ComplaintCostEngine.pbix` and export **File → Export → PDF** for a static copy.

## Refreshing after new data
Re-run `.\scripts\run_pipeline.ps1 -Stage finish` (or the full pipeline), then click **Home → Refresh** in Power BI.
