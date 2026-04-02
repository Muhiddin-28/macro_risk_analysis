"""
FRED → PostgreSQL AQLLI YANGILASH
Har bir seriyaning FRED da yozilgan ENG BIRINCHI SANASIDAN yuklab oladi.
Qayta ishga tushirilganda faqat yangi (DB da yo'q) qatorlar tortiladi.

Ishlatish:
    python fred_update.py           # Oxirgi DB sanasidan yangilaydi
    python fred_update.py --full    # Seriyaning eng boshidan qayta yuklab oladi
"""

import requests
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from io import StringIO
from datetime import date
import argparse
import logging

# ============================================================
# LOGGING
# ============================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    handlers=[
        logging.FileHandler("fred_update.log", encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)

# ============================================================
# SOZLAMALAR — faqat shu joyni o'zgartiring
# ============================================================
DB_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "dbname":   "macro_analysis",
    "user":     "postgres",
    "password": "2002",
}

FRED_CSV_URL = "https://fred.stlouisfed.org/graph/fredgraph.csv"

SERIES = {
    "A191RL1Q225SBEA": {
        "table": "macro_risk.gdp_growth",
        "label": "GDP O'sishi",
        "is_cpi": False,
    },
    "FEDFUNDS": {
        "table": "macro_risk.fed_rate",
        "label": "Fed Funds Rate",
        "is_cpi": False,
    },
    "UNRATE": {
        "table": "macro_risk.unemployment",
        "label": "Ishsizlik",
        "is_cpi": False,
    },
    "CPIAUCSL": {
        "table": "macro_risk.cpi_inflation",
        "label": "CPI Inflyatsiya",
        "is_cpi": True,
    },
}


# ============================================================
# 1. FRED DAGI ENG BIRINCHI SANANI ANIQLASH
#    API key shart emas — CSV endpoint ishlatiladi
# ============================================================
def get_fred_series_start(series_id: str) -> str:
    """
    FRED ga bitta so'rov yuborib, seriyaning
    haqiqiy eng birinchi observation sanasini qaytaradi.
    """
    url = (
        f"{FRED_CSV_URL}"
        f"?id={series_id}"
        f"&observation_start=1776-07-04"  # FRED ning tarixiy boshi
        f"&sort_order=asc"
    )
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        df = pd.read_csv(StringIO(resp.text))
        df.columns = ["date", "value"]
        df = df[df["value"] != "."]
        if not df.empty:
            start = pd.to_datetime(df["date"].iloc[0]).strftime("%Y-%m-%d")
            log.info(f"     📅 FRED birinchi sana: {start}")
            return start
    except Exception as e:
        log.warning(f"     ⚠ Sana aniqlanmadi ({e}), 1900-01-01 ishlatiladi")
    return "1900-01-01"


# ============================================================
# 2. DB DAGI SO'NGGI SANANI ANIQLASH
# ============================================================
def get_db_last_date(conn, table: str):
    with conn.cursor() as cur:
        cur.execute(f"SELECT MAX(date) FROM {table}")
        result = cur.fetchone()[0]
    return result  # datetime.date yoki None


# ============================================================
# 3. QAYSI SANADAN YUKLAB OLISH KERAKLIGINI ANIQLASH
# ============================================================
def determine_start(conn, series_id: str, table: str, full_mode: bool) -> str:
    """
    full_mode=True  → FRED dagi eng birinchi sanadan
    full_mode=False → DB dagi oxirgi sanadan keyingisi
                      (DB bo'sh bo'lsa → FRED birinchi sanasidan)
    """
    if full_mode:
        start = get_fred_series_start(series_id)
        log.info(f"     🔄 TO'LIQ rejim: {start} dan yuklanadi")
        return start

    last_in_db = get_db_last_date(conn, table)

    if last_in_db is None:
        # Jadval mutlaqo bo'sh — FRED ning eng boshidan yuklaymiz
        start = get_fred_series_start(series_id)
        log.info(f"     🆕 Jadval bo'sh → FRED boshidan: {start}")
        return start
    else:
        # Mavjud oxirgi sanadan 1 kun keyingi
        next_day = (
            pd.Timestamp(last_in_db) + pd.DateOffset(days=1)
        ).strftime("%Y-%m-%d")
        log.info(f"     📂 DB oxirgi: {last_in_db} → {next_day} dan yangilanadi")
        return next_day


# ============================================================
# 4. FRED DAN MA'LUMOT YUKLAB OLISH
# ============================================================
def fetch_fred(series_id: str, start: str, end: str) -> pd.DataFrame:
    url = (
        f"{FRED_CSV_URL}"
        f"?id={series_id}"
        f"&observation_start={start}"
        f"&observation_end={end}"
    )
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()

    df = pd.read_csv(StringIO(resp.text))
    df.columns = ["date", "value"]
    df["date"]  = pd.to_datetime(df["date"])
    df = df[df["value"] != "."].copy()
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    df.dropna(subset=["value"], inplace=True)
    return df.reset_index(drop=True)


