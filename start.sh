#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PIDFILE="/tmp/bluetti_reader.pid"

if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
    echo "Bluetti reader already running with PID $(cat "$PIDFILE")"
    exit 0
fi

echo "Starting MariaDB database..."
docker compose up -d db

echo "Waiting for database to be ready..."
timeout 30 bash -c 'until docker exec bluetti-db-1 mariadb -uroot -pkilroy -e "SELECT 1" >/dev/null 2>&1; do sleep 2; done' || {
    echo "WARNING: Database may not be ready, continuing anyway..."
}

if bluetoothctl info CF:DD:53:11:F4:72 2>/dev/null | grep -q "Connected: yes"; then
    echo "Disconnecting Bluetti device first (required for bleak to scan)..."
    bluetoothctl disconnect CF:DD:53:11:F4:72 2>/dev/null || true
    sleep 5
fi

echo "Starting Bluetti reader in background..."
nohup setsid python3 "$SCRIPT_DIR/bluetti_reader.py" \
    -a CF:DD:53:11:F4:72 \
    --csv "$SCRIPT_DIR/data.csv" \
    --mysql \
    --loop 0 \
    --interval 60 \
    </dev/null >"$SCRIPT_DIR/bluetti.log" 2>&1 &
echo $! > "$PIDFILE"
echo "Started with PID $(cat $PIDFILE)"