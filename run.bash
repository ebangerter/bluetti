#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="/tmp/bluetti_reader.pid"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Bluetti reader already running with PID $(cat "$PIDFILE")"
    exit 0
fi

nohup python3 "$SCRIPT_DIR/bluetti_reader.py" \
    -a CF:DD:53:11:F4:72 \
    --csv "$SCRIPT_DIR/data.csv" \
    --mysql \
    --loop 0 \
    --interval 60 \
    </dev/null >"$SCRIPT_DIR/bluetti.log" 2>&1 &

echo $! > "$PIDFILE"
echo "Started Bluetti reader with PID $(cat "$PIDFILE")"
