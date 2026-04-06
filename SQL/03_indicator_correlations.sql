-- ================================================================
-- MODULE 3: INDICATOR CORRELATIONS
-- ================================================================
 
-- ----------------------------------------------------------------
-- QUERY 3.1
-- QUESTION: Do classic economic theories hold in the data?
--
-- Okun's Law     : GDP up  → Unemployment down  (expect negative)
-- Phillips Curve : CPI up  → Unemployment down  (expect negative)
-- Taylor Rule    : CPI up  → Fed Rate up         (expect positive)
--
-- Scale: < -0.7 strong negative | -0.3 to 0.3 weak | > +0.7 strong positive
-- ----------------------------------------------------------------
 
SELECT
    ROUND(CORR(gdp_growth,    unemployment)::NUMERIC, 4) AS okuns_law,
    ROUND(CORR(cpi_inflation, unemployment)::NUMERIC, 4) AS phillips_curve,
    ROUND(CORR(fed_rate,      cpi_inflation)::NUMERIC, 4) AS taylor_rule,
    ROUND(CORR(gdp_growth,    cpi_inflation)::NUMERIC, 4) AS gdp_vs_inflation
FROM macro_risk.macro_indicators
WHERE date BETWEEN '1950-01-01' AND '2024-12-31';
 
 
-- ----------------------------------------------------------------
-- QUERY 3.2
-- QUESTION: Have these correlations changed across decades?
-- NOTE    : Phillips Curve is expected to weaken after the 1980s
-- ----------------------------------------------------------------
 
SELECT
    decade,
    quarters,
    ROUND(gdp_unemp_corr::NUMERIC, 4)  AS okuns_law_corr,
    CASE
        WHEN gdp_unemp_corr < -0.3 THEN 'Confirmed'
        WHEN gdp_unemp_corr <  0   THEN 'Weak'
        ELSE                            'Not confirmed'
    END                                AS okuns_law_status,
    ROUND(cpi_unemp_corr::NUMERIC, 4)  AS phillips_curve_corr,
    CASE
        WHEN cpi_unemp_corr < -0.3 THEN 'Confirmed'
        WHEN cpi_unemp_corr <  0   THEN 'Weak'
        ELSE                            'Flattened / broken down'
    END                                AS phillips_curve_status,
    ROUND(rate_cpi_corr::NUMERIC, 4)   AS taylor_rule_corr
FROM (
    SELECT
        CASE
            WHEN date BETWEEN '1950-01-01' AND '1959-12-31' THEN '1950s'
            WHEN date BETWEEN '1960-01-01' AND '1969-12-31' THEN '1960s'
            WHEN date BETWEEN '1970-01-01' AND '1979-12-31' THEN '1970s'
            WHEN date BETWEEN '1980-01-01' AND '1989-12-31' THEN '1980s'
            WHEN date BETWEEN '1990-01-01' AND '1999-12-31' THEN '1990s'
            WHEN date BETWEEN '2000-01-01' AND '2009-12-31' THEN '2000s'
            WHEN date BETWEEN '2010-01-01' AND '2019-12-31' THEN '2010s'
            WHEN date BETWEEN '2020-01-01' AND '2024-12-31' THEN '2020s'
        END                               AS decade,
        COUNT(*)                          AS quarters,
        CORR(gdp_growth, unemployment)    AS gdp_unemp_corr,
        CORR(cpi_inflation, unemployment) AS cpi_unemp_corr,
        CORR(fed_rate, cpi_inflation)     AS rate_cpi_corr
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
    GROUP BY 1
) sub
WHERE decade IS NOT NULL
ORDER BY decade;
 
 
-- ----------------------------------------------------------------
-- QUERY 3.3
-- QUESTION: After how many quarters does Fed Rate affect GDP?
-- THEORY  : Monetary policy has a 6-18 month transmission lag
-- ----------------------------------------------------------------
 
WITH lagged AS (
    SELECT
        date,
        gdp_growth,
        LAG(fed_rate, 2) OVER (ORDER BY date) AS rate_2q_ago,
        LAG(fed_rate, 4) OVER (ORDER BY date) AS rate_4q_ago,
        LAG(fed_rate, 6) OVER (ORDER BY date) AS rate_6q_ago,
        LAG(fed_rate, 8) OVER (ORDER BY date) AS rate_8q_ago
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
)
SELECT
    ROUND(CORR(gdp_growth, rate_2q_ago)::NUMERIC, 4) AS corr_lag_2q,
    ROUND(CORR(gdp_growth, rate_4q_ago)::NUMERIC, 4) AS corr_lag_4q,
    ROUND(CORR(gdp_growth, rate_6q_ago)::NUMERIC, 4) AS corr_lag_6q,
    ROUND(CORR(gdp_growth, rate_8q_ago)::NUMERIC, 4) AS corr_lag_8q,
    -- Strongest absolute correlation = most likely transmission lag
    CASE
        WHEN ABS(CORR(gdp_growth, rate_2q_ago)) = GREATEST(
            ABS(CORR(gdp_growth, rate_2q_ago)), ABS(CORR(gdp_growth, rate_4q_ago)),
            ABS(CORR(gdp_growth, rate_6q_ago)), ABS(CORR(gdp_growth, rate_8q_ago)))
        THEN '6 months'
        WHEN ABS(CORR(gdp_growth, rate_4q_ago)) = GREATEST(
            ABS(CORR(gdp_growth, rate_2q_ago)), ABS(CORR(gdp_growth, rate_4q_ago)),
            ABS(CORR(gdp_growth, rate_6q_ago)), ABS(CORR(gdp_growth, rate_8q_ago)))
        THEN '1 year'
        WHEN ABS(CORR(gdp_growth, rate_6q_ago)) = GREATEST(
            ABS(CORR(gdp_growth, rate_2q_ago)), ABS(CORR(gdp_growth, rate_4q_ago)),
            ABS(CORR(gdp_growth, rate_6q_ago)), ABS(CORR(gdp_growth, rate_8q_ago)))
        THEN '1.5 years'
        ELSE '2 years'
    END AS strongest_lag
FROM lagged;