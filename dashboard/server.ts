import { readFileSync, existsSync, statSync } from "fs";
import { resolve, extname } from "path";
import mysql from "mysql2/promise";

const MIME_TYPES: Record<string, string> = {
  ".js": "application/javascript",
  ".css": "text/css",
  ".html": "text/html",
  ".json": "application/json",
  ".txt": "text/plain",
};

const DB_HOST = process.env.BLUETTI_DB_HOST || "127.0.0.1";
const DB_PORT = parseInt(process.env.BLUETTI_DB_PORT || "3390", 10);
const DB_USER = process.env.BLUETTI_DB_USER || "root";
const DB_PASSWORD = process.env.BLUETTI_DB_PASSWORD || "kilroy";
const DB_NAME = process.env.BLUETTI_DB_NAME || "Bluetti_AC200MAX";

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

const SELECT_COLS = `timestamp, total_battery_percent, total_battery_voltage, ac_input_power, dc_input_power, ac_output_power, dc_output_power, internal_ac_voltage, internal_current_one, internal_power_one, internal_ac_frequency, internal_dc_input_voltage, internal_dc_input_power, internal_dc_input_current, power_generation, ac_output_on, dc_output_on, pack_battery_percent, pack_voltage, elapsed_seconds, charging_state, battery_range, net_power, power_rate`;

async function readData(date?: string) {
  let sql: string;
  let params: any[] = [];
  if (date) {
    sql = `SELECT ${SELECT_COLS} FROM readings WHERE timestamp >= ? AND timestamp < ? + INTERVAL 1 DAY ORDER BY timestamp ASC`;
    params = [date, date];
  } else {
    sql = `SELECT ${SELECT_COLS} FROM readings ORDER BY timestamp ASC`;
  }
  const [rows] = await pool.query(sql, params);
  return (rows as any[]).map((r) => ({
    ...r,
    ac_output_on: !!r.ac_output_on,
    dc_output_on: !!r.dc_output_on,
  }));
}

