#!/usr/bin/env python3
"""Database model for Bluetti AC200MAX telemetry data (MariaDB)."""

import pymysql

DB_HOST = "127.0.0.1"
DB_PORT = 3390
DB_USER = "root"
DB_PASSWORD = "kilroy"
DB_NAME = "Bluetti_AC200MAX"

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS readings (
    id                      INT AUTO_INCREMENT PRIMARY KEY,
    timestamp               DATETIME NOT NULL UNIQUE,
    total_battery_percent   INT,
    total_battery_voltage   DECIMAL(10,4),
    ac_input_power          INT,
    dc_input_power          INT,
    ac_output_power         INT,
    dc_output_power         INT,
    internal_ac_voltage     DECIMAL(10,4),
    internal_current_one    DECIMAL(10,4),
    internal_power_one      INT,
    internal_ac_frequency   INT,
    internal_dc_input_voltage   DECIMAL(10,4),
    internal_dc_input_power     DECIMAL(10,4),
    internal_dc_input_current   DECIMAL(10,4),
    power_generation        INT,
    ac_output_on            TINYINT(1) NOT NULL DEFAULT 0,
    dc_output_on            TINYINT(1) NOT NULL DEFAULT 0,
    pack_battery_percent    INT,
    pack_voltage            DECIMAL(10,4),
    elapsed_seconds         INT,
    charging_state          TINYINT(1) NOT NULL DEFAULT 0,
    battery_range           TINYINT(1) NOT NULL DEFAULT 0,
    net_power               INT,
    power_rate              TINYINT(1) NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

CREATE_INDEX_SQL = """
CREATE INDEX IF NOT EXISTS idx_readings_timestamp ON readings(timestamp);
"""


def get_connection(db_name=None):
    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=db_name or DB_NAME,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )


def init_db():
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(CREATE_TABLE_SQL)
        cur.execute(CREATE_INDEX_SQL)
    conn.commit()
    conn.close()


if __name__ == "__main__":
    init_db()
    print(f"Database initialized: {DB_NAME} on {DB_HOST}:{DB_PORT}")
