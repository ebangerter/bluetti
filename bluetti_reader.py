#!/usr/bin/env python3
"""Read current values from a Bluetti AC200MAX over Bluetooth LE."""

import argparse
import asyncio
import csv
import os
import struct
import sys
import time
from decimal import Decimal
from enum import Enum

from bleak import BleakClient, BleakScanner

try:
    import crcmod.predefined

    modbus_crc = crcmod.predefined.mkCrcFun("modbus")
except ImportError:
    print("ERROR: crcmod is required. Install with: pip install crcmod", file=sys.stderr)
    sys.exit(1)

try:
    import pymysql

    pymysql.install_as_MySQLdb()
except ImportError:
    pymysql = None

DB_HOST = os.environ.get("BLUETTI_DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("BLUETTI_DB_PORT", "3390"))
DB_USER = os.environ.get("BLUETTI_DB_USER", "root")
DB_PASSWORD = os.environ.get("BLUETTI_DB_PASSWORD", "kilroy")
DB_NAME = os.environ.get("BLUETTI_DB_NAME", "Bluetti_AC200MAX")


WRITE_UUID = "0000ff02-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000ff01-0000-1000-8000-00805f9b34fb"
DEVICE_NAME_UUID = "00002a00-0000-1000-8000-00805f9b34fb"

RESPONSE_TIMEOUT = 10
MAX_RETRIES = 3

CHARGING_THRESHOLD_W = 5
FAST_CHARGE_THRESHOLD_W = 500
TRICKLE_CHARGE_THRESHOLD_W = 100

OUTPUT_MODES = {0: "STOP", 1: "Inverter", 2: "Bypass C", 3: "Bypass D", 4: "Load Matching"}


def compute_charging_state(dc_input_power, ac_input_power):
    dc_active = dc_input_power > CHARGING_THRESHOLD_W
    ac_active = ac_input_power > CHARGING_THRESHOLD_W
    if dc_active and ac_active:
        return 3
    if dc_active:
        return 1
    if ac_active:
        return 2
    return 0


CHARGING_STATE_LABELS = {0: "None", 1: "DC", 2: "AC", 3: "AC+DC"}


def compute_battery_range(pct):
    if pct is None:
        return None
    if pct <= 25:
        return 0
    if pct <= 50:
        return 1
    if pct <= 75:
        return 2
    return 3


BATTERY_RANGE_LABELS = {0: "0-25%", 1: "25-50%", 2: "50-75%", 3: "75-100%"}


def compute_power_rate(net_power):
    if net_power is None:
        return None
    if net_power < TRICKLE_CHARGE_THRESHOLD_W:
        return 0
    if net_power < FAST_CHARGE_THRESHOLD_W:
        return 1
    return 2


POWER_RATE_LABELS = {0: "Trickle", 1: "Normal", 2: "Fast"}


def compute_net_power(dc_input_power, dc_output_power):
    return dc_input_power - dc_output_power


class Field:
    def __init__(self, name, address, size, unit="", fmt=None):
        self.name = name
        self.address = address
        self.size = size
        self.unit = unit
        self.fmt = fmt

    def parse(self, data):
        raise NotImplementedError


class UintField(Field):
    def __init__(self, name, address, unit="", range_check=None):
        super().__init__(name, address, 1, unit)
        self.range_check = range_check

    def parse(self, data):
        val = struct.unpack("!H", data)[0]
        if self.range_check and (val < self.range_check[0] or val > self.range_check[1]):
            return None
        return val


class BoolField(Field):
    def __init__(self, name, address):
        super().__init__(name, address, 1)

    def parse(self, data):
        return struct.unpack("!H", data)[0] == 1


class DecimalField(Field):
    def __init__(self, name, address, scale, unit="", range_check=None):
        super().__init__(name, address, 1, unit)
        self.scale = scale
        self.range_check = range_check

    def parse(self, data):
        val = struct.unpack("!H", data)[0]
        if self.range_check and (val < self.range_check[0] or val > self.range_check[1]):
            return None
        return Decimal(val) / Decimal(10**self.scale)


class StringField(Field):
    def __init__(self, name, address, size):
        super().__init__(name, address, size)

    def parse(self, data):
        return data.rstrip(b"\0").decode("ascii", errors="replace")


class VersionField(Field):
    def __init__(self, name, address):
        super().__init__(name, address, 2)

    def parse(self, data):
        values = struct.unpack("!2H", data)
        return (values[0] + (values[1] << 16)) / 100


AC200M_FIELDS = [
    StringField("device_type", 10, 6),
    VersionField("arm_version", 23),
    VersionField("dsp_version", 25),
    UintField("dc_input_power", 36, "W"),
    UintField("ac_input_power", 37, "W"),
    UintField("ac_output_power", 38, "W"),
    UintField("dc_output_power", 39, "W"),
    DecimalField("power_generation", 41, 1, "kWh"),
    UintField("total_battery_percent", 43, "%", range_check=(0, 100)),
    BoolField("ac_output_on", 48),
    BoolField("dc_output_on", 49),
    UintField("ac_output_mode", 70),
    UintField("internal_ac_voltage", 71, "V"),
    DecimalField("internal_current_one", 72, 1, "A"),
    UintField("internal_power_one", 73, "W"),
    DecimalField("internal_ac_frequency", 74, 1, "Hz"),
    UintField("internal_dc_input_voltage", 86, "V", range_check=(0, 10000)),
    DecimalField("internal_dc_input_power", 87, 1, "W"),
    DecimalField("internal_dc_input_current", 88, 2, "A"),
    UintField("pack_num_max", 91),
    DecimalField("total_battery_voltage", 92, 2, "V"),
    UintField("pack_num", 96),
    DecimalField("pack_voltage", 98, 2, "V"),
    UintField("pack_battery_percent", 99, "%", range_check=(0, 100)),
]


POLLING_REGISTERS = [
    (10, 40),
    (70, 21),
    (91, 37),
]

CSV_COLUMNS = [
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
]

DB_INSERT_SQL = f"""
INSERT IGNORE INTO readings ({', '.join(CSV_COLUMNS)})
VALUES ({', '.join('%s' for _ in CSV_COLUMNS)})
"""


def db_connect():
    if pymysql is None:
        return None
    try:
        conn = pymysql.connect(
            host=DB_HOST, port=DB_PORT, user=DB_USER,
            password=DB_PASSWORD, database=DB_NAME, charset="utf8mb4",
        )
        return conn
    except Exception as e:
        print(f"  WARNING: Could not connect to MariaDB: {e}", file=sys.stderr)
        return None


def db_init(conn):
    if conn is None:
        return
    try:
        with conn.cursor() as cur:
            cur.execute("""
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
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """)
            cur.execute("CREATE INDEX IF NOT EXISTS idx_readings_timestamp ON readings(timestamp)")
            new_cols = [
                ("elapsed_seconds", "INT"),
                ("charging_state", "TINYINT(1) NOT NULL DEFAULT 0"),
                ("battery_range", "TINYINT(1) NOT NULL DEFAULT 0"),
                ("net_power", "INT"),
                ("power_rate", "TINYINT(1) NOT NULL DEFAULT 0"),
            ]
            for col_name, col_def in new_cols:
                cur.execute(f"ALTER TABLE readings ADD COLUMN IF NOT EXISTS {col_name} {col_def}")
        conn.commit()
        print("  Database schema ready")
    except Exception as e:
        print(f"  WARNING: DB init failed: {e}", file=sys.stderr)


def db_insert_row(conn, row, reading_time=None):
    if conn is None:
        return
    values = []
    for col in CSV_COLUMNS:
        val = row.get(col)
        if isinstance(val, Decimal):
            val = float(val)
        elif isinstance(val, bool):
            val = int(val)
        values.append(val)
    try:
        with conn.cursor() as cur:
            cur.execute(DB_INSERT_SQL, values)
        conn.commit()
        print(f"  DB INSERT OK: {reading_time}")
    except Exception as e:
        print(f"  WARNING: DB insert failed: {e}", file=sys.stderr)


def build_read_command(starting_address, quantity):
    cmd = bytearray(8)
    cmd[0] = 0x01
    cmd[1] = 0x03
    struct.pack_into("!HH", cmd, 2, starting_address, quantity)
    crc = modbus_crc(cmd[:-2])
    struct.pack_into("<H", cmd, 6, crc)
    return bytes(cmd)


def build_write_command(register_address, value):
    cmd = bytearray(8)
    cmd[0] = 0x01
    cmd[1] = 0x06
    struct.pack_into("!HH", cmd, 2, register_address, value)
    crc = modbus_crc(cmd[:-2])
    struct.pack_into("<H", cmd, 6, crc)
    return bytes(cmd)


def expected_response_size(quantity):
    return 2 * quantity + 5


def validate_crc(response):
    if len(response) < 3:
        return False
    crc = modbus_crc(response[:-2])
    crc_bytes = crc.to_bytes(2, byteorder="little")
    return response[-2:] == crc_bytes


def parse_fields(starting_address, data):
    data_size = len(data) // 2
    addr_range = range(starting_address, starting_address + data_size)

    results = {}
    for field in AC200M_FIELDS:
        if field.address not in addr_range:
            continue
        if field.address + field.size - 1 not in addr_range:
            continue

        offset = 2 * (field.address - starting_address)
        field_data = data[offset : offset + 2 * field.size]
        val = field.parse(field_data)
        if val is not None:
            results[field.name] = (val, field.unit if hasattr(field, "unit") else "")

    return results


async def scan():
    print("Scanning for Bluetti devices...")
    devices = await BleakScanner.discover()
    bluetti = [d for d in devices if d.name and d.name.startswith("AC200M")]
    if not bluetti:
        print("No AC200MAX devices found.")
        return []
    for d in bluetti:
        print(f"  {d.name} - {d.address}")
    return bluetti


async def read_device(address, loop_count=1, interval=5, csv_writer=None, csv_file=None, db_conn=None):
    print(f"Scanning for {address}...")
    device = await BleakScanner.find_device_by_address(address, timeout=15)
    if device is None:
        raise RuntimeError(f"Device {address} not found during scan")
    print(f"Connecting to {address}...")

    async with BleakClient(device) as client:
        name = await client.read_gatt_char(DEVICE_NAME_UUID)
        print(f"Connected to: {name.decode('ascii', errors='replace')}")

        response_data = bytearray()

        def notification_handler(_sender, data):
            response_data.extend(data)

        await client.start_notify(NOTIFY_UUID, notification_handler)

        loop = 0
        last_reading_time = None
        while loop < loop_count:
            all_results = {}
            reading_time = time.strftime("%Y-%m-%d %H:%M:%S")
            reading_ts = time.time()

            if last_reading_time is not None:
                elapsed = int(reading_ts - last_reading_time)
            else:
                elapsed = 0
            last_reading_time = reading_ts

            for start_addr, quantity in POLLING_REGISTERS:
                cmd = build_read_command(start_addr, quantity)
                response_data.clear()

                retries = 0
                while retries < MAX_RETRIES:
                    response_data.clear()
                    await client.write_gatt_char(WRITE_UUID, cmd)

                    expected = expected_response_size(quantity)
                    for _ in range(RESPONSE_TIMEOUT * 10):
                        if len(response_data) >= expected:
                            break
                        await asyncio.sleep(0.1)

                    if len(response_data) < expected:
                        retries += 1
                        continue

                    resp = bytes(response_data[:expected])

                    if resp[1] == 0x83:
                        print(f"  MODBUS error for registers {start_addr}+{quantity}: code {resp[2]}")
                        break

                    if not validate_crc(resp):
                        retries += 1
                        continue

                    body = resp[3:-2]
                    parsed = parse_fields(start_addr, body)
                    all_results.update(parsed)
                    break

            if all_results:
                print(f"\n{'='*50}")
                if loop_count > 1:
                    print(f"Reading #{loop + 1} at {time.strftime('%H:%M:%S')}")
                print(f"{'='*50}")

                if "device_type" in all_results:
                    print(f"  Device:          {all_results['device_type'][0]}")
                print(f"  Battery:         {format_val(all_results, 'total_battery_percent')}")
                print(f"  Battery Voltage: {format_val(all_results, 'total_battery_voltage')}")

                print(f"\n  --- Power ---")
                print(f"  AC Input:        {format_val(all_results, 'ac_input_power')}")
                print(f"  DC Input:        {format_val(all_results, 'dc_input_power')}")
                print(f"  AC Output:       {format_val(all_results, 'ac_output_power')}")
                print(f"  DC Output:       {format_val(all_results, 'dc_output_power')}")

                print(f"\n  --- AC Details ---")
                mode = all_results.get("ac_output_mode", (None, ""))[0]
                mode_str = OUTPUT_MODES.get(mode, str(mode)) if mode is not None else "N/A"
                print(f"  Output Mode:     {mode_str}")
                print(f"  AC Voltage:      {format_val(all_results, 'internal_ac_voltage')}")
                print(f"  AC Current:      {format_val(all_results, 'internal_current_one')}")
                print(f"  AC Power:        {format_val(all_results, 'internal_power_one')}")
                print(f"  AC Frequency:    {format_val(all_results, 'internal_ac_frequency')}")

                print(f"\n  --- DC Input Details ---")
                print(f"  DC Voltage:      {format_val(all_results, 'internal_dc_input_voltage')}")
                print(f"  DC Power:        {format_val(all_results, 'internal_dc_input_power')}")
                print(f"  DC Current:      {format_val(all_results, 'internal_dc_input_current')}")

                print(f"\n  --- Status ---")
                ac_on = all_results.get("ac_output_on", (None, ""))[0]
                dc_on = all_results.get("dc_output_on", (None, ""))[0]
                print(f"  AC Output:       {'ON' if ac_on else 'OFF' if ac_on is not None else 'N/A'}")
                print(f"  DC Output:       {'ON' if dc_on else 'OFF' if dc_on is not None else 'N/A'}")
                print(f"  Total Generated: {format_val(all_results, 'power_generation')}")

                print(f"\n  --- Battery Pack ---")
                print(f"  Packs:           {format_val(all_results, 'pack_num')} / {format_val(all_results, 'pack_num_max')}")
                print(f"  Pack Voltage:    {format_val(all_results, 'pack_voltage')}")
                print(f"  Pack Battery:    {format_val(all_results, 'pack_battery_percent')}")

                dc_input = all_results.get("dc_input_power", (0, ""))[0] or 0
                ac_input = all_results.get("ac_input_power", (0, ""))[0] or 0
                dc_output = all_results.get("dc_output_power", (0, ""))[0] or 0
                battery_pct = all_results.get("total_battery_percent", (None, ""))[0]

                net_power = compute_net_power(dc_input, dc_output)
                charging_state = compute_charging_state(dc_input, ac_input)
                battery_range = compute_battery_range(battery_pct)
                power_rate = compute_power_rate(net_power if charging_state > 0 else 0)

                print(f"\n  --- KPIs ---")
                state_label = CHARGING_STATE_LABELS.get(charging_state, "?")
                rate_label = POWER_RATE_LABELS.get(power_rate, "?")
                net_sign = "+" if net_power >= 0 else ""
                if charging_state == 0:
                    print(f"  Charging:        Not charging")
                else:
                    print(f"  Charging:        {state_label} ({dc_input}W in, {dc_output}W out) -> Net: {net_sign}{net_power}W [{rate_label}]")
                range_label = BATTERY_RANGE_LABELS.get(battery_range, "?") if battery_range is not None else "?"
                print(f"  Battery Range:   {range_label}")

            if csv_writer and all_results:
                row = {"timestamp": reading_time}
                for col in CSV_COLUMNS[1:]:
                    if col in all_results:
                        row[col] = all_results[col][0]
                row["elapsed_seconds"] = elapsed
                row["charging_state"] = charging_state
                row["battery_range"] = battery_range if battery_range is not None else 0
                row["net_power"] = net_power
                row["power_rate"] = power_rate if power_rate is not None else 0
                csv_writer.writerow(row)
                csv_file.flush()
                db_insert_row(db_conn, row, reading_time)
            elif db_conn and all_results:
                row = {"timestamp": reading_time}
                for col in CSV_COLUMNS[1:]:
                    if col in all_results:
                        row[col] = all_results[col][0]
                row["elapsed_seconds"] = elapsed
                row["charging_state"] = charging_state
                row["battery_range"] = battery_range if battery_range is not None else 0
                row["net_power"] = net_power
                row["power_rate"] = power_rate if power_rate is not None else 0
                db_insert_row(db_conn, row, reading_time)

            if loop < loop_count - 1:
                await asyncio.sleep(interval)
            loop += 1

        await client.stop_notify(NOTIFY_UUID)


async def write_device(address, register, value):
    device = await BleakScanner.find_device_by_address(address, timeout=15)
    if device is None:
        raise RuntimeError(f"Device {address} not found during scan")
    print(f"Connecting to {address}...")

    async with BleakClient(device) as client:
        response_data = bytearray()

        def notification_handler(_sender, data):
            response_data.extend(data)

        await client.start_notify(NOTIFY_UUID, notification_handler)

        cmd = build_write_command(register, value)
        response_data.clear()
        await client.write_gatt_char(WRITE_UUID, cmd)

        for _ in range(RESPONSE_TIMEOUT * 10):
            if len(response_data) >= 8:
                break
            await asyncio.sleep(0.1)

        if len(response_data) < 8:
            print("  ERROR: No response to write command")
            await client.stop_notify(NOTIFY_UUID)
            return False

        resp = bytes(response_data[:8])
        if not validate_crc(resp):
            print("  ERROR: Invalid CRC in write response")
            await client.stop_notify(NOTIFY_UUID)
            return False

        if resp[1] == 0x86:
            print(f"  ERROR: Modbus write error, code {resp[2]}")
            await client.stop_notify(NOTIFY_UUID)
            return False

        resp_reg = struct.unpack("!H", resp[2:4])[0]
        resp_val = struct.unpack("!H", resp[4:6])[0]
        if resp_reg == register and resp_val == value:
            print(f"  OK: Register {register} set to {value}")
        else:
            print(f"  WARNING: Echo mismatch (reg={resp_reg}, val={resp_val})")

        await client.stop_notify(NOTIFY_UUID)
        return True


def format_val(results, key):
    if key not in results:
        return "N/A"
    val, unit = results[key]
    if isinstance(val, Decimal):
        return f"{val}{unit}"
    if isinstance(val, bool):
        return f"{'ON' if val else 'OFF'}"
    return f"{val}{unit}"


def main():
    parser = argparse.ArgumentParser(description="Read Bluetti AC200MAX data over Bluetooth")
    parser.add_argument("--address", "-a", help="Bluetooth MAC address of the device")
    parser.add_argument("--scan", "-s", action="store_true", help="Scan for Bluetti devices")
    parser.add_argument("--loop", "-l", type=int, default=1, help="Number of readings (default: 1, use 0 for infinite)")
    parser.add_argument("--interval", "-i", type=int, default=5, help="Seconds between readings (default: 5)")
    parser.add_argument("--csv", metavar="FILE", help="Log readings to CSV (defaults: --loop 180 --interval 60)")
    parser.add_argument("--mysql", action="store_true", help="Store readings in MariaDB (auto-enabled when --csv is used)")
    parser.add_argument("--dc-on", action="store_true", help="Turn DC output ON")
    parser.add_argument("--dc-off", action="store_true", help="Turn DC output OFF")
    parser.add_argument("--ac-on", action="store_true", help="Turn AC output ON")
    parser.add_argument("--ac-off", action="store_true", help="Turn AC output OFF")
    args = parser.parse_args()

    write_commands = []
    if args.dc_on:
        write_commands.append((49, 1, "DC output ON"))
    if args.dc_off:
        write_commands.append((49, 0, "DC output OFF"))
    if args.ac_on:
        write_commands.append((48, 1, "AC output ON"))
    if args.ac_off:
        write_commands.append((48, 0, "AC output OFF"))

    if write_commands:
        if args.scan or not args.address:
            devices = asyncio.run(scan())
            if not args.address and devices:
                args.address = devices[0].address
                print(f"\nAuto-selecting first device: {args.address}")
            elif not args.address:
                print("\nNo device found. Use --address to specify a MAC address.")
                sys.exit(1)
        for reg, val, label in write_commands:
            print(f"Sending: {label} (register {reg} = {val})")
            ok = asyncio.run(write_device(args.address, reg, val))
            if ok:
                print(f"  {label}: success")
            else:
                print(f"  {label}: failed")
        return

    if args.scan or not args.address:
        devices = asyncio.run(scan())
        if not args.address and devices:
            args.address = devices[0].address
            print(f"\nAuto-selecting first device: {args.address}")
        elif not args.address:
            print("\nNo device found. Use --address to specify a MAC address.")
            sys.exit(1)

    loop_count = float("inf") if args.loop == 0 else args.loop
    interval = args.interval

    csv_writer = None
    csv_file = None
    db_conn = None

    use_mysql = args.mysql or bool(args.csv)

    if use_mysql:
        db_conn = db_connect()
        if db_conn:
            db_init(db_conn)

    if args.csv:
        import os

        if args.loop == 1 and interval == 5:
            loop_count = 1440
            interval = 60
        file_exists = os.path.isfile(args.csv) and os.path.getsize(args.csv) > 0
        csv_file = open(args.csv, "a", newline="")
        csv_writer = csv.DictWriter(csv_file, fieldnames=CSV_COLUMNS)
        if not file_exists:
            csv_writer.writeheader()
            csv_file.flush()

    targets = []
    if args.csv:
        targets.append(args.csv)
    if db_conn:
        targets.append("MariaDB")
    if targets:
        print(f"Logging to {' + '.join(targets)} ({loop_count} readings, every {interval}s)")

    try:
        while True:
            try:
                asyncio.run(read_device(args.address, loop_count, interval, csv_writer, csv_file, db_conn))
                break
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception as e:
                print(f"\nBLE connection lost: {e}", file=sys.stderr)
                print("Reconnecting in 10 seconds...", file=sys.stderr)
                time.sleep(10)
                if use_mysql:
                    try:
                        if db_conn:
                            db_conn.ping(reconnect=True)
                        else:
                            db_conn = db_connect()
                            if db_conn:
                                db_init(db_conn)
                    except Exception:
                        db_conn = db_connect()
                        if db_conn:
                            db_init(db_conn)
    finally:
        if db_conn:
            db_conn.close()
        if csv_file:
            csv_file.close()


if __name__ == "__main__":
    main()
