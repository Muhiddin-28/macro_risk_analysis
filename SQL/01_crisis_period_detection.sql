-- ================================================================
-- MODULE 1: CRISIS PERIOD DETECTION
-- ================================================================
 
-- ----------------------------------------------------------------
-- QUERY 1.1
-- QUESTION: Which quarters were recessions?
-- LOGIC   : Recession = 2 consecutive quarters of negative GDP
-- ----------------------------------------------------------------
 
WITH flagged AS (
    SELECT
        date,
        gdp_growth,
        LAG(gdp_growth) OVER (ORDER BY date) AS prev_gdp
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
      AND gdp_growth IS NOT NULL
)
SELECT
    date,
    EXTRACT(YEAR    FROM date)::INT AS yr,
    EXTRACT(QUARTER FROM date)::INT AS qtr,
    ROUND(gdp_growth::NUMERIC, 2)   AS gdp_growth,
    ROUND(prev_gdp::NUMERIC,   2)   AS prev_quarter_gdp,
    CASE
        WHEN gdp_growth < 0 AND prev_gdp < 0 THEN 'RECESSION'
        WHEN gdp_growth < 0                  THEN 'NEGATIVE (1 quarter only)'
        WHEN gdp_growth < 1                  THEN 'WEAK GROWTH'
        WHEN gdp_growth < 3                  THEN 'NORMAL'
        ELSE                                      'STRONG GROWTH'
    END AS status
FROM flagged
WHERE gdp_growth < 0
ORDER BY date;
 
 
-- ----------------------------------------------------------------
-- QUERY 1.2
-- QUESTION: How many recession quarters per decade?
-- ----------------------------------------------------------------
 
WITH flagged AS (
    SELECT
        date,
        gdp_growth,
        LAG(gdp_growth) OVER (ORDER BY date) AS prev_gdp
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
      AND gdp_growth IS NOT NULL
)
SELECT
    (FLOOR(EXTRACT(YEAR FROM date) / 10) * 10)::INT AS decade,
    COUNT(*)                                         AS total_quarters,
    COUNT(*) FILTER (WHERE gdp_growth < 0)           AS negative_quarters,
    COUNT(*) FILTER (WHERE gdp_growth < 0
                       AND prev_gdp   < 0)           AS recession_quarters,
    ROUND(
        COUNT(*) FILTER (WHERE gdp_growth < 0) * 100.0 / NULLIF(COUNT(*), 0),
    1)                                               AS negative_pct
FROM flagged
GROUP BY 1
ORDER BY 1;
 
 
-- ----------------------------------------------------------------
-- QUERY 1.3
-- QUESTION: What were the 5 worst multi-quarter crisis periods?
-- METHOD  : Groups consecutive negative GDP quarters together
-- ----------------------------------------------------------------
 
WITH grouped AS (
    SELECT
        date,
        gdp_growth,
        -- Every time GDP turns non-negative, group counter increments.
        -- Consecutive negatives share the same group number.
        SUM(CASE WHEN gdp_growth >= 0 THEN 1 ELSE 0 END)
            OVER (ORDER BY date) AS grp
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
      AND gdp_growth IS NOT NULL
)
SELECT
    MIN(date)                          AS crisis_start,
    MAX(date)                          AS crisis_end,
    COUNT(*)                           AS quarters_count,
    ROUND(MIN(gdp_growth)::NUMERIC, 2) AS worst_gdp,
    ROUND(AVG(gdp_growth)::NUMERIC, 2) AS avg_gdp,
    ROUND(SUM(gdp_growth)::NUMERIC, 2) AS cumulative_gdp_loss
FROM grouped
WHERE gdp_growth < 0
GROUP BY grp
HAVING COUNT(*) >= 2
ORDER BY MIN(gdp_growth)
LIMIT 5;
 
 
-- ----------------------------------------------------------------
-- QUERY 1.4
-- QUESTION: How do the 4 major crises compare side by side?
-- ----------------------------------------------------------------
 
WITH crisis_data AS (
    SELECT
        CASE
            WHEN date BETWEEN '1973-01-01' AND '1975-12-31' THEN '1973 Oil Shock'
            WHEN date BETWEEN '1980-01-01' AND '1982-12-31' THEN '1980 Recession'
            WHEN date BETWEEN '2007-10-01' AND '2009-06-30' THEN '2008 Financial Crisis'
            WHEN date BETWEEN '2020-01-01' AND '2020-12-31' THEN '2020 COVID-19'
        END AS crisis_name,
        MIN(date)             AS crisis_start,
        gdp_growth,
        cpi_inflation,
        unemployment,
        fed_rate
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '1973-01-01' AND '1975-12-31'
       OR date BETWEEN '1980-01-01' AND '1982-12-31'
       OR date BETWEEN '2007-10-01' AND '2009-06-30'
       OR date BETWEEN '2020-01-01' AND '2020-12-31'
    GROUP BY crisis_name, date, gdp_growth, cpi_inflation, unemployment, fed_rate
)
SELECT
    crisis_name,
    MIN(crisis_start)                         AS started,
    COUNT(*)                                  AS quarters,
    ROUND(MIN(gdp_growth)::NUMERIC,    2)     AS worst_gdp,
    ROUND(MAX(cpi_inflation)::NUMERIC, 2)     AS peak_inflation,
    ROUND(MAX(unemployment)::NUMERIC,  2)     AS peak_unemployment,
    ROUND(MAX(fed_rate)::NUMERIC,      2)     AS peak_fed_rate,
    ROUND(MIN(fed_rate)::NUMERIC,      2)     AS lowest_fed_rate
FROM crisis_data
GROUP BY crisis_name
ORDER BY MIN(crisis_start);
 