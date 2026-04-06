-- ================================================================
-- MODULE 4: TREND AND ANOMALY DETECTION
-- ================================================================
 
-- ----------------------------------------------------------------
-- QUERY 4.1
-- QUESTION: Which direction did each indicator move year by year?
-- ----------------------------------------------------------------
 
WITH yearly AS (
    SELECT
        EXTRACT(YEAR FROM date)::INT AS yr,
        AVG(gdp_growth)              AS gdp,
        AVG(cpi_inflation)           AS cpi,
        AVG(unemployment)            AS unemp,
        AVG(fed_rate)                AS rate
    FROM macro_risk.macro_indicators
    WHERE date >= '2015-01-01'
    GROUP BY 1
)
SELECT
    yr,
    ROUND(gdp::NUMERIC,   2) AS avg_gdp,
    CASE
        WHEN gdp > LAG(gdp) OVER (ORDER BY yr) THEN 'UP'
        WHEN gdp < LAG(gdp) OVER (ORDER BY yr) THEN 'DOWN'
        ELSE 'FLAT'
    END                      AS gdp_trend,
    ROUND(cpi::NUMERIC,   2) AS avg_cpi,
    CASE
        WHEN cpi > LAG(cpi) OVER (ORDER BY yr) THEN 'UP'
        WHEN cpi < LAG(cpi) OVER (ORDER BY yr) THEN 'DOWN'
        ELSE 'FLAT'
    END                      AS cpi_trend,
    ROUND(unemp::NUMERIC, 2) AS avg_unemp,
    CASE
        WHEN unemp > LAG(unemp) OVER (ORDER BY yr) THEN 'UP'
        WHEN unemp < LAG(unemp) OVER (ORDER BY yr) THEN 'DOWN'
        ELSE 'FLAT'
    END                      AS unemp_trend,
    ROUND(rate::NUMERIC,  2) AS avg_fed_rate,
    CASE
        WHEN rate > LAG(rate) OVER (ORDER BY yr) THEN 'UP'
        WHEN rate < LAG(rate) OVER (ORDER BY yr) THEN 'DOWN'
        ELSE 'FLAT'
    END                      AS rate_trend
FROM yearly
ORDER BY yr;
 
 
-- ----------------------------------------------------------------
-- QUERY 4.2
-- QUESTION: Which quarters were statistically abnormal?
--
-- Z-score = (value - mean) / std_dev
-- |Z| > 2  = Anomaly      (outside 95% confidence interval)
-- |Z| > 3  = Extreme event (outside 99.7% confidence interval)
-- ----------------------------------------------------------------
 
WITH stats AS (
    SELECT
        AVG(gdp_growth)    AS gdp_mean, STDDEV(gdp_growth)    AS gdp_std,
        AVG(cpi_inflation) AS cpi_mean, STDDEV(cpi_inflation) AS cpi_std,
        AVG(unemployment)  AS un_mean,  STDDEV(unemployment)  AS un_std
    FROM macro_risk.macro_indicators
    WHERE date BETWEEN '1950-01-01' AND '2024-12-31'
)
SELECT
    m.date,
    EXTRACT(YEAR FROM m.date)::INT                                          AS yr,
    ROUND(m.gdp_growth::NUMERIC,    2)                                      AS gdp,
    ROUND((m.gdp_growth - s.gdp_mean) / NULLIF(s.gdp_std, 0), 2)           AS gdp_z,
    ROUND(m.cpi_inflation::NUMERIC, 2)                                      AS cpi,
    ROUND((m.cpi_inflation - s.cpi_mean) / NULLIF(s.cpi_std, 0), 2)        AS cpi_z,
    ROUND(m.unemployment::NUMERIC,  2)                                      AS unemployment,
    ROUND((m.unemployment - s.un_mean) / NULLIF(s.un_std, 0), 2)           AS unemp_z,
    CASE
        WHEN ABS((m.gdp_growth - s.gdp_mean)    / NULLIF(s.gdp_std, 0)) > 3 THEN 'GDP — EXTREME'
        WHEN ABS((m.cpi_inflation - s.cpi_mean) / NULLIF(s.cpi_std, 0)) > 3 THEN 'CPI — EXTREME'
        WHEN ABS((m.unemployment - s.un_mean)   / NULLIF(s.un_std,  0)) > 3 THEN 'UNEMP — EXTREME'
        WHEN ABS((m.gdp_growth - s.gdp_mean)    / NULLIF(s.gdp_std, 0)) > 2 THEN 'GDP — Anomaly'
        WHEN ABS((m.cpi_inflation - s.cpi_mean) / NULLIF(s.cpi_std, 0)) > 2 THEN 'CPI — Anomaly'
        WHEN ABS((m.unemployment - s.un_mean)   / NULLIF(s.un_std,  0)) > 2 THEN 'UNEMP — Anomaly'
        ELSE 'Normal'
    END AS anomaly_type
FROM macro_risk.macro_indicators m
CROSS JOIN stats s
WHERE
    ABS((m.gdp_growth - s.gdp_mean)    / NULLIF(s.gdp_std, 0)) > 2
    OR ABS((m.cpi_inflation - s.cpi_mean) / NULLIF(s.cpi_std, 0)) > 2
    OR ABS((m.unemployment - s.un_mean)   / NULLIF(s.un_std,  0)) > 2
ORDER BY GREATEST(
    ABS((m.gdp_growth - s.gdp_mean)    / NULLIF(s.gdp_std, 0)),
    ABS((m.cpi_inflation - s.cpi_mean) / NULLIF(s.cpi_std, 0)),
    ABS((m.unemployment - s.un_mean)   / NULLIF(s.un_std,  0))
) DESC;
 
 
-- ----------------------------------------------------------------
-- QUERY 4.3
-- QUESTION: How far did inflation deviate from the 2% Fed target?
-- ----------------------------------------------------------------
 
SELECT
    EXTRACT(YEAR FROM date)::INT                   AS yr,
    ROUND(AVG(cpi_inflation)::NUMERIC, 2)          AS avg_inflation,
    ROUND((AVG(cpi_inflation) - 2)::NUMERIC, 2)    AS deviation_from_target,
    ROUND(AVG(fed_rate)::NUMERIC, 2)               AS avg_fed_rate,
    CASE
        WHEN AVG(cpi_inflation) > 5               THEN 'HIGH — Fed raising rates'
        WHEN AVG(cpi_inflation) > 2               THEN 'ABOVE TARGET'
        WHEN AVG(cpi_inflation) BETWEEN 1.5 AND 2 THEN 'ON TARGET'
        WHEN AVG(cpi_inflation) > 0               THEN 'BELOW TARGET'
        ELSE                                           'DEFLATION RISK'
    END AS inflation_status
FROM macro_risk.macro_indicators
WHERE date >= '1990-01-01'
GROUP BY 1
ORDER BY 1;
 
 