async function readAvailableDates() {
  const [rows] = await pool.query(
    `SELECT DISTINCT DATE(timestamp) AS date FROM readings ORDER BY date ASC`
  );
  return (rows as any[]).map((r) => {
    const d = r.date;
    return typeof d === "string" ? d : (d as Date).toISOString().slice(0, 10);
  });
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

function computeDailyTotal(rows: any[], date: string) {
  let producedW = 0;
  let usedW = 0;
  let chargingTimeSec = 0;
  let dischargingTimeSec = 0;
  let trickleTimeSec = 0;
  let normalTimeSec = 0;
  let fastTimeSec = 0;
  let rangeTime = [0, 0, 0, 0];

  for (let i = 0; i < rows.length; i++) {
    const ts = rows[i].timestamp?.toString().slice(0, 10);
    if (ts !== date) continue;

    const dcIn = rows[i].dc_input_power || 0;
    const acIn = rows[i].ac_input_power || 0;
    const dcOut = rows[i].dc_output_power || 0;
    const net = dcIn - dcOut;
    const elapsed = rows[i].elapsed_seconds || 0;
    const state = rows[i].charging_state;
    const rate = rows[i].power_rate;
    const br = rows[i].battery_range;

    producedW += dcIn;
    usedW += (rows[i].ac_output_power || 0) + dcOut;

    if (state === 0) {
      dischargingTimeSec += elapsed;
    } else {
      chargingTimeSec += elapsed;
    }

    if (rate === 0) trickleTimeSec += elapsed;
    else if (rate === 1) normalTimeSec += elapsed;
    else if (rate === 2) fastTimeSec += elapsed;

    if (br >= 0 && br <= 3) rangeTime[br] += elapsed;
  }

  const fmtHour = (sec: number) => (sec / 3600).toFixed(1) + "h";
  return {
    producedW: Math.round(producedW),
    usedW: Math.round(usedW),
    chargingTime: fmtHour(chargingTimeSec),
    dischargingTime: fmtHour(dischargingTimeSec),
    trickleTime: fmtHour(trickleTimeSec),
    normalTime: fmtHour(normalTimeSec),
    fastTime: fmtHour(fastTimeSec),
    rangeTime,
  };
}

const BLUETTI_ADDRESS = process.env.BLUETTI_MAC || "";
const BLUETTI_SCRIPT = resolve(import.meta.dir, "..", "bluetti_reader.py");
const READER_PIDFILE = "/tmp/bluetti_reader.pid";

function stopReader(): void {
  try {
    const pid = parseInt(readFileSync(READER_PIDFILE, "utf-8").trim());
    if (pid) process.kill(pid, "SIGTERM");
  } catch {}
  Bun.spawnSync(["pkill", "-f", "bluetti_reader.py"]);
}

function startReader(): void {
  try {
    Bun.spawn(["bash", resolve(import.meta.dir, "..", "run.bash")], {
      detached: true,
      stdio: "ignore",
    });
  } catch {}
}

function toggleOutput(output: string, state: string): Promise<{ ok: boolean; msg: string }> {
  return new Promise((resolve) => {
    if (!BLUETTI_ADDRESS) {
      resolve({ ok: false, msg: "BLUETTI_MAC env var not set" });
      return;
    }
    const flag = `--${output}-${state}`;
    stopReader();
    setTimeout(() => {
      try {
        const proc = Bun.spawn(["python3", BLUETTI_SCRIPT, "-a", BLUETTI_ADDRESS, flag], {
          stdout: "pipe",
          stderr: "pipe",
        });
        const exitCode = proc.exited;
        const stdout = new Response(proc.stdout).text();
        const stderr = new Response(proc.stderr).text();
        Promise.all([exitCode, stdout, stderr]).then(([code, out, err]) => {
          startReader();
          if (code !== 0) {
            resolve({ ok: false, msg: err || `Process exited with code ${code}` });
            return;
          }
          if (out.includes("success")) {
            resolve({ ok: true, msg: `${output.toUpperCase()} output turned ${state}` });
          } else {
            resolve({ ok: false, msg: out + err });
          }
        });
      } catch (e: any) {
        startReader();
        resolve({ ok: false, msg: e.message || "Failed to execute command" });
      }
    }, 8000);
  });
}

const server = Bun.serve({
  port: 5000,
  async fetch(req) {
    const url = new URL(req.url);
    console.log("Request:", url.pathname);

    if (url.pathname === "/api/toggle" && req.method === "POST") {
      try {
        const body = await req.json() as { output: string; state: string };
        const result = await toggleOutput(body.output, body.state);
        return Response.json(result);
      } catch (e: any) {
        return Response.json({ ok: false, msg: e.message || "Invalid request" });
      }
    }

    const filePath = resolve(import.meta.dir, "." + url.pathname);
    if (existsSync(filePath) && !statSync(filePath).isDirectory()) {
      const ext = extname(filePath);
      const mime = MIME_TYPES[ext] || "application/octet-stream";
      return new Response(readFileSync(filePath), {
        headers: { "Content-Type": mime, "Cache-Control": "no-cache" },
      });
    }

    if (url.pathname === "/api/dates") {
      const dates = await readAvailableDates();
      return Response.json({ dates });
    }

    if (url.pathname === "/api/data") {
      const date = url.searchParams.get("date") || undefined;
      const rows = await readData(date);
      const targetDate = date || new Date().toISOString().slice(0, 10);
      return Response.json({
        rows,
        prediction: computePrediction(rows),
        dailyTotal: computeDailyTotal(rows, targetDate),
        date: targetDate,
      });
    }

    const html = readFileSync(resolve(import.meta.dir, "index.html"), "utf-8");
    return new Response(html, { headers: { "Content-Type": "text/html" } });
  },
});

console.log(`Dashboard running at http://localhost:${server.port} (data from MariaDB ${DB_HOST}:${DB_PORT}/${DB_NAME})`);
