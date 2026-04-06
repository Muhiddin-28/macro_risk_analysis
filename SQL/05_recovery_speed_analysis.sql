-- ================================================================
-- MODULE 5: RECOVERY SPEED ANALYSIS
-- ================================================================


-- ----------------------------------------------------------------
-- QUERY 5.1
-- QUESTION: Quarter by quarter — how did GDP recover after COVID
--           and 2008? When did it cross back above the pre-crisis level?
-- ----------------------------------------------------------------

WITH baselines AS (
    SELECT 'COVID'          AS crisis,
           AVG(gdp_growth)  AS pre_crisis_avg
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '2018-01-01' AND '2019-12-31'

    UNION ALL

    SELECT '2008 Crisis',
           AVG(gdp_growth)
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '2005-01-01' AND '2007-09-30'
)
SELECT
    m.date,
    b.crisis,
    ROUND(m.gdp_growth::NUMERIC,      2) AS gdp,
    ROUND(b.pre_crisis_avg::NUMERIC,  2) AS pre_crisis_baseline,
    ROUND((m.gdp_growth - b.pre_crisis_avg)::NUMERIC, 2) AS gap,
    CASE
        WHEN m.gdp_growth >= b.pre_crisis_avg THEN 'RECOVERED'
        WHEN m.gdp_growth >= 0               THEN 'POSITIVE BUT BELOW BASELINE'
        ELSE                                      'STILL IN CONTRACTION'
    END AS status
FROM macro_risk.macro_indicators m
CROSS JOIN baselines b
WHERE
    (b.crisis = 'COVID'       AND m.date BETWEEN '2020-01-01' AND '2023-12-31')
    OR
    (b.crisis = '2008 Crisis' AND m.date BETWEEN '2008-01-01' AND '2013-12-31')
ORDER BY b.crisis, m.date;


-- ----------------------------------------------------------------
-- QUERY 5.2
-- QUESTION: Which crisis had the fastest recovery?
-- METRIC  : Quarters from crisis onset until GDP returned to
--           the pre-crisis average level
-- NOTE    : DATE - DATE = INTEGER (days) in PostgreSQL.
--           Divide by 91.25 for quarters, 365.25 for years.
-- ----------------------------------------------------------------

WITH baselines AS (
    SELECT 'COVID'          AS crisis,
           AVG(gdp_growth)  AS pre_crisis_avg,
           '2020-01-01'::DATE AS crisis_onset
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '2018-01-01' AND '2019-12-31'

    UNION ALL

    SELECT '2008 Crisis',
           AVG(gdp_growth),
           '2007-10-01'::DATE
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '2005-01-01' AND '2007-09-30'

    UNION ALL

    SELECT '1980 Recession',
           AVG(gdp_growth),
           '1980-01-01'::DATE
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '1977-01-01' AND '1979-12-31'
),
first_recovery AS (
    SELECT
        b.crisis,
        b.crisis_onset,
        -- First quarter after crisis onset where GDP >= pre-crisis average
        MIN(m.date) AS recovery_date
    FROM macro_risk.macro_indicators m
    JOIN baselines b ON m.date > b.crisis_onset
    WHERE m.gdp_growth >= b.pre_crisis_avg
    GROUP BY b.crisis, b.crisis_onset
)
SELECT
    crisis,
    crisis_onset,
    recovery_date,
    -- DATE - DATE returns INTEGER (number of days) in PostgreSQL
    (recovery_date - crisis_onset)                       AS days,
    ROUND((recovery_date - crisis_onset) / 91.25)::INT  AS quarters_to_recovery,
    ROUND((recovery_date - crisis_onset) / 365.25, 1)   AS years_to_recovery
FROM first_recovery
ORDER BY quarters_to_recovery;


-- ----------------------------------------------------------------
-- QUERY 5.3
-- QUESTION: How aggressively did the Fed cut rates in each crisis?
-- THEORY  : The Fed cuts rates to stimulate a contracting economy.
--           Larger cuts = more severe crisis response.
-- ----------------------------------------------------------------

WITH crisis_rates AS (
    SELECT
        CASE
            WHEN date BETWEEN '1973-01-01' AND '1975-12-31' THEN '1973 Oil Shock'
            WHEN date BETWEEN '1980-01-01' AND '1982-12-31' THEN '1980 Recession'
            WHEN date BETWEEN '2007-10-01' AND '2009-12-31' THEN '2008 Financial Crisis'
            WHEN date BETWEEN '2020-01-01' AND '2020-12-31' THEN '2020 COVID-19'
        END     AS crisis_name,
        MIN(date) OVER (PARTITION BY
            CASE
                WHEN date BETWEEN '1973-01-01' AND '1975-12-31' THEN 1
                WHEN date BETWEEN '1980-01-01' AND '1982-12-31' THEN 2
                WHEN date BETWEEN '2007-10-01' AND '2009-12-31' THEN 3
                WHEN date BETWEEN '2020-01-01' AND '2020-12-31' THEN 4
            END
        )       AS crisis_start,
        fed_rate
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '1973-01-01' AND '1975-12-31'
       OR date BETWEEN '1980-01-01' AND '1982-12-31'
       OR date BETWEEN '2007-10-01' AND '2009-12-31'
       OR date BETWEEN '2020-01-01' AND '2020-12-31'
)
SELECT
    crisis_name,
    ROUND(MAX(fed_rate)::NUMERIC, 2)                    AS rate_at_peak,
    ROUND(MIN(fed_rate)::NUMERIC, 2)                    AS rate_at_trough,
    -- Negative = Fed cut rates; more negative = bigger cut
    ROUND((MIN(fed_rate) - MAX(fed_rate))::NUMERIC, 2)  AS total_cut,
    CASE
        WHEN MIN(fed_rate) - MAX(fed_rate) < -3 THEN 'AGGRESSIVE  (> 3 pts)'
        WHEN MIN(fed_rate) - MAX(fed_rate) < -1 THEN 'MODERATE    (1-3 pts)'
        ELSE                                        'MINOR       (< 1 pt)'
    END AS fed_response
FROM crisis_rates
GROUP BY crisis_name, crisis_start
ORDER BY crisis_start;