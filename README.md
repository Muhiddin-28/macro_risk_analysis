# Macro Risk Analysis — SQL + PostgreSQL

> 76 years of U.S. macroeconomic data. 305 quarters. 18 SQL queries. Real answers to real questions.

This project downloads data from the Federal Reserve (FRED API), stores it in PostgreSQL, and answers 18 specific questions about U.S. economic risk using only SQL — no Python ML, no notebooks, no guesswork.

---

## What this project actually does

Every query was written to answer one specific question. The answers came from the data, not assumptions. Some confirmed textbook economics. Some contradicted it entirely.

---

## Project overview

| Item | Detail |
|---|---|
| Data source | FRED API — Federal Reserve Bank of St. Louis |
| Database | PostgreSQL 15+ |
| Period | 1950 Q1 — 2026 Q1 (305 quarters, 76 years) |
| Indicators | GDP growth · CPI inflation · Unemployment · Fed Funds Rate |
| Queries | 18 SQL queries across 6 modules |
| Automation | Python (psycopg2 + pandas) for data loading |
| Visualization | Power BI — Star Schema + 40 DAX measures |

---

## Repository structure

```
macro-risk-analysis/
│
├── sql/
│   ├── macro_risk_final.sql     # 6 modules, 18 queries — main analysis
│   ├── data_cleaning.sql        # Deduplication, outlier flagging, gap detection
│   └── powerbi_views.sql        # 5 Star Schema views for Power BI
│
├── python/
│   ├── fred_to_postgres.py      # Initial full load from FRED API
│   └── fred_update.py           # Incremental updates (auto-detects last date)
│
├── powerbi/
│   └── dax_final_fixed.txt      # 3 Calculated Columns + 40 DAX Measures
│
└── README.md
```

---

## Quickstart

### 1. Install dependencies

```bash
pip install requests pandas psycopg2-binary
```

### 2. Configure database

Edit `DB_CONFIG` in both Python files:

```python
DB_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "dbname":   "macro_risk",
    "user":     "your_user",
    "password": "your_password",
}
```

### 3. Create schema and tables

```bash
psql -U postgres -d macro_risk -f sql/macro_risk_final.sql
```

### 4. Load data from FRED

```bash
# First run — auto-detects earliest available FRED date per series
python python/fred_update.py

# Force full reload from beginning
python python/fred_update.py --full
```

### 5. Run analysis queries

Open `macro_risk_final.sql` in pgAdmin. Run each block with F5.

---

## Data pipeline

```
FRED API (free, no key required)
  └── fred_update.py
        ├── gdp_growth      Series: A191RL1Q225SBEA  Quarterly % change
        ├── fed_rate        Series: FEDFUNDS          Monthly → quarterly avg
        ├── unemployment    Series: UNRATE            Monthly → quarterly avg
        └── cpi_inflation   Series: CPIAUCSL          Monthly index → YoY %
              └── macro_risk.macro_indicators  (consolidated quarterly table)
```

The update script calls `get_fred_series_start()` which fetches the first available row from FRED using `observation_start=1776-07-04`. If the table is empty it loads from the beginning. If data exists it queries `MAX(date)` and only fetches newer rows. CPI is converted from index level to year-over-year percentage change using `pct_change(periods=12) * 100`.

---

## Module 1 — Crisis period detection

### Question
**Which quarters in U.S. history were recessions, and how do different crises compare?**

### How the SQL works

**Q1.1 — Recession identification**

Used `LAG()` to fetch the previous quarter's GDP. A quarter is labeled `RECESSION` only when both the current and previous quarters are negative — the standard NBER technical definition.

```sql
LAG(gdp_growth) OVER (ORDER BY date) AS prev_gdp
```

**Why LAG() and not a self-join?**
A self-join would require `ON t1.date = t2.date - INTERVAL '3 months'`. `LAG()` is cleaner, executes in a single pass, and handles NULLs safely: if there is no previous row, LAG() returns NULL, so `prev_gdp < 0` evaluates to FALSE — the first row in the dataset cannot trigger a false recession label.

**Q1.3 — Grouping crisis periods (islands-and-gaps)**

