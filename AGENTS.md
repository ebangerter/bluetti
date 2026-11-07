# Bluetti Reader

Single-file Python script (`bluetti_reader.py`) that reads data from a Bluetti AC200MAX over Bluetooth LE using Modbus-over-BLE.

## Dependencies

- `bleak` — BLE client library
- `crcmod` — Modbus CRC calculation (mandatory; script exits if missing)

Install: `pip install bleak crcmod`

## Running

```bash
# Scan for devices
python bluetti_reader.py --scan

# Read once from a specific MAC
python bluetti_reader.py --address <MAC>

# Continuous polling every 10 seconds
python bluetti_reader.py -a <MAC> --loop 0 --interval 10
```

## Rust port

`rust/` holds `bluetti-reader`, a Rust binary with the same register map, CSV columns, KPI
definitions and CLI flags. Build with `cargo build --release` (binary at
`rust/target/release/bluetti-reader`), test with `cargo test`. See `rust/README.md`.

The live collector is the systemd **user** unit `bluetti-reader.service`
(`rust/systemd/bluetti-reader.service`), polling into MariaDB every 60 s:

```bash
systemctl --user status bluetti-reader
journalctl --user -u bluetti-reader -f
```

Stop it before running any other reader — the device accepts one BLE connection.

## Notes

- Requires a Bluetooth adapter with BLE support on the host machine.
- Communicates via BLE GATT characteristics (`ff01`/`ff02`) using Modbus RTU framing.
- The device accepts ONE BLE connection — never run the Python and Rust readers at once.
- Protocol details (register addresses, field types) are hardcoded in `AC200M_FIELDS` and `POLLING_REGISTERS`.
- `net_power` is `(dc_in + ac_in) - (ac_out + dc_out)`; `power_rate` is derived from it.
