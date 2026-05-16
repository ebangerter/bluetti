pkill -f "bun run server.ts" 2>/dev/null
sleep 0.5
bun run server.ts &
