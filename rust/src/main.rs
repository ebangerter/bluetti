//! Read current values from a Bluetti AC200MAX over Bluetooth LE.

mod db;
mod protocol;

use std::io::Write;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use btleplug::api::{
    BDAddr, Central, CharPropFlags, Characteristic, Manager as _, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Manager, Peripheral};
use chrono::Local;
use clap::Parser;
use futures::StreamExt;
use tokio::sync::watch;
use uuid::Uuid;

use db::{Archive, Cell, Row};
use protocol::*;

const WRITE_UUID: Uuid = Uuid::from_u128(0x0000ff02_0000_1000_8000_00805f9b34fb);
const NOTIFY_UUID: Uuid = Uuid::from_u128(0x0000ff01_0000_1000_8000_00805f9b34fb);
const DEVICE_NAME_UUID: Uuid = Uuid::from_u128(0x00002a00_0000_1000_8000_00805f9b34fb);

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_RETRIES: u32 = 3;
const POLL_STEP: Duration = Duration::from_millis(100);

#[derive(Parser)]
#[command(name = "bluetti-reader", about = "Read Bluetti AC200MAX data over Bluetooth")]
struct Cli {
    /// Bluetooth MAC address of the device
    #[arg(short, long)]
    address: Option<String>,

    /// Scan for Bluetti devices
    #[arg(short, long)]
    scan: bool,

    /// Number of readings (default: 1, use 0 for infinite)
    #[arg(short, long, default_value_t = 1)]
    r#loop: u64,

    /// Seconds between readings
    #[arg(short, long, default_value_t = 5)]
    interval: u64,

    /// Log readings to CSV (defaults: --loop 1440 --interval 60)
    #[arg(long, value_name = "FILE")]
    csv: Option<String>,

    /// Store readings in MariaDB (auto-enabled when --csv is used)
    #[arg(long)]
    mysql: bool,

    /// Turn DC output ON
    #[arg(long)]
    dc_on: bool,
    /// Turn DC output OFF
    #[arg(long)]
    dc_off: bool,
    /// Turn AC output ON
    #[arg(long)]
    ac_on: bool,
    /// Turn AC output OFF
    #[arg(long)]
    ac_off: bool,
}

// ── BLE plumbing ─────────────────────────────────────────────────────────────

async fn adapter() -> Result<btleplug::platform::Adapter> {
    let manager = Manager::new().await.context("no Bluetooth manager")?;
    manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("no Bluetooth adapter found"))
}

/// Discover every advertising peripheral whose name starts with "AC200M".
async fn scan_devices() -> Result<Vec<(String, BDAddr)>> {
    println!("Scanning for Bluetti devices...");
    let central = adapter().await?;
    central.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(Duration::from_secs(5)).await;
    let _ = central.stop_scan().await;

    let mut found = Vec::new();
    for peripheral in central.peripherals().await? {
        let Some(properties) = peripheral.properties().await? else {
            continue;
        };
        let Some(name) = properties.local_name else {
            continue;
        };
        if name.starts_with("AC200M") {
            found.push((name, peripheral.address()));
        }
    }

    if found.is_empty() {
        println!("No AC200MAX devices found.");
    } else {
        for (name, address) in &found {
            println!("  {} - {}", name, address);
        }
    }
    Ok(found)
}

