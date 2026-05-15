#!/bin/sh
set -e

echo "Starting dashboard on port 5000..."
cd /app/dashboard
bun run server.ts &

MAC_ARG=""
if [ -n "$BLUETTI_MAC" ]; then
    MAC_ARG="--address $BLUETTI_MAC"
fi

echo "Starting bluetti_reader with args: $@ $MAC_ARG"
PYTHONUNBUFFERED=1 python3 /app/bluetti_reader.py $MAC_ARG "$@" || echo "Reader exited (will retry on restart)"

wait
