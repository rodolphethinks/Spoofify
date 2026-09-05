#!/bin/sh
# Start the local PO-Token provider server (bypasses YouTube's datacenter-IP
# bot-check for yt-dlp) in the background, then run the Flask app.
# --host is required: without it the server binds IPv6-only ([::]), but the
# yt-dlp plugin connects via IPv4 (127.0.0.1), so the token fetch silently
# fails and yt-dlp falls back to no-token requests (bot-check errors).
node /opt/bgutil-pot/build/main.js --port 4416 --host 127.0.0.1 &
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