/// Scan until the requested address shows up, then return the peripheral.
async fn find_device(address: &str, timeout: Duration) -> Result<Peripheral> {
    let target = BDAddr::from_str(address).context("invalid MAC address")?;
    let central = adapter().await?;
    central.start_scan(ScanFilter::default()).await?;

    let deadline = Instant::now() + timeout;
    let found = loop {
        let mut hit = None;
        for peripheral in central.peripherals().await? {
            if peripheral.address() == target {
                hit = Some(peripheral);
                break;
            }
        }
        if hit.is_some() {
            break hit;
        }
        if Instant::now() >= deadline {
            break None;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    };

    let _ = central.stop_scan().await;
    found.ok_or_else(|| anyhow!("Device {} not found during scan", address))
}

struct Link {
    peripheral: Peripheral,
    write_char: Characteristic,
    notify_char: Characteristic,
    buffer: Arc<Mutex<Vec<u8>>>,
}

impl Link {
    async fn open(peripheral: Peripheral, announce: bool) -> Result<Self> {
        peripheral.connect().await.context("BLE connect failed")?;
        peripheral.discover_services().await?;

        let characteristics = peripheral.characteristics();
        let find = |uuid: Uuid| {
            characteristics
                .iter()
                .find(|c| c.uuid == uuid)
                .cloned()
                .ok_or_else(|| anyhow!("characteristic {} not found", uuid))
        };
        let write_char = find(WRITE_UUID)?;
        let notify_char = find(NOTIFY_UUID)?;

        if announce {
            if let Ok(name) = peripheral.read(&find(DEVICE_NAME_UUID)?).await {
                println!("Connected to: {}", String::from_utf8_lossy(&name));
            }
        }

        peripheral.subscribe(&notify_char).await?;

        // Notifications arrive in fragments, so accumulate them exactly as the
        // Python reader does and let the caller decide when enough has arrived.
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&buffer);
        let mut notifications = peripheral.notifications().await?;
        tokio::spawn(async move {
            while let Some(notification) = notifications.next().await {
                if notification.uuid == NOTIFY_UUID {
                    sink.lock().unwrap().extend_from_slice(&notification.value);
                }
            }
        });

        Ok(Link { peripheral, write_char, notify_char, buffer })
    }

    fn write_type(&self) -> WriteType {
        if self.write_char.properties.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) {
            WriteType::WithoutResponse
        } else {
            WriteType::WithResponse
        }
    }

    /// Send a frame and wait until `expected` bytes have accumulated.
    async fn transact(&self, command: &[u8], expected: usize) -> Result<Option<Vec<u8>>> {
        self.buffer.lock().unwrap().clear();
        self.peripheral.write(&self.write_char, command, self.write_type()).await?;

        let deadline = Instant::now() + RESPONSE_TIMEOUT;
        loop {
            if self.buffer.lock().unwrap().len() >= expected {
                break;
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            tokio::time::sleep(POLL_STEP).await;
        }

        let buffer = self.buffer.lock().unwrap();
        Ok(Some(buffer[..expected].to_vec()))
    }

    async fn close(&self) {
        let _ = self.peripheral.unsubscribe(&self.notify_char).await;
        let _ = self.peripheral.disconnect().await;
    }
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// Poll every register block once and return whatever decoded.
async fn poll_once(link: &Link) -> Result<Readings> {
    let mut readings = Readings::new();

    for (start, quantity) in POLLING_REGISTERS {
        let command = build_read_command(start, quantity);
        let expected = expected_response_size(quantity);

        for _ in 0..MAX_RETRIES {
            let Some(response) = link.transact(&command, expected).await? else {
                continue;
            };

            if response[1] == 0x83 {
                println!(
                    "  MODBUS error for registers {}+{}: code {}",
                    start, quantity, response[2]
                );
                break;
            }
            if !validate_crc(&response) {
                continue;
            }

            parse_fields(start, &response[3..response.len() - 2], &mut readings);
            break;
        }
    }

    Ok(readings)
}

struct Kpis {
    elapsed: i64,
    charging_state: u8,
    battery_range: u8,
    net_power: i64,
    power_rate: u8,
}

fn compute_kpis(readings: &Readings, elapsed: i64) -> Kpis {
    let get = |key: &str| readings.get(key).and_then(|r| r.value.as_i64()).unwrap_or(0);

    let dc_input = get("dc_input_power");
    let ac_input = get("ac_input_power");
    let ac_output = get("ac_output_power");
    let dc_output = get("dc_output_power");
    let battery_pct = readings.get("total_battery_percent").and_then(|r| r.value.as_i64());

    let net_power = compute_net_power(dc_input, ac_input, ac_output, dc_output);
    let charging_state = compute_charging_state(dc_input, ac_input);
    let battery_range = compute_battery_range(battery_pct).unwrap_or(0);
    let power_rate = compute_power_rate(if charging_state > 0 { net_power } else { 0 });

    Kpis { elapsed, charging_state, battery_range, net_power, power_rate }
}

fn print_reading(readings: &Readings, kpis: &Kpis, index: u64, total: Option<u64>) {
    let f = |key: &str| format_value(readings, key);

    println!("\n{}", "=".repeat(50));
    if total.is_none_or(|t| t > 1) {
        println!("Reading #{} at {}", index + 1, Local::now().format("%H:%M:%S"));
    }
    println!("{}", "=".repeat(50));

    if readings.contains_key("device_type") {
        println!("  Device:          {}", f("device_type"));
    }
    println!("  Battery:         {}", f("total_battery_percent"));
    println!("  Battery Voltage: {}", f("total_battery_voltage"));

    println!("\n  --- Power ---");
    println!("  AC Input:        {}", f("ac_input_power"));
    println!("  DC Input:        {}", f("dc_input_power"));
    println!("  AC Output:       {}", f("ac_output_power"));
    println!("  DC Output:       {}", f("dc_output_power"));

    println!("\n  --- AC Details ---");
    let mode = readings
        .get("ac_output_mode")
        .and_then(|r| r.value.as_i64())
        .map(|m| output_mode_label(m as u16).to_string())
        .unwrap_or_else(|| "N/A".to_string());
    println!("  Output Mode:     {}", mode);
    println!("  AC Voltage:      {}", f("internal_ac_voltage"));
    println!("  AC Current:      {}", f("internal_current_one"));
    println!("  AC Power:        {}", f("internal_power_one"));
    println!("  AC Frequency:    {}", f("internal_ac_frequency"));

    println!("\n  --- DC Input Details ---");
    println!("  DC Voltage:      {}", f("internal_dc_input_voltage"));
    println!("  DC Power:        {}", f("internal_dc_input_power"));
    println!("  DC Current:      {}", f("internal_dc_input_current"));

    println!("\n  --- Status ---");
    println!("  AC Output:       {}", f("ac_output_on"));
    println!("  DC Output:       {}", f("dc_output_on"));
    println!("  Total Generated: {}", f("power_generation"));

    println!("\n  --- Battery Pack ---");
    println!("  Packs:           {} / {}", f("pack_num"), f("pack_num_max"));
    println!("  Pack Voltage:    {}", f("pack_voltage"));
    println!("  Pack Battery:    {}", f("pack_battery_percent"));

    println!("\n  --- KPIs ---");
    if kpis.charging_state == 0 {
        println!("  Charging:        Not charging");
    } else {
        let get = |key: &str| readings.get(key).and_then(|r| r.value.as_i64()).unwrap_or(0);
        let inbound = get("dc_input_power") + get("ac_input_power");
        let outbound = get("ac_output_power") + get("dc_output_power");
        println!(
            "  Charging:        {} ({}W in, {}W out) -> Net: {}{}W [{}]",
            CHARGING_STATE_LABELS[kpis.charging_state as usize],
            inbound,
            outbound,
            if kpis.net_power >= 0 { "+" } else { "" },
            kpis.net_power,
            POWER_RATE_LABELS[kpis.power_rate as usize],
        );
    }
    println!("  Battery Range:   {}", BATTERY_RANGE_LABELS[kpis.battery_range as usize]);
}

fn build_row(readings: &Readings, timestamp: &str, kpis: &Kpis) -> Row {
    let cells = CSV_COLUMNS
        .iter()
        .map(|column| match *column {
            "timestamp" => Cell::Text(timestamp.to_string()),
            "elapsed_seconds" => Cell::Int(kpis.elapsed),
            "charging_state" => Cell::Int(kpis.charging_state as i64),
            "battery_range" => Cell::Int(kpis.battery_range as i64),
            "net_power" => Cell::Int(kpis.net_power),
            "power_rate" => Cell::Int(kpis.power_rate as i64),
            name => match readings.get(name).map(|r| &r.value) {
                Some(protocol::Value::Uint(v)) => Cell::Int(*v as i64),
                Some(protocol::Value::Bool(b)) => Cell::Bool(*b),
                Some(protocol::Value::Decimal(v, scale)) => Cell::Dec(*v, *scale),
                Some(protocol::Value::Str(s)) => Cell::Text(s.clone()),
                None => Cell::Null,
            },
        })
        .collect();
    Row { cells }
}

// ── Sinks ────────────────────────────────────────────────────────────────────

struct CsvSink {
    file: std::fs::File,
}

impl CsvSink {
    fn open(path: &str) -> Result<Self> {
        let existing = std::fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false);
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
        if !existing {
            writeln!(file, "{}", CSV_COLUMNS.join(","))?;
            file.flush()?;
        }
        Ok(CsvSink { file })
    }

    fn write(&mut self, row: &Row) -> Result<()> {
        let line: Vec<String> = row.cells.iter().map(Cell::to_csv).collect();
        writeln!(self.file, "{}", line.join(","))?;
        self.file.flush()?;
        Ok(())
    }
}

