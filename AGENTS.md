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

## Notes

- Requires a Bluetooth adapter with BLE support on the host machine.
- Communicates via BLE GATT characteristics (`ff01`/`ff02`) using Modbus RTU framing.
- No tests, no build step, no virtual environment configuration in repo.
- Protocol details (register addresses, field types) are hardcoded in `AC200M_FIELDS` and `POLLING_REGISTERS`.
