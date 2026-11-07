# bluetti-reader (Rust)

A Rust port of `bluetti_reader.py`: reads the Bluetti AC200MAX over Bluetooth LE using
Modbus-over-BLE and writes the result to stdout, a CSV file and the MariaDB `readings` table.
Same register map, same CSV columns, same KPI definitions, same CLI flags.

## Build

    cd rust
    cargo build --release

The binary lands at `rust/target/release/bluetti-reader`. It is a single static-ish executable
with no Python, no venv and no runtime dependency beyond BlueZ and the system Bluetooth stack.

## Run

    # scan for devices
    ./target/release/bluetti-reader --scan

    # one reading, printed only
    ./target/release/bluetti-reader -a CF:DD:53:11:F4:72 --loop 1

    # continuous collector: forever, every 60 s, into CSV and MariaDB
    ./target/release/bluetti-reader -a CF:DD:53:11:F4:72 \
        --csv ../data.csv --mysql --loop 0 --interval 60

    # switch the outputs
    ./target/release/bluetti-reader -a CF:DD:53:11:F4:72 --ac-off
    ./target/release/bluetti-reader -a CF:DD:53:11:F4:72 --dc-on

`--loop 0` means forever. `--csv` without explicit pacing implies `--loop 1440 --interval 60`,
and turns on the MariaDB sink, exactly as the Python version does.

## Database

Connection comes from the environment, with the same defaults as the Python reader:

| Variable | Default |
|---|---|
| `BLUETTI_DB_HOST` | `127.0.0.1` |
| `BLUETTI_DB_PORT` | `3390` |
| `BLUETTI_DB_USER` | `root` |
| `BLUETTI_DB_PASSWORD` | `kilroy` |
| `BLUETTI_DB_NAME` | `Bluetti_AC200MAX` |

The table and its later-added columns are created on startup if missing, and inserts use
`INSERT IGNORE` keyed on the unique `timestamp`, so running this alongside an existing archive
is safe. A database that is unreachable degrades to a warning — readings still print and still
reach the CSV.

## Layout

    src/protocol.rs   CRC, frame building, register map, field decoding, KPI maths (unit tested)
    src/db.rs         MariaDB schema bootstrap and inserts
    src/main.rs       CLI, BLE transport, output formatting, polling loop

    cargo test        10 unit tests covering CRC, framing, decoding and KPI classification

## Running it as a service

`systemd/bluetti-reader.service` is a **user** unit — BLE, the MariaDB container and the DMS
widget all live in your user session, and lingering is already enabled so it survives logout.

    systemctl --user enable --now ~/DEV/bluetti/rust/systemd/bluetti-reader.service
    systemctl --user status bluetti-reader
    journalctl --user -u bluetti-reader -f

It polls every 60 s into MariaDB (`--mysql --loop 0 --interval 60`). CSV is deliberately off:
`data.csv` still carries the old 19-column header and appending 24-column rows would corrupt it.

Settings come from `Environment=` lines in the unit; override any of them without editing the
unit by writing `~/.config/bluetti/collector.env`:

    BLUETTI_MAC=CF:DD:53:11:F4:72
    BLUETTI_DB_PORT=3390

`Restart=always` with `RestartSec=15` covers Bluetooth or the database not being up yet.
`TimeoutStopSec=120` is deliberate: a stop must leave the reader room to finish its current
Modbus cycle and disconnect, because a SIGKILL would strand the link (see below).

Do not run this service and `bluetti_reader.py` at the same time — one connection, one client.

## Releasing the BLE link

The AC200MAX accepts exactly one BLE connection, and on Linux the ACL link is owned by
`bluetoothd`, not by this process — killing the reader with SIGKILL leaves the device showing
`Connected: yes` in `bluetoothctl info` indefinitely, blocking the phone app and any other client.

The link is therefore held only for the duration of a capture. Each cycle is
scan → connect → read the three register blocks → disconnect, so between captures the device's
single connection slot is free for the phone app or anything else. At `--interval 60` that is
roughly 4 s connected and 56 s idle.

It is also released on every exit path:

- normal completion, Modbus failure and I/O error all run through `link.close()`
  (`unsubscribe` + `disconnect`) in `capture_once` / `write_device`;
- SIGINT and SIGTERM set a shutdown flag that breaks the polling loop at the next safe point,
  so `systemctl stop` or Ctrl-C disconnects cleanly rather than orphaning the connection.

A `kill -9` still cannot be intercepted. If that happens, clear it by hand:

    bluetoothctl disconnect CF:DD:53:11:F4:72

## Differences from the Python reader

- One BLE connection is held only for the duration of each capture (connect, read, disconnect),
  not for the whole session as in Python; the device still accepts a single connection, so never
  run this and `bluetti_reader.py` at the same time.
- Decimal rendering reproduces Python's `Decimal` normalisation (600/10 prints as `60`, not
  `60.0`) so CSV output is byte-comparable.
- Timestamps are host-local, matching the Python writer — note the MariaDB container runs on UTC.