// ── Session ──────────────────────────────────────────────────────────────────

struct Session<'a> {
    loop_count: u64,
    interval: Duration,
    csv: Option<&'a mut CsvSink>,
    /// Set when MariaDB logging is on. The slot is refilled by `ensure_archive`
    /// whenever the connection is missing or dead, so a database that was down
    /// at startup (or restarts later) does not silence the collector for good.
    db_config: Option<&'a db::Config>,
    archive: &'a mut Option<Archive>,
    shutdown: watch::Receiver<bool>,
}

/// Make `slot` hold a live MariaDB connection, (re)connecting if it is empty or
/// the existing connection no longer answers a ping. Failures leave the slot
/// empty; the next call tries again.
fn ensure_archive(slot: &mut Option<Archive>, config: &db::Config) {
    if let Some(archive) = slot.as_mut() {
        if archive.ping() {
            return;
        }
        eprintln!("  WARNING: MariaDB connection lost, reconnecting");
    }
    *slot = match Archive::connect(config) {
        Ok(mut archive) => {
            if let Err(e) = archive.init_schema() {
                eprintln!("  WARNING: DB init failed: {}", e);
            }
            Some(archive)
        }
        Err(e) => {
            eprintln!("  WARNING: Could not connect to MariaDB: {}", e);
            None
        }
    };
}

