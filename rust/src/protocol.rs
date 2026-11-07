//! Modbus-over-BLE framing and the AC200MAX register map.

use std::collections::HashMap;

pub const CHARGING_THRESHOLD_W: i64 = 5;
pub const FAST_CHARGE_THRESHOLD_W: i64 = 500;
pub const TRICKLE_CHARGE_THRESHOLD_W: i64 = 100;

/// Register blocks the reader polls, as (starting address, quantity).
pub const POLLING_REGISTERS: [(u16, u16); 3] = [(10, 40), (70, 21), (91, 37)];

pub const CSV_COLUMNS: [&str; 24] = [
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
    "elapsed_seconds",
    "charging_state",
    "battery_range",
    "net_power",
    "power_rate",
];

pub fn output_mode_label(mode: u16) -> &'static str {
    match mode {
        0 => "STOP",
        1 => "Inverter",
        2 => "Bypass C",
        3 => "Bypass D",
        4 => "Load Matching",
        _ => "?",
    }
}

pub const CHARGING_STATE_LABELS: [&str; 4] = ["None", "DC", "AC", "AC+DC"];
pub const BATTERY_RANGE_LABELS: [&str; 4] = ["0-25%", "25-50%", "50-75%", "75-100%"];
pub const POWER_RATE_LABELS: [&str; 3] = ["Trickle", "Normal", "Fast"];

pub fn compute_charging_state(dc_input_power: i64, ac_input_power: i64) -> u8 {
    let dc_active = dc_input_power > CHARGING_THRESHOLD_W;
    let ac_active = ac_input_power > CHARGING_THRESHOLD_W;
    match (dc_active, ac_active) {
        (true, true) => 3,
        (true, false) => 1,
        (false, true) => 2,
        (false, false) => 0,
    }
}

pub fn compute_battery_range(pct: Option<i64>) -> Option<u8> {
    let pct = pct?;
    Some(match pct {
        p if p <= 25 => 0,
        p if p <= 50 => 1,
        p if p <= 75 => 2,
        _ => 3,
    })
}

pub fn compute_power_rate(net_power: i64) -> u8 {
    if net_power < TRICKLE_CHARGE_THRESHOLD_W {
        0
    } else if net_power < FAST_CHARGE_THRESHOLD_W {
        1
    } else {
        2
    }
}

/// Everything flowing in minus everything flowing out.
pub fn compute_net_power(
    dc_input_power: i64,
    ac_input_power: i64,
    ac_output_power: i64,
    dc_output_power: i64,
) -> i64 {
    (dc_input_power + ac_input_power) - (ac_output_power + dc_output_power)
}

// ── CRC ──────────────────────────────────────────────────────────────────────

/// CRC-16/MODBUS: reflected, polynomial 0xA001, initial value 0xFFFF.
pub fn modbus_crc(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &byte in data {
        crc ^= byte as u16;
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xA001;
            } else {
                crc >>= 1;
            }
        }
    }
    crc
}

pub fn build_read_command(starting_address: u16, quantity: u16) -> [u8; 8] {
    let mut cmd = [0u8; 8];
    cmd[0] = 0x01;
    cmd[1] = 0x03;
    cmd[2..4].copy_from_slice(&starting_address.to_be_bytes());
    cmd[4..6].copy_from_slice(&quantity.to_be_bytes());
    let crc = modbus_crc(&cmd[..6]);
    cmd[6..8].copy_from_slice(&crc.to_le_bytes());
    cmd
}

pub fn build_write_command(register_address: u16, value: u16) -> [u8; 8] {
    let mut cmd = [0u8; 8];
    cmd[0] = 0x01;
    cmd[1] = 0x06;
    cmd[2..4].copy_from_slice(&register_address.to_be_bytes());
    cmd[4..6].copy_from_slice(&value.to_be_bytes());
    let crc = modbus_crc(&cmd[..6]);
    cmd[6..8].copy_from_slice(&crc.to_le_bytes());
    cmd
}

pub fn expected_response_size(quantity: u16) -> usize {
    2 * quantity as usize + 5
}

pub fn validate_crc(response: &[u8]) -> bool {
    if response.len() < 3 {
        return false;
    }
    let split = response.len() - 2;
    modbus_crc(&response[..split]).to_le_bytes() == response[split..]
}

// ── Field map ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
pub enum Kind {
    Uint { range: Option<(u16, u16)> },
    Bool,
    Decimal { scale: u32, range: Option<(u16, u16)> },
    Str,
    Version,
}

pub struct Field {
    pub name: &'static str,
    pub address: u16,
    pub size: u16,
    pub unit: &'static str,
    pub kind: Kind,
}

