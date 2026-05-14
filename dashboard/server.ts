import { readFileSync } from "fs";
import { resolve } from "path";
import mysql from "mysql2/promise";

const DB_HOST = "127.0.0.1";
const DB_PORT = 3390;
const DB_USER = "root";
const DB_PASSWORD = "kilroy";
const DB_NAME = "Bluetti_AC200MAX";

const pool = mysql.createPool({
  host: DB_HOST,
  port: DB_PORT,
  user: DB_USER,
  password: DB_PASSWORD,
  database: DB_NAME,
  charset: "utf8mb4",
  waitForConnections: true,
  connectionLimit: 5,
  dateStrings: true,
  decimalNumbers: true,
});

const SELECT_COLS = `timestamp, total_battery_percent, total_battery_voltage, ac_input_power, dc_input_power, ac_output_power, dc_output_power, internal_ac_voltage, internal_current_one, internal_power_one, internal_ac_frequency, internal_dc_input_voltage, internal_dc_input_power, internal_dc_input_current, power_generation, ac_output_on, dc_output_on, pack_battery_percent, pack_voltage`;

async function readData() {
  const [rows] = await pool.query(`SELECT ${SELECT_COLS} FROM readings ORDER BY timestamp ASC`);
  return (rows as any[]).map((r) => ({
    ...r,
    ac_output_on: !!r.ac_output_on,
    dc_output_on: !!r.dc_output_on,
  }));
}

function computePrediction(rows: any[]) {
  if (rows.length < 2) return null;

  const first = rows[0];
  const last = rows[rows.length - 1];
  const batteryNow = Number(last.total_battery_percent);
  if (batteryNow >= 100) return { fullAt: "Already full", pctPerMin: 0, minsLeft: 0 };

  const batteryStart = Number(first.total_battery_percent);
  const t0 = new Date(first.timestamp).getTime();
  const t1 = new Date(last.timestamp).getTime();
  const elapsedMin = (t1 - t0) / 60000;
  if (elapsedMin < 1) return null;

  const pctPerMin = (batteryNow - batteryStart) / elapsedMin;
  if (pctPerMin <= 0) return { fullAt: "Not charging (discharging or flat)", pctPerMin, minsLeft: Infinity, batteryNow, avgChargeRate: Math.round(pctPerMin * 60 * 10) / 10 };

  const minsLeft = (100 - batteryNow) / pctPerMin;
  const fullAt = new Date(t1 + minsLeft * 60000);

  return {
    batteryNow,
    batteryStart,
    elapsedMin: Math.round(elapsedMin),
    pctPerMin: Math.round(pctPerMin * 1000) / 1000,
    minsLeft: Math.round(minsLeft),
    fullAt: fullAt.toISOString(),
    avgChargeRate: Math.round(pctPerMin * 60 * 10) / 10,
  };
}

function computeDailyTotal(rows: any[]) {
  const today = new Date().toISOString().slice(0, 10);
  let producedW = 0;
  let usedW = 0;

  for (let i = 0; i < rows.length; i++) {
    const ts = rows[i].timestamp?.toString().slice(0, 10);
    if (ts !== today) continue;

    producedW += (rows[i].dc_input_power || 0);
    usedW += (rows[i].ac_output_power || 0) + (rows[i].dc_output_power || 0);
  }

  return {
    producedW: Math.round(producedW),
    usedW: Math.round(usedW),
  };
}

const server = Bun.serve({
  port: 5000,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/api/data") {
      const rows = await readData();
      return Response.json({ rows, prediction: computePrediction(rows), dailyTotal: computeDailyTotal(rows) });
    }

    const html = readFileSync(resolve(import.meta.dir, "index.html"), "utf-8");
    return new Response(html, { headers: { "Content-Type": "text/html" } });
  },
});

console.log(`Dashboard running at http://localhost:${server.port} (data from MariaDB ${DB_HOST}:${DB_PORT}/${DB_NAME})`);
