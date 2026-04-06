-- 1. Dublikat o'chir
DELETE FROM macro_risk.macro_indicators
WHERE id NOT IN (SELECT MAX(id) FROM macro_risk.macro_indicators GROUP BY date);

-- 2. Xato qiymatlarni belgilab qo'y
ALTER TABLE macro_risk.macro_indicators ADD COLUMN IF NOT EXISTS is_outlier BOOLEAN DEFAULT FALSE;

UPDATE macro_risk.macro_indicators SET is_outlier = TRUE
WHERE gdp_growth NOT BETWEEN -15 AND 20
   OR cpi_inflation NOT BETWEEN -5 AND 25
   OR unemployment  NOT BETWEEN  0 AND 25
   OR fed_rate      NOT BETWEEN  0 AND 22;
