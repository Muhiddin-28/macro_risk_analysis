-- ================================================================
-- MODULE 2: VALUE AT RISK (VaR)
-- ================================================================
 
-- ----------------------------------------------------------------
-- QUERY 2.1
-- QUESTION: What is GDP downside risk at 95% and 99% confidence?
--
-- VaR 95% : GDP fell below this value in only 5 out of 100 quarters
-- CVaR 95%: Average GDP when VaR is breached (worst 5% average)
-- ----------------------------------------------------------------
 
WITH ranked AS (
    SELECT
        gdp_growth,
        PERCENT_RANK() OVER (ORDER BY gdp_growth) AS prank
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
      AND gdp_growth IS NOT NULL
)
SELECT
    ROUND(MAX(gdp_growth) FILTER (WHERE prank <= 0.05)::NUMERIC, 2) AS var_95,
    ROUND(MAX(gdp_growth) FILTER (WHERE prank <= 0.01)::NUMERIC, 2) AS var_99,
    ROUND(AVG(gdp_growth) FILTER (WHERE prank <= 0.05)::NUMERIC, 2) AS cvar_95,
    ROUND(AVG(gdp_growth) FILTER (WHERE prank <= 0.01)::NUMERIC, 2) AS cvar_99,
    COUNT(*) FILTER (WHERE prank <= 0.05)                           AS var95_breach_count,
    COUNT(*) FILTER (WHERE prank <= 0.01)                           AS var99_breach_count
FROM ranked;

 -- ----------------------------------------------------------------
-- QUERY 2.2
-- QUESTION: What is the VaR for each indicator?
-- NOTE    : GDP/inflation — downside (low) is the risk
--           Unemployment  — upside (high) is the risk
-- ----------------------------------------------------------------
 
SELECT
    indicator,
    ROUND(var_95::NUMERIC, 2) AS var_95,
    ROUND(var_99::NUMERIC, 2) AS var_99,
    note
FROM (
    SELECT
        'GDP Growth (%)'   AS indicator,
        PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY gdp_growth) AS var_95,
        PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY gdp_growth) AS var_99,
        '5% chance GDP falls below this level'                   AS note
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
 
    UNION ALL
 
    SELECT
        'CPI Inflation (%)',
        PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY cpi_inflation),
        PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY cpi_inflation),
        '5% chance inflation falls below this level'
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
 
    UNION ALL
 
    SELECT
        'Unemployment (%)',
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY unemployment),
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY unemployment),
        '5% chance unemployment rises above this level'
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
 
    UNION ALL
 
    SELECT
        'Fed Funds Rate (%)',
        PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY fed_rate),
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY fed_rate),
        'Historical extreme low and high thresholds'
    FROM macro_risk.macro_indicators
    WHERE date >= '1950-01-01'
) t;
 
 
-- ================================================================
-- QUERY 2.3 — Annual Value at Risk (VaR) by Year
-- ================================================================
-- QUESTION: How has GDP downside risk changed year by year?
--
-- VaR 95% : 5% chance GDP falls below this value in a given year.
--           Negative = bad quarter occurred. Positive = safe year.
-- VaR 99% : Even more extreme downside estimate.
-- quarters : Years below 4 are incomplete — interpret with caution.
-- ================================================================

SELECT
    -- Year as integer for clean output
    EXTRACT(YEAR FROM date)::INT             AS yr,

    -- Lower 5th percentile of the 4 quarterly GDP values
    -- Negative = at least one bad quarter that year
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP
          (ORDER BY gdp_growth)::NUMERIC, 2) AS var95,

    -- Lower 1st percentile — more conservative threshold
    ROUND(PERCENTILE_CONT(0.01) WITHIN GROUP
          (ORDER BY gdp_growth)::NUMERIC, 2) AS var99,

    -- Incomplete years (< 4) should not be interpreted
    COUNT(*)                                 AS quarters

FROM macro_risk.macro_indicators
WHERE date >= '1960-01-01'
GROUP BY 1
ORDER BY 1;