const fn uint(name: &'static str, address: u16, unit: &'static str) -> Field {
    Field { name, address, size: 1, unit, kind: Kind::Uint { range: None } }
}

const fn uint_ranged(
    name: &'static str,
    address: u16,
    unit: &'static str,
    range: (u16, u16),
) -> Field {
    Field { name, address, size: 1, unit, kind: Kind::Uint { range: Some(range) } }
}

const fn boolean(name: &'static str, address: u16) -> Field {
    Field { name, address, size: 1, unit: "", kind: Kind::Bool }
}

const fn decimal(name: &'static str, address: u16, scale: u32, unit: &'static str) -> Field {
    Field { name, address, size: 1, unit, kind: Kind::Decimal { scale, range: None } }
}

pub const AC200M_FIELDS: &[Field] = &[
    Field { name: "device_type", address: 10, size: 6, unit: "", kind: Kind::Str },
    Field { name: "arm_version", address: 23, size: 2, unit: "", kind: Kind::Version },
    Field { name: "dsp_version", address: 25, size: 2, unit: "", kind: Kind::Version },
    uint("dc_input_power", 36, "W"),
    uint("ac_input_power", 37, "W"),
    uint("ac_output_power", 38, "W"),
    uint("dc_output_power", 39, "W"),
    decimal("power_generation", 41, 1, "kWh"),
    uint_ranged("total_battery_percent", 43, "%", (0, 100)),
    boolean("ac_output_on", 48),
    boolean("dc_output_on", 49),
    uint("ac_output_mode", 70, ""),
    uint("internal_ac_voltage", 71, "V"),
    decimal("internal_current_one", 72, 1, "A"),
    uint("internal_power_one", 73, "W"),
    decimal("internal_ac_frequency", 74, 1, "Hz"),
    uint_ranged("internal_dc_input_voltage", 86, "V", (0, 10000)),
    decimal("internal_dc_input_power", 87, 1, "W"),
    decimal("internal_dc_input_current", 88, 2, "A"),
    uint("pack_num_max", 91, ""),
    decimal("total_battery_voltage", 92, 2, "V"),
    uint("pack_num", 96, ""),
    decimal("pack_voltage", 98, 2, "V"),
    uint_ranged("pack_battery_percent", 99, "%", (0, 100)),
];

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Uint(u16),
    Bool(bool),
    /// Fixed-point value plus the number of decimal places it was scaled by.
    Decimal(f64, u32),
    Str(String),
}

impl Value {
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Value::Uint(v) => Some(*v as i64),
            Value::Bool(b) => Some(*b as i64),
            Value::Decimal(v, _) => Some(v.round() as i64),
            Value::Str(_) => None,
        }
    }
}

pub struct Reading {
    pub value: Value,
    pub unit: &'static str,
}

pub type Readings = HashMap<&'static str, Reading>;

fn be_u16(bytes: &[u8]) -> u16 {
    u16::from_be_bytes([bytes[0], bytes[1]])
}

fn parse_field(field: &Field, data: &[u8]) -> Option<Value> {
    match field.kind {
        Kind::Uint { range } => {
            let v = be_u16(data);
            match range {
                Some((lo, hi)) if v < lo || v > hi => None,
                _ => Some(Value::Uint(v)),
            }
        }
        Kind::Bool => Some(Value::Bool(be_u16(data) == 1)),
        Kind::Decimal { scale, range } => {
            let v = be_u16(data);
            match range {
                Some((lo, hi)) if v < lo || v > hi => None,
                _ => Some(Value::Decimal(v as f64 / 10f64.powi(scale as i32), scale)),
            }
        }
        Kind::Str => {
            let end = data.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
            Some(Value::Str(String::from_utf8_lossy(&data[..end]).into_owned()))
        }
        Kind::Version => {
            let lo = be_u16(&data[0..2]) as u32;
            let hi = be_u16(&data[2..4]) as u32;
            Some(Value::Decimal((lo + (hi << 16)) as f64 / 100.0, 2))
        }
    }
}

/// Decode every field that falls entirely inside the returned register block.
pub fn parse_fields(starting_address: u16, data: &[u8], out: &mut Readings) {
    let registers = (data.len() / 2) as u16;
    let last = starting_address + registers;

    for field in AC200M_FIELDS {
        if field.address < starting_address || field.address >= last {
            continue;
        }
        if field.address + field.size > last {
            continue;
        }

        let offset = 2 * (field.address - starting_address) as usize;
        let slice = &data[offset..offset + 2 * field.size as usize];
        if let Some(value) = parse_field(field, slice) {
            out.insert(field.name, Reading { value, unit: field.unit });
        }
    }
}

