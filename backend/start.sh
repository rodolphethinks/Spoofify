#!/bin/sh
# Start the local PO-Token provider server (bypasses YouTube's datacenter-IP
# bot-check for yt-dlp) in the background, then run the Flask app.
node /opt/bgutil-pot/build/main.js --port 4416 &
POT_PID=$!

cleanup() {
  kill "$POT_PID" 2>/dev/null
}
trap cleanup TERM INT

exec .venv/bin/gunicorn "spoofify.player:app" \
    --bind "0.0.0.0:${PORT:-8000}" \
    --workers 1 \
    --worker-class gthread \
    --threads 4 \
    --timeout 300
