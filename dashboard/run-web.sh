PORT=5000
UID_NUM="$(id -u)"

pkill -u "$UID_NUM" -f "bun run server.ts" 2>/dev/null

for i in $(seq 1 20); do
    pgrep -u "$UID_NUM" -f "bun run server.ts" >/dev/null || ss -ltn "( sport = :$PORT )" | grep -q ":$PORT" || break
    sleep 0.25
done

if pgrep -u "$UID_NUM" -f "bun run server.ts" >/dev/null; then
    echo "run-web.sh: old server.ts still alive after 5s, force killing"
    pkill -9 -u "$UID_NUM" -f "bun run server.ts" 2>/dev/null
    sleep 0.5
fi

export BLUETTI_MAC=CF:DD:53:11:F4:72
bun run server.ts &
