pkill -f "bun run server.ts" 2>/dev/null
sleep 0.5
export BLUETTI_MAC=CF:DD:53:11:F4:72
bun run server.ts &
