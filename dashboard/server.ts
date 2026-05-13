import { readFileSync, watchFile } from "fs";
import { resolve } from "path";

const CSV_PATH = resolve(import.meta.dir, "..", "data.csv");

function parseCSV(content: string) {
  const lines = content.trim().split("\n");
  if (lines.length < 2) return [];

  const headers = lines[0].split(",");
  const rows = [];

  for (let i = 1; i < lines.length; i++) {
    const values = lines[i].split(",");
    const row: Record<string, string | number | boolean> = {};
    for (let j = 0; j < headers.length; j++) {
      const v = values[j]?.trim();
      if (v === "True") row[headers[j]] = true;
      else if (v === "False") row[headers[j]] = false;
      else if (v !== "" && !isNaN(Number(v))) row[headers[j]] = Number(v);
      else row[headers[j]] = v;
    }
    rows.push(row);
  }
  return rows;
}

function readData() {
  try {
    return parseCSV(readFileSync(CSV_PATH, "utf-8"));
  } catch {
    return [];
  }
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
  if (pctPerMin <= 0) return { fullAt: "Not charging (discharging or flat)", pctPerMin, minsLeft: Infinity };

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

const server = Bun.serve({
  port: 5000,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/api/data") {
      const rows = readData();
      return Response.json({ rows, prediction: computePrediction(rows) });
    }

    const html = readFileSync(resolve(import.meta.dir, "index.html"), "utf-8");
    return new Response(html, { headers: { "Content-Type": "text/html" } });
  },
});

console.log(`Dashboard running at http://localhost:${server.port}`);