/// Resolve on SIGINT or SIGTERM so the BLE link gets released on shutdown
/// instead of being left open for bluetoothd to hold.
fn spawn_shutdown_watch() -> watch::Receiver<bool> {
    let (tx, rx) = watch::channel(false);
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            match signal(SignalKind::terminate()) {
                Ok(mut terminate) => {
                    tokio::select! {
                        _ = tokio::signal::ctrl_c() => {}
                        _ = terminate.recv() => {}
                    }
                }
                Err(_) => {
                    let _ = tokio::signal::ctrl_c().await;
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        eprintln!("\nShutting down, releasing the BLE connection...");
        let _ = tx.send(true);
    });
    rx
}

/// Capture `loop_count` readings, connecting and disconnecting around each one
/// so the device's single BLE slot is free between captures.
async fn read_device(address: &str, session: &mut Session<'_>) -> Result<()> {
    let infinite = session.loop_count == 0;
    let total = if infinite { None } else { Some(session.loop_count) };

    let mut index: u64 = 0;
    let mut last_reading: Option<Instant> = None;

    while infinite || index < session.loop_count {
        if *session.shutdown.borrow() {
            break;
        }

        let cycle_start = Instant::now();
        match capture_once(address, session, index, total, &mut last_reading).await {
            Ok(()) => {}
            // A long-running collector rides out a failed capture and keeps its
            // cadence; a bounded run reports the failure to the caller.
            Err(e) if infinite => eprintln!("  WARNING: capture failed: {}", e),
            Err(e) => return Err(e),
        }

        index += 1;
        if infinite || index < session.loop_count {
            // Sleep the remainder of the period, so connect + read + disconnect
            // time does not push each capture later than the last.
            let remaining = session.interval.saturating_sub(cycle_start.elapsed());
            tokio::select! {
                _ = tokio::time::sleep(remaining) => {}
                _ = session.shutdown.changed() => break,
            }
        }
    }

    Ok(())
}

/// One connect / poll / disconnect cycle.
async fn capture_once(
    address: &str,
    session: &mut Session<'_>,
    index: u64,
    total: Option<u64>,
    last_reading: &mut Option<Instant>,
) -> Result<()> {
    // Only narrate the first cycle; a 60 s collector would otherwise write two
    // connection lines to the journal every minute.
    let announce = index == 0;
    if announce {
        println!("Scanning for {}...", address);
    }
    let peripheral = find_device(address, Duration::from_secs(15)).await?;
    if announce {
        println!("Connecting to {}...", address);
    }
    let link = Link::open(peripheral, announce).await?;

    // The device accepts a single BLE connection, so the link must be released
    // however this cycle ends — success, Modbus failure or I/O error.
    let readings = poll_once(&link).await;
    link.close().await;
    let readings = readings?;

    if readings.is_empty() {
        return Ok(());
    }

    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let now = Instant::now();
    let elapsed = last_reading.map_or(0, |prev| now.duration_since(prev).as_secs() as i64);
    *last_reading = Some(now);

    let kpis = compute_kpis(&readings, elapsed);
    print_reading(&readings, &kpis, index, total);

    let row = build_row(&readings, &timestamp, &kpis);
    if let Some(csv) = session.csv.as_deref_mut() {
        csv.write(&row)?;
    }
    if let Some(config) = session.db_config {
        ensure_archive(session.archive, config);
    }
    if let Some(archive) = session.archive.as_mut() {
        match archive.insert(&row) {
            Ok(()) => println!("  DB INSERT OK: {}", timestamp),
            Err(e) => eprintln!("  WARNING: DB insert failed: {}", e),
        }
    }

    Ok(())
}

