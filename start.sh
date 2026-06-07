#!/bin/bash
# SaveVision — start everything with one command.
#   ./start.sh
# Starts the local server (serves all views) and opens the landing page.
set -e
cd "$(dirname "$0")/operator-web"

# install the single dependency (ws) if needed — npm or yarn, whichever you use
if [ ! -d node_modules ]; then
  if command -v npm >/dev/null 2>&1; then npm install --no-audit --no-fund
  elif command -v yarn >/dev/null 2>&1; then yarn install
  fi
fi

# stop any old instance, then start fresh in the background
pkill -f "node server.js" 2>/dev/null || true
PORT="${PORT:-8080}" node server.js &
SERVER_PID=$!
sleep 1.5

URL="http://localhost:${PORT:-8080}/landing.html"
echo "SaveVision running → $URL  (server pid $SERVER_PID; stop with: kill $SERVER_PID)"

# open the landing page (macOS: open, Linux: xdg-open)
if command -v open >/dev/null 2>&1; then open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL"
fi

# keep the server in the foreground so Ctrl+C stops it
wait $SERVER_PID