Every time GDP turns non-negative, a running counter increments. Quarters in the same unbroken negative run share the same group number.

```sql
SUM(CASE WHEN gdp_growth >= 0 THEN 1 ELSE 0 END)
    OVER (ORDER BY date) AS grp
```

`GROUP BY grp` collapses each continuous crisis into one row. `HAVING COUNT(*) >= 2` removes single-quarter dips.

**Q1.4 — Crisis comparison**

Pre-filtered rows to crisis windows using `WHERE date BETWEEN ... OR date BETWEEN ...` before `GROUP BY crisis_name`. Without this pre-filter, all non-crisis rows produce `crisis_name = NULL` and get grouped together, inflating the aggregates with 260+ irrelevant quarters.

### What the data showed

- **305 quarters analyzed. 40 were negative (13.1%).** The U.S. economy contracted in roughly 1 out of every 8 quarters since 1950.
- **The 1990s were the safest decade** — only 2 negative quarters in 40 (5%). The 1950s were the most volatile — 8 negative quarters in 40 (20%).
- **COVID 2020 Q2 hit −28.0%.** The next worst single quarter was 1958 Q1 at −10.0%. COVID was nearly 3x worse than anything in the previous 62 years.
- **2008 lasted the longest: 4 consecutive negative quarters.** Every other top-5 crisis lasted exactly 2 quarters.
- **1980 and 1981 appear as two separate crises.** The islands-and-gaps algorithm correctly separates them because positive quarters occurred in between — they are two distinct events, not one continuous recession.

| Crisis period | Quarters | Worst GDP | Total cumulative loss |
|---|---|---|---|
| 2020 COVID-19 | 2 | −28.00% | −33.20% |
| 1957–1958 | 2 | −10.00% | −14.10% |
| 2008 Financial Crisis | 4 | −8.50% | −15.80% |
| 1980 Recession | 2 | −8.00% | −8.50% |
| 1981–1982 Recession | 2 | −6.10% | −10.40% |

---

## Module 2 — Value at Risk (VaR)

### Question
**How bad could GDP get in any given quarter, expressed as a probability?**

### How the SQL works

**Q2.1 — Historical VaR using PERCENT_RANK and FILTER**

`PERCENT_RANK()` assigns each quarter a position from 0 (lowest GDP) to 1 (highest). The `FILTER` clause then calculates statistics within the tail.

```sql
PERCENT_RANK() OVER (ORDER BY gdp_growth)        AS prank
MAX(gdp_growth) FILTER (WHERE prank <= 0.05)     AS var_95
AVG(gdp_growth) FILTER (WHERE prank <= 0.05)     AS cvar_95
```

**Why FILTER instead of a subquery?**
`FILTER` is a PostgreSQL conditional aggregate. It applies the condition inside the aggregate in a single pass. A subquery approach would require two separate table scans or a CTE. On 305 rows the difference is negligible, but `FILTER` is the idiomatic PostgreSQL pattern and scales cleanly to larger datasets.

**VaR 95% vs CVaR 95% — why CVaR matters more:**
VaR 95% = −3.33% answers: "What is the threshold GDP rarely falls below?"
CVaR 95% = −6.83% answers: "When GDP does breach that threshold, how bad does it actually get?"
CVaR is always worse than VaR. It measures the magnitude of tail events, not just the boundary.

**Q2.3 — Rolling VaR: why PERCENTILE_CONT cannot use OVER()**

`PERCENTILE_CONT` is an ordered-set aggregate in PostgreSQL. It cannot be used with `OVER()` — doing so throws error `0A000: OVER is not supported for ordered-set aggregate`. The workaround is to group by year and calculate the percentile per group independently, producing an annual rolling view.

```sql
PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY gdp_growth)
-- Works in GROUP BY context
-- Does NOT work with OVER() window clause
```

### What the data showed

- **VaR 95% = −3.33%.** In 95 out of 100 quarters, GDP does not fall below this level.  
   *This defines the typical downside boundary of normal economic fluctuations.*