async fn write_device(address: &str, register: u16, value: u16) -> Result<bool> {
    let mut peripheral = None;
    for attempt in 1..=5 {
        match find_device(address, Duration::from_secs(10)).await {
            Ok(found) => {
                peripheral = Some(found);
                break;
            }
            Err(_) => {
                println!("  Scan attempt {}/5: device not found, retrying...", attempt);
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        }
    }
    let peripheral =
        peripheral.ok_or_else(|| anyhow!("Device {} not found after 5 scan attempts", address))?;

    println!("Connecting to {}...", address);
    let link = Link::open(peripheral, true).await?;

    let outcome = write_once(&link, register, value).await;
    link.close().await;
    outcome
}

async fn write_once(link: &Link, register: u16, value: u16) -> Result<bool> {
    let command = build_write_command(register, value);
    let outcome = match link.transact(&command, 8).await? {
        None => {
            println!("  ERROR: No response to write command");
            false
        }
        Some(response) if !validate_crc(&response) => {
            println!("  ERROR: Invalid CRC in write response");
            false
        }
        Some(response) if response[1] == 0x86 => {
            println!("  ERROR: Modbus write error, code {}", response[2]);
            false
        }
        Some(response) => {
            let echoed_register = u16::from_be_bytes([response[2], response[3]]);
            let echoed_value = u16::from_be_bytes([response[4], response[5]]);
            if echoed_register == register && echoed_value == value {
                println!("  OK: Register {} set to {}", register, value);
            } else {
                println!(
                    "  WARNING: Echo mismatch (reg={}, val={})",
                    echoed_register, echoed_value
                );
            }
            true
        }
    };

    Ok(outcome)
}

// ── Entry point ──────────────────────────────────────────────────────────────

/// Resolve the target address, scanning first when none was supplied.
async fn resolve_address(cli: &Cli) -> Result<String> {
    if let Some(address) = &cli.address {
        return Ok(address.clone());
    }
    let devices = scan_devices().await?;
    match devices.first() {
        Some((_, address)) => {
            println!("\nAuto-selecting first device: {}", address);
            Ok(address.to_string())
        }
        None => bail!("No device found. Use --address to specify a MAC address."),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let mut write_commands = Vec::new();
    if cli.dc_on {
        write_commands.push((49u16, 1u16, "DC output ON"));
    }
    if cli.dc_off {
        write_commands.push((49, 0, "DC output OFF"));
    }
    if cli.ac_on {
        write_commands.push((48, 1, "AC output ON"));
    }
    if cli.ac_off {
        write_commands.push((48, 0, "AC output OFF"));
    }

    if !write_commands.is_empty() {
        let address = resolve_address(&cli).await?;
        for (register, value, label) in write_commands {
            println!("Sending: {} (register {} = {})", label, register, value);
            match write_device(&address, register, value).await {
                Ok(true) => println!("  {}: success", label),
                Ok(false) => println!("  {}: failed", label),
                Err(e) => println!("  {}: failed ({})", label, e),
            }
        }
        return Ok(());
    }

    // A bare --scan lists devices and stops.
    if cli.scan && cli.address.is_none() {
        scan_devices().await?;
        return Ok(());
    }

    let address = resolve_address(&cli).await?;

    // --csv without explicit pacing means "log all day", as in the Python reader.
    let (mut loop_count, mut interval_secs) = (cli.r#loop, cli.interval);
    if cli.csv.is_some() && cli.r#loop == 1 && cli.interval == 5 {
        loop_count = 1440;
        interval_secs = 60;
    }

    let use_mysql = cli.mysql || cli.csv.is_some();
    let db_config = db::Config::from_env();

    let mut archive: Option<Archive> = None;
    if use_mysql {
        ensure_archive(&mut archive, &db_config);
    }

    let mut csv = match &cli.csv {
        Some(path) => Some(CsvSink::open(path)?),
        None => None,
    };

    let mut targets = Vec::new();
    if let Some(path) = &cli.csv {
        targets.push(path.clone());
    }
    if use_mysql {
        targets.push("MariaDB".to_string());
    }
    if !targets.is_empty() {
        let readings = if loop_count == 0 { "inf".to_string() } else { loop_count.to_string() };
        println!(
            "Logging to {} ({} readings, every {}s)",
            targets.join(" + "),
            readings,
            interval_secs
        );
    }

    let shutdown = spawn_shutdown_watch();

    loop {
        let mut session = Session {
            loop_count,
            interval: Duration::from_secs(interval_secs),
            csv: csv.as_mut(),
            db_config: use_mysql.then_some(&db_config),
            archive: &mut archive,
            shutdown: shutdown.clone(),
        };

        match read_device(&address, &mut session).await {
            Ok(()) => break,
            Err(e) => {
                if *shutdown.borrow() {
                    break;
                }
                eprintln!("\nBLE connection lost: {}", e);
                eprintln!("Reconnecting in 10 seconds...");
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
        }
    }

    Ok(())
}