/// Render a fixed-point value the way Python's `Decimal` division does: exact
/// digits only, with trailing zeros normalised away (600/10 prints as "60").
pub fn format_decimal(value: f64, scale: u32) -> String {
    let mut text = format!("{:.*}", scale as usize, value);
    if text.contains('.') {
        text = text.trim_end_matches('0').trim_end_matches('.').to_string();
    }
    text
}

/// Render a value the way the Python reader prints it.
pub fn format_value(readings: &Readings, key: &str) -> String {
    let Some(reading) = readings.get(key) else {
        return "N/A".to_string();
    };
    match &reading.value {
        Value::Uint(v) => format!("{}{}", v, reading.unit),
        Value::Bool(b) => (if *b { "ON" } else { "OFF" }).to_string(),
        Value::Decimal(v, scale) => format!("{}{}", format_decimal(*v, *scale), reading.unit),
        Value::Str(s) => format!("{}{}", s, reading.unit),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_matches_modbus_reference() {
        // Known CRC-16/MODBUS check value for the ASCII string "123456789".
        assert_eq!(modbus_crc(b"123456789"), 0x4B37);
    }

    #[test]
    fn read_command_is_well_formed() {
        let cmd = build_read_command(10, 40);
        assert_eq!(&cmd[..6], &[0x01, 0x03, 0x00, 0x0A, 0x00, 0x28]);
        assert!(validate_crc(&cmd));
    }

    #[test]
    fn write_command_is_well_formed() {
        let cmd = build_write_command(49, 1);
        assert_eq!(&cmd[..6], &[0x01, 0x06, 0x00, 0x31, 0x00, 0x01]);
        assert!(validate_crc(&cmd));
    }

    #[test]
    fn response_size_matches_quantity() {
        assert_eq!(expected_response_size(40), 85);
        assert_eq!(expected_response_size(21), 47);
    }

    #[test]
    fn parses_a_register_block() {
        // Registers 36..=43: dc_in 815, ac_in 0, ac_out 132, dc_out 5,
        // unused, power_generation 0, unused, battery 35.
        let mut body = Vec::new();
        for v in [815u16, 0, 132, 5, 0, 0, 0, 35] {
            body.extend_from_slice(&v.to_be_bytes());
        }
        let mut readings = Readings::new();
        parse_fields(36, &body, &mut readings);

        assert_eq!(readings["dc_input_power"].value, Value::Uint(815));
        assert_eq!(readings["ac_output_power"].value, Value::Uint(132));
        assert_eq!(readings["total_battery_percent"].value, Value::Uint(35));
        assert_eq!(format_value(&readings, "dc_input_power"), "815W");
    }

    #[test]
    fn out_of_range_values_are_dropped() {
        // total_battery_percent = 255 is outside 0..=100 and must be discarded.
        let mut body = Vec::new();
        for v in [0u16, 0, 0, 0, 0, 0, 0, 255] {
            body.extend_from_slice(&v.to_be_bytes());
        }
        let mut readings = Readings::new();
        parse_fields(36, &body, &mut readings);
        assert!(!readings.contains_key("total_battery_percent"));
    }

    #[test]
    fn decimal_scaling_and_formatting() {
        let mut body = Vec::new();
        // Register 92 is total_battery_voltage with scale 2.
        body.extend_from_slice(&5493u16.to_be_bytes());
        let mut readings = Readings::new();
        parse_fields(92, &body, &mut readings);
        assert_eq!(format_value(&readings, "total_battery_voltage"), "54.93V");
    }

    #[test]
    fn decimals_drop_trailing_zeros_like_python() {
        // Python's Decimal(600)/Decimal(10) renders as "60", not "60.0".
        assert_eq!(format_decimal(60.0, 1), "60");
        assert_eq!(format_decimal(0.0, 1), "0");
        assert_eq!(format_decimal(0.5, 1), "0.5");
        assert_eq!(format_decimal(816.7, 1), "816.7");
        assert_eq!(format_decimal(54.93, 2), "54.93");
        assert_eq!(format_decimal(54.90, 2), "54.9");
    }

    #[test]
    fn net_power_counts_both_sides() {
        assert_eq!(compute_net_power(440, 0, 146, 8), 286);
        assert_eq!(compute_net_power(0, 0, 180, 12), -192);
    }

    #[test]
    fn kpi_classification() {
        assert_eq!(compute_charging_state(815, 0), 1);
        assert_eq!(compute_charging_state(0, 400), 2);
        assert_eq!(compute_charging_state(815, 400), 3);
        assert_eq!(compute_charging_state(0, 0), 0);
        assert_eq!(compute_battery_range(Some(35)), Some(1));
        assert_eq!(compute_power_rate(61), 0);
        assert_eq!(compute_power_rate(286), 1);
        assert_eq!(compute_power_rate(810), 2);
    }
}