# ============================================================
# 5. CPI → YoY FOIZ O'ZGARISHI
# ============================================================
def cpi_to_yoy(conn, new_df: pd.DataFrame, full_mode: bool) -> pd.DataFrame:
    """
    YoY hisoblash uchun 12 oy oldingi qiymat kerak.
    Incremental rejimda DBdan 13 oylik tarix olib birlashtiriladi.
    """
    if full_mode:
        combined = new_df.sort_values("date").copy()
        hist_max = None
    else:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT date, value FROM macro_risk.cpi_inflation
                ORDER BY date DESC LIMIT 13
            """)
            rows = cur.fetchall()
        hist = pd.DataFrame(rows, columns=["date", "value"])
        hist["date"] = pd.to_datetime(hist["date"])
        hist_max = hist["date"].max() if not hist.empty else None
        combined = (
            pd.concat([hist, new_df])
            .drop_duplicates("date")
            .sort_values("date")
        )

    combined["value"] = combined["value"].pct_change(periods=12) * 100
    combined.dropna(subset=["value"], inplace=True)
    combined["value"] = combined["value"].round(4)

    # Faqat yangi qatorlarni qaytarish
    if hist_max is not None:
        combined = combined[combined["date"] > hist_max]

    return combined.reset_index(drop=True)


# ============================================================
# 6. UPSERT
# ============================================================
def upsert(conn, df: pd.DataFrame, table: str):
    if df.empty:
        log.info(f"  ⏭  {table} — yangi ma'lumot yo'q")
        return
    rows = [(row["date"].date(), float(row["value"])) for _, row in df.iterrows()]
    sql  = f"""
        INSERT INTO {table} (date, value)
        VALUES %s
        ON CONFLICT (date) DO UPDATE SET value = EXCLUDED.value;
    """
    with conn.cursor() as cur:
        execute_values(cur, sql, rows)
    conn.commit()
    log.info(f"  💾 {table} — {len(rows)} qator saqlandi")


# ============================================================
# 7. macro_indicators KONSOLIDATSIYA
# ============================================================
def refresh_macro_indicators(conn):
    sql = """
    INSERT INTO macro_risk.macro_indicators
        (date, gdp_growth, fed_rate, unemployment, cpi_inflation)
    WITH
    gdp   AS (SELECT DATE_TRUNC('quarter', date)::DATE AS qd, AVG(value) AS v
              FROM macro_risk.gdp_growth    GROUP BY 1),
    rate  AS (SELECT DATE_TRUNC('quarter', date)::DATE AS qd, AVG(value) AS v
              FROM macro_risk.fed_rate       GROUP BY 1),
    unemp AS (SELECT DATE_TRUNC('quarter', date)::DATE AS qd, AVG(value) AS v
              FROM macro_risk.unemployment   GROUP BY 1),
    cpi   AS (SELECT DATE_TRUNC('quarter', date)::DATE AS qd, AVG(value) AS v
              FROM macro_risk.cpi_inflation  GROUP BY 1)
    SELECT
        COALESCE(gdp.qd, rate.qd, unemp.qd, cpi.qd),
        ROUND(gdp.v::NUMERIC,   4),
        ROUND(rate.v::NUMERIC,  4),
        ROUND(unemp.v::NUMERIC, 2),
        ROUND(cpi.v::NUMERIC,   4)
    FROM gdp
    FULL OUTER JOIN rate  USING (qd)
    FULL OUTER JOIN unemp USING (qd)
    FULL OUTER JOIN cpi   USING (qd)
    ON CONFLICT (date) DO UPDATE SET
        gdp_growth    = EXCLUDED.gdp_growth,
        fed_rate      = EXCLUDED.fed_rate,
        unemployment  = EXCLUDED.unemployment,
        cpi_inflation = EXCLUDED.cpi_inflation;
    """
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM macro_risk.macro_indicators")
        n = cur.fetchone()[0]
    log.info(f"  ✅ macro_indicators — jami {n} kvartal")


# ============================================================
# 8. ASOSIY FUNKSIYA
# ============================================================
def main():
    parser = argparse.ArgumentParser(description="FRED → PostgreSQL yangilash")
    parser.add_argument(
        "--full", action="store_true",
        help="Seriyaning FRED dagi eng birinchi sanasidan to'liq yuklab oladi"
    )
    args = parser.parse_args()

    today = date.today().strftime("%Y-%m-%d")
    mode  = "TO'LIQ" if args.full else "INCREMENTAL"

    log.info("=" * 55)
    log.info(f"  Yangilash boshlandi [{mode}]: {today}")
    log.info("=" * 55)

    conn = psycopg2.connect(**DB_CONFIG)
    log.info("  ✅ PostgreSQL ga ulandi\n")

    for series_id, meta in SERIES.items():
        log.info(f"▶ {meta['label']} ({series_id})")

        start = determine_start(conn, series_id, meta["table"], args.full)

        if start > today:
            log.info(f"  ⏭  Allaqachon dolzarb — o'tkazildi\n")
            continue

        # CPI incremental rejimda 13 oy orqaga
        if meta["is_cpi"] and not args.full:
            cpi_from = (
                pd.Timestamp(start) - pd.DateOffset(months=13)
            ).strftime("%Y-%m-%d")
            raw = fetch_fred(series_id, cpi_from, today)
            df  = cpi_to_yoy(conn, raw, full_mode=False)
        else:
            df = fetch_fred(series_id, start, today)
            if meta["is_cpi"]:
                df = cpi_to_yoy(conn, df, full_mode=True)

        if not df.empty:
            log.info(
                f"  ⬇  {len(df)} qator: "
                f"{df['date'].min().date()} → {df['date'].max().date()}"
            )
        upsert(conn, df, meta["table"])
        log.info("")

    log.info("🔗 macro_indicators konsolidatsiyalanmoqda...")
    refresh_macro_indicators(conn)

    conn.close()
    log.info("\n✅ Yangilash muvaffaqiyatli yakunlandi!\n")


if __name__ == "__main__":
    main()