- **Only 4 quarters in 76 years ever breached VaR 99% (−7.94%): 1958 Q1, 1980 Q2, 2008 Q4, 2020 Q2. One breach approximately every 19 years.**  
   *These represent rare, system-level shocks rather than normal business cycle movements.*

- **COVID breached VaR 99% by 3.5x. −28.0% vs a threshold of −7.94%. No other event approaches this ratio.**  
   *This indicates an extreme outlier event far beyond historical expectations (“black swan” level shock).*

- **Unemployment VaR 95% = 9.02%. The 2008 peak (9.30%) barely exceeded it. COVID pushed unemployment to 13.0% — exceeding even the 99th percentile (10.12%).**  
   *Labor market stress during COVID surpassed even the most severe historical benchmarks.*

- **CPI VaR 99% = −0.63%. Deflation has occurred historically. 2009 Q3 recorded −1.61% CPI — a genuine deflation event.**  
   *Although rare, deflation is a real tail risk, typically associated with demand collapse during crises.*

- **The 1980s were the riskiest decade: annual VaR 95% was −6.88% in 1980, −4.09% in 1981, −5.41% in 1982 — three consecutive years of extreme volatility.**  
   *This reflects a period of sustained macro instability driven by high inflation and aggressive monetary tightening.*
---

## Module 3 — Indicator correlations

### Question
**Do Okun's Law, the Phillips Curve, and the Taylor Rule actually hold in the data?**

### How the SQL works

**Q3.1 — Native CORR() function**

PostgreSQL has a built-in `CORR()` aggregate. It accepts two column expressions and returns the Pearson correlation coefficient. It handles NULLs automatically — rows where either value is NULL are excluded.

```sql
ROUND(CORR(gdp_growth, unemployment)::NUMERIC, 4) AS okuns_law
```

The `::NUMERIC` cast is required before `ROUND()` because `CORR()` returns `double precision`, and `ROUND()` in PostgreSQL requires `NUMERIC`.

**Q3.2 — Decade breakdown without running 8 separate queries**

Wrapped the `CORR()` calls in a subquery with a `CASE` expression assigning each row to a decade. The outer query references the correlation aliases. This produces one result set with all decades side by side — directly comparable, no UNION required.

**Q3.3 — Lagged correlation to measure transmission delay**

`LAG(fed_rate, N)` with N = 2, 4, 6, 8 creates four columns representing the Fed Rate from 2, 4, 6, and 8 quarters ago. Correlating each with current GDP reveals which lag has the strongest relationship — the transmission delay.

```sql
LAG(fed_rate, 2) OVER (ORDER BY date) AS rate_2q_ago
LAG(fed_rate, 4) OVER (ORDER BY date) AS rate_4q_ago
```

`GREATEST(ABS(CORR(...)), ABS(CORR(...)), ...)` inside a CASE identifies the dominant lag without a separate sort step.

### What the data showed

| Theory | Expected | Full period (1950–2024) | Verdict |
|---|---|---|---|
| Okun's Law: GDP ↑ → Unemployment ↓ | Negative | −0.10 | Weak |
| Phillips Curve: CPI ↑ → Unemployment ↓ | Negative | +0.09 | Broken |
| Taylor Rule: CPI ↑ → Fed Rate ↑ | Positive | +0.71 | Confirmed |

- **The Taylor Rule is the only theory confirmed over the full 76-year period (+0.71).**
- **The Phillips Curve was −0.82 in the 1960s** — near-perfect inverse. Then stagflation hit in the 1970s (+0.14): high inflation and high unemployment simultaneously. The relationship broke down in 5 of 8 decades.
- **The Taylor Rule inverted in the 2020s (−0.07).** The Fed held rates near zero while inflation climbed from 1.25% to 6.77% through 2021. Historically, the Fed would have raised rates before inflation crossed 3%. This is the largest Taylor Rule deviation in the dataset.
- **Fed Rate → GDP transmission lag: strongest at 6 months, but only −0.13.** In 2022–2023, the Fed raised rates by 5 percentage points — GDP still grew 3.38% in 2023. The lag exists but fiscal stimulus and global demand overwhelmed the monetary signal.

---

## Module 4 — Trend and anomaly detection

