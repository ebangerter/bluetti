//! MariaDB archive: schema bootstrap and row inserts.

use anyhow::{Context, Result};
use mysql::prelude::*;
use mysql::{Conn, Opts, OptsBuilder};

use crate::protocol::CSV_COLUMNS;

/// One column of an outgoing row, in a form both the CSV and MariaDB understand.
#[derive(Clone, Debug)]
pub enum Cell {
    Int(i64),
    /// Fixed-point value plus the number of decimal places to render.
    Dec(f64, u32),
    Bool(bool),
    Text(String),
    Null,
}

impl Cell {
    pub fn to_csv(&self) -> String {
        match self {
            Cell::Int(v) => v.to_string(),
            Cell::Dec(v, scale) => crate::protocol::format_decimal(*v, *scale),
            // Matches the Python csv module's rendering of a bool.
            Cell::Bool(b) => (if *b { "True" } else { "False" }).to_string(),
            Cell::Text(s) => s.clone(),
            Cell::Null => String::new(),
        }
    }

    fn to_sql(&self) -> mysql::Value {
        match self {
            Cell::Int(v) => mysql::Value::Int(*v),
            Cell::Dec(v, _) => mysql::Value::Double(*v),
            Cell::Bool(b) => mysql::Value::Int(*b as i64),
            Cell::Text(s) => mysql::Value::Bytes(s.clone().into_bytes()),
            Cell::Null => mysql::Value::NULL,
        }
    }
}

/// A full reading row, ordered to match `CSV_COLUMNS`.
pub struct Row {
    pub cells: Vec<Cell>,
}

pub struct Config {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

impl Config {
    pub fn from_env() -> Self {
        let env =
            |key: &str, fallback: &str| std::env::var(key).unwrap_or_else(|_| fallback.to_string());
        Config {
            host: env("BLUETTI_DB_HOST", "127.0.0.1"),
            port: env("BLUETTI_DB_PORT", "3390").parse().unwrap_or(3390),
            user: env("BLUETTI_DB_USER", "root"),
            password: env("BLUETTI_DB_PASSWORD", "kilroy"),
            database: env("BLUETTI_DB_NAME", "Bluetti_AC200MAX"),
        }
    }
}

pub struct Archive {
    conn: Conn,
    insert_sql: String,
}

impl Archive {
    pub fn connect(config: &Config) -> Result<Self> {
        let opts: Opts = OptsBuilder::new()
            .ip_or_hostname(Some(config.host.clone()))
            .tcp_port(config.port)
            .user(Some(config.user.clone()))
            .pass(Some(config.password.clone()))
            .db_name(Some(config.database.clone()))
            .into();
        let conn = Conn::new(opts).context("could not connect to MariaDB")?;

        let placeholders = vec!["?"; CSV_COLUMNS.len()].join(", ");
        let insert_sql = format!(
            "INSERT IGNORE INTO readings ({}) VALUES ({})",
            CSV_COLUMNS.join(", "),
            placeholders
        );

        Ok(Archive { conn, insert_sql })
    }

    pub fn init_schema(&mut self) -> Result<()> {
        self.conn.query_drop(
            r"CREATE TABLE IF NOT EXISTS readings (
                id                          INT AUTO_INCREMENT PRIMARY KEY,
                timestamp                   DATETIME NOT NULL UNIQUE,
                total_battery_percent       INT,
                total_battery_voltage       DECIMAL(10,4),
                ac_input_power              INT,
                dc_input_power              INT,
                ac_output_power             INT,
                dc_output_power             INT,
                internal_ac_voltage         DECIMAL(10,4),
                internal_current_one        DECIMAL(10,4),
                internal_power_one          INT,
                internal_ac_frequency       INT,
                internal_dc_input_voltage   DECIMAL(10,4),
                internal_dc_input_power     DECIMAL(10,4),
                internal_dc_input_current   DECIMAL(10,4),
                power_generation            INT,
                ac_output_on                TINYINT(1) NOT NULL DEFAULT 0,
                dc_output_on                TINYINT(1) NOT NULL DEFAULT 0,
                pack_battery_percent        INT,
                pack_voltage                DECIMAL(10,4),
                elapsed_seconds             INT,
                charging_state              TINYINT(1) NOT NULL DEFAULT 0,
                battery_range               TINYINT(1) NOT NULL DEFAULT 0,
                net_power                   INT,
                power_rate                  TINYINT(1) NOT NULL DEFAULT 0
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
        )?;
        self.conn.query_drop(
            "CREATE INDEX IF NOT EXISTS idx_readings_timestamp ON readings(timestamp)",
        )?;

        for (name, definition) in [
            ("elapsed_seconds", "INT"),
            ("charging_state", "TINYINT(1) NOT NULL DEFAULT 0"),
            ("battery_range", "TINYINT(1) NOT NULL DEFAULT 0"),
            ("net_power", "INT"),
            ("power_rate", "TINYINT(1) NOT NULL DEFAULT 0"),
        ] {
            self.conn.query_drop(format!(
                "ALTER TABLE readings ADD COLUMN IF NOT EXISTS {} {}",
                name, definition
            ))?;
        }

        println!("  Database schema ready");
        Ok(())
    }

    pub fn insert(&mut self, row: &Row) -> Result<()> {
        let params: Vec<mysql::Value> = row.cells.iter().map(Cell::to_sql).collect();
        self.conn.exec_drop(&self.insert_sql, params)?;
        Ok(())
    }

    pub fn ping(&mut self) -> bool {
        self.conn.ping().is_ok()
    }
}
