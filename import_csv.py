#!/usr/bin/env python3
"""Import data.csv into the Bluetti MariaDB database."""

import csv
import sys
from pathlib import Path

from models import init_db, get_connection

CSV_PATH = Path(__file__).parent / "data.csv"

COLUMNS = [
    "timestamp",
    "total_battery_percent",
    "total_battery_voltage",
    "ac_input_power",
    "dc_input_power",
    "ac_output_power",
    "dc_output_power",
    "internal_ac_voltage",
    "internal_current_one",
    "internal_power_one",
    "internal_ac_frequency",
    "internal_dc_input_voltage",
    "internal_dc_input_power",
    "internal_dc_input_current",
    "power_generation",
    "ac_output_on",
    "dc_output_on",
    "pack_battery_percent",
    "pack_voltage",
]

INSERT_SQL = f"""
INSERT IGNORE INTO readings ({', '.join(COLUMNS)})
VALUES ({', '.join('%s' for _ in COLUMNS)})
"""

BOOL_MAP = {"True": 1, "False": 0, "true": 1, "false": 0, "1": 1, "0": 0}


def parse_row(row):
    values = []
    for col in COLUMNS:
        val = row.get(col, "").strip()
        if col == "timestamp":
            values.append(val)
        elif col in ("ac_output_on", "dc_output_on"):
            values.append(BOOL_MAP.get(val, 0))
        elif col in (
            "total_battery_voltage",
            "internal_ac_voltage",
            "internal_current_one",
            "internal_dc_input_voltage",
            "internal_dc_input_power",
            "internal_dc_input_current",
            "pack_voltage",
        ):
            values.append(float(val) if val else None)
        else:
            values.append(int(float(val)) if val else None)
    return values


def import_csv(csv_path=None):
    csv_path = csv_path or CSV_PATH
    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found", file=sys.stderr)
        sys.exit(1)

    init_db()
    conn = get_connection()

    inserted = 0
    skipped = 0

    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                values = parse_row(row)
                with conn.cursor() as cur:
                    cur.execute(INSERT_SQL, values)
                if conn.affected_rows() > 0:
                    inserted += 1
                else:
                    skipped += 1
            except Exception as e:
                print(f"Error importing row {row.get('timestamp', '?')}: {e}", file=sys.stderr)
                skipped += 1

    conn.commit()

    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS cnt FROM readings")
        total = cur.fetchone()["cnt"]
    conn.close()

    print(f"Import complete: {inserted} inserted, {skipped} skipped, {total} total rows in database")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Import Bluetti CSV data into MariaDB")
    parser.add_argument("--csv", type=Path, default=CSV_PATH, help="Path to CSV file")
    args = parser.parse_args()

    import_csv(args.csv)