### Question
**Which quarters were statistically abnormal, and is the 2026 economy in the normal zone?**

### How the SQL works

**Q4.2 — Z-score with CROSS JOIN and NULLIF guard**

Long-run statistics are computed once in a CTE, then broadcast to every row via `CROSS JOIN`. This avoids a scalar subquery executing 305 times.

```sql
WITH stats AS (
    SELECT AVG(gdp_growth) AS gdp_mean,
           STDDEV(gdp_growth) AS gdp_std
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '1950-01-01' AND '2024-12-31'
)
SELECT (m.gdp_growth - s.gdp_mean) / NULLIF(s.gdp_std, 0) AS gdp_zscore
FROM macro_risk.macro_indicators m
CROSS JOIN stats s
```

**Why NULLIF(s.gdp_std, 0)?**
Division by zero throws a PostgreSQL runtime error. `NULLIF(expr, 0)` returns NULL when `gdp_std = 0`, turning the division result to NULL instead of crashing. This is the standard guard for any Z-score or ratio calculation in SQL.

**Q4.3 — CPI deviation grouped by year**

`GROUP BY 1` is shorthand for the first expression in the SELECT clause (`EXTRACT(YEAR FROM date)::INT`). The classification CASE runs on the aggregated `AVG(cpi_inflation)` — which is only valid in an outer query context, not inside a WHERE clause. Hence the `HAVING`-equivalent structure using `CASE` inside SELECT.

### What the data showed

- **Only 2 EXTREME events (|Z| > 3) in 76 years:** 2020 Q2 crash (Z = −6.89) and 2020 Q3 rebound (Z = +6.96). The crash and the recovery were equally extreme in opposite directions.
- **6 CPI EXTREME quarters: all in 1979–1980** (Z = 3.21 to 3.88). Inflation reached 14.43% — more than 4 standard deviations above the 3.52% historical mean.
- **The 2% inflation target was hit in only 4 out of 36 years (1990–2026):** 1998, 2002, 2010, 2014. The "above target" state is effectively the base case.
- **2022–2026 disinflationary path:** 8.00% → 4.15% → 2.95% → 2.77% → 2.75%. The deviation from the 2% target narrowed every year: 6.00 → 2.15 → 0.95 → 0.77 → 0.75. No anomalies detected in 2024 or 2025.

---

## Module 5 — Recovery speed analysis

### Question
**Does a bigger Fed Rate cut produce a faster recovery from recession?**

### How the SQL works

**Q5.1 — Pre-crisis baseline with CROSS JOIN**

`AVG(gdp_growth)` over the 2 years before each crisis establishes a baseline. `CROSS JOIN` broadcasts this to all post-crisis quarters. `gap = gdp_growth - pre_crisis_avg` is the recovery metric — positive means recovered, negative means still below baseline.

**Q5.2 — Days to recovery: DATE arithmetic in PostgreSQL**

Subtracting two `DATE` values in PostgreSQL returns an `INTEGER` (number of days) — not an INTERVAL, not a TIMESTAMP difference. This is a common source of confusion.

```sql
-- DATE - DATE = INTEGER (days) in PostgreSQL
(recovery_date - crisis_onset)                     AS days
ROUND((recovery_date - crisis_onset) / 91.25)::INT AS quarters_to_recovery
```

Dividing by 91.25 (= 365.25 / 4) converts to quarters, accounting for leap years. Using 90 would drift by approximately 1.25 days per quarter over multi-year periods.

### What the data showed

| Crisis | Rate cut | Quarters to recover | Recovery shape |
|---|---|---|---|
| 2020 COVID-19 | −1.20 pts | 2 | V-shaped |
| 1980 Recession | −8.49 pts | 3 | Fast V |
| 2008 Financial Crisis | −4.38 pts | 8 | W-shaped |

