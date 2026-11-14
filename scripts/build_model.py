"""Build the star schema used by the Power BI dashboard.

Reads the raw Olist CSV files from data/raw/ and writes one CSV per
model table to data/model/.

Usage:
    python scripts/build_model.py
"""
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
MODEL = ROOT / "data" / "model"
SQL = ROOT / "sql" / "star_schema.sql"

RAW_TABLES = {
    "customers": "olist_customers_dataset.csv",
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "products": "olist_products_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}
MODEL_TABLES = ["dim_date", "dim_state", "dim_product", "dim_seller", "fact_orders", "fact_order_items"]


def main() -> None:
    missing = [f for f in RAW_TABLES.values() if not (RAW / f).exists()]
    if missing:
        raise SystemExit("Missing CSV files in data/raw/:\n  - " + "\n  - ".join(missing))

    con = duckdb.connect()  # in-memory: the CSV files in data/model/ are the output
    for table, filename in RAW_TABLES.items():
        con.execute(
            f"CREATE TABLE {table} AS "
            f"SELECT * FROM read_csv_auto('{(RAW / filename).as_posix()}', header = true)"
        )

    con.execute(SQL.read_text(encoding="utf-8"))

    MODEL.mkdir(parents=True, exist_ok=True)
    for table in MODEL_TABLES:
        out = MODEL / f"{table}.csv"
        con.execute(f"COPY {table} TO '{out.as_posix()}' (HEADER, DELIMITER ',')")
        rows = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        print(f"{table:<20}{rows:>10,} rows -> data/model/{out.name}")
    con.close()


if __name__ == "__main__":
    main()