- **The answer is: No.** A bigger rate cut does not produce faster recovery. COVID had the smallest cut and the fastest recovery. 2008 had a larger cut and the slowest.
- **The decisive 2020 factor was $2 trillion in fiscal stimulus**, not rate cuts. Module 3 showed the Fed Rate → GDP correlation is only −0.13.
- **The 2008 recovery in 2009 Q4 was a false signal.** GDP crossed the baseline but fell back into contraction in 2011 Q1 and Q3. The W-shape confirms a structurally damaged banking system that rate cuts could not fix.
- **The 1980 recession was engineered by the Volcker Fed** raising rates to 17.78% to kill inflation. Cutting rates 8.49 pts reversed the cause directly — which is why it worked in 3 quarters.

---

## Module 6 — Final risk dashboard

### Question
**What does the current macro environment look like, and is 2026 high-risk?**

### How the SQL works

**Q6.1 — Composite risk signal**

Three signals feed a single `OVERALL_RISK` label per quarter. The hierarchy: any HIGH signal (VaR breach or CPI Z-score > 2) → HIGH RISK; GDP below mean or unemployment above mean + 1 std → MODERATE RISK; otherwise LOW RISK.

**Q6.2 — Single-scan historical summary**

One SELECT with `AVG`, `MAX`, `MIN`, `STDDEV`, `COUNT`, `MIN(date)`, `MAX(date)` across all 305 rows simultaneously. No joins, no CTEs — one table scan returns the complete statistical picture.

### What the data showed

**Risk timeline 2020–2026:**

| Period | Risk level | Trigger |
|---|---|---|
| 2020 Q1–Q2 | HIGH RISK | VaR breached, GDP anomaly Z = −6.89 |
| 2020 Q3–Q4 | LOW RISK | GDP rebounded +34.9%, VaR cleared |
| 2021 Q1–Q4 | LOW RISK | GDP strong despite HIGH INFLATION |
| 2022 Q1–Q4 | MODERATE RISK | CPI 7–8%, no VaR breach |
| 2023 Q1–Q2 | MODERATE RISK | CPI still above 5% |
| 2023 Q3–Q4 | LOW RISK | CPI dropped below 5% |
| 2024 Q1–Q4 | LOW / MODERATE | CPI 2.7–3.2%, normalizing |
| 2025 Q1–Q4 | LOW / MODERATE | All indicators below historical average |
| 2026 Q1 | LOW RISK | CPI 2.75%, Unemployment 4.35%, Rate 3.64% |

**2026 Q1 vs 76-year averages:**

| Indicator | 2026 Q1 | 76-year avg | Difference |
|---|---|---|---|
| GDP growth | — (pending) | 3.26% | — |
| CPI inflation | 2.75% | 3.52% | −0.77 pts |
| Unemployment | 4.35% | 5.68% | −1.33 pts |
| Fed Rate | 3.64% | 4.52% | −0.88 pts |

The macro environment in 2026 appears stable, with all key indicators below long-term averages. However, similar configurations have occurred before major economic crises, indicating that low risk conditions may mask underlying vulnerabilities.

---

## SQL techniques reference

| Technique | Used in | What it does and why |
|---|---|---|
| `LAG(col, N) OVER (ORDER BY date)` | Q1.1, Q3.3 | Fetches value N rows back. Replaces self-joins for sequential comparisons. Single-pass, NULL-safe. |
| Islands-and-gaps: `SUM(CASE WHEN val >= 0 THEN 1 ELSE 0 END) OVER (ORDER BY date)` | Q1.3 | Assigns consecutive negative rows the same group number by counting non-negative "breaks". `GROUP BY grp` then collapses each island into one row. |
| `PERCENT_RANK() OVER (ORDER BY col)` | Q2.1 | Assigns 0–1 percentile rank to each row. Used to identify bottom 5% and 1% tail for VaR. |
| `FILTER (WHERE condition)` | Q2.1 | Conditional aggregate in one pass. `MAX(gdp) FILTER (WHERE prank <= 0.05)` = 5th percentile threshold without a subquery. |
| `PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY col)` | Q2.2, Q2.3 | Interpolated percentile. Cannot use `OVER()` — is an ordered-set aggregate not a window function. Error `0A000` if attempted with OVER. Group by year for rolling view. |
| `CORR(col1, col2)` | Q3.1, Q3.2 | Native Pearson correlation. Returns `double precision` — must cast `::NUMERIC` before `ROUND()`. NULLs excluded automatically. |
| `CROSS JOIN` single-row CTE | Q3.1, Q4.2, Q6.1 | Broadcasts one row of statistics (mean, std, VaR threshold) to all rows. Replaces scalar subqueries in SELECT that would execute once per row. |
| `NULLIF(expr, 0)` | Q4.2, Q6.1 | Prevents division-by-zero in Z-score. Returns NULL instead of error when std = 0. Required for robust ratio calculations. |
| `GREATEST(ABS(...), ABS(...))` | Q3.3 | Finds the maximum absolute value across columns. Used to identify the lag with the strongest correlation in a single CASE expression. |
| `HAVING COUNT(*) >= 2` | Q1.3 | Post-aggregation filter. Removes single-quarter dips from the crisis period list, keeping only multi-quarter events. |
| Pre-filter before `GROUP BY` | Q1.4, Q5.3 | Filters rows to relevant windows before grouping, preventing a NULL group row that would aggregate all non-matching rows together. |
| `DATE - DATE = INTEGER` | Q5.2 | PostgreSQL-specific: subtracting two DATE values returns integer days, not INTERVAL. Divide by 91.25 to convert to quarters (365.25 / 4 accounts for leap years). |
| `GROUP BY 1` | Q4.3 | Shorthand for the first SELECT expression. Reduces repetition when grouping by a derived column like `EXTRACT(YEAR FROM date)::INT`. |

---

## Key conclusions

**1. Economic theories hold selectively, not universally.**
The Phillips Curve confirmed in the 1960s (−0.82), broke in the 1970s (+0.14 stagflation), was absent in the 2010s (+0.21 "missing inflation"), and revived in the 2020s (−0.58). No decade confirms all three theories — Okun, Phillips, and Taylor — simultaneously.

**2. Monetary policy is weaker than textbooks suggest.**
Fed Rate → GDP lag correlation: −0.13 at 6 months. In 2022–2023, a 5 percentage point rate increase failed to prevent 3.38% GDP growth in 2023. In 2020, a 1.20 pt cut produced the fastest recovery in the dataset. Rate cuts work when the recession was caused by tight monetary policy (1980). They do not work when the recession was caused by credit destruction (2008) or external shock (2020).

**3. Crisis depth and recovery speed are unrelated.**
COVID: deepest crisis in 76 years (−28% GDP), fastest recovery (2 quarters). 2008: moderate depth (−8.5% GDP), slowest recovery (8 quarters). The difference is the transmission mechanism: 2020 had intact credit markets and direct fiscal support; 2008 had a broken banking system that rate cuts could not repair.

**4. The 2% inflation target is the exception, not the norm.**
In 36 years (1990–2026): 4 years on target, 29 above, 3 below. The historical average CPI is 3.52%. Treating 2.75% inflation in 2026 as a problem requires ignoring 76 years of data.

**5. The 2026 macro environment is historically calm — with one open question.**
CPI 2.75%, unemployment 4.35%, Fed Rate 3.64% — all below 76-year averages. No VaR breaches. No anomalies. Disinflationary trend intact four consecutive years. The last time this configuration existed was 2019 Q3 — one quarter before the largest shock in post-war history. Whether this is durable stability or a temporary lull cannot be determined from historical data alone.

---

## Data sources

- **GDP growth** — [FRED A191RL1Q225SBEA](https://fred.stlouisfed.org/series/GDPC1): Real GDP percent change from preceding period, quarterly, seasonally adjusted annual rate
- **Fed Funds Rate** — [FRED FEDFUNDS](https://fred.stlouisfed.org/series/FEDFUNDS): Effective Federal Funds Rate, monthly average, converted to quarterly
- **Unemployment** — [FRED UNRATE](https://fred.stlouisfed.org/series/UNRATE): Unemployment rate, monthly, seasonally adjusted, converted to quarterly average
- **CPI Inflation** — [FRED CPIAUCSL](https://fred.stlouisfed.org/series/CPIAUCSL): CPI all urban consumers, monthly index, converted to year-over-year percentage change

All series are publicly available. No API key required for CSV download.

---

## Author
Muhiddin Ahmadov


