FROM python:3.11-slim

# Install ffmpeg (required for yt-dlp MP3 conversion)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install uv
RUN pip install --no-cache-dir uv

# Install Python deps (cached layer — only re-runs when lock file changes)
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --frozen --no-dev

# Copy backend source only (Flutter app lives alongside it in the repo, not needed here)
COPY backend/ .

ENV DOWNLOAD_FOLDER=/tmp/spoofify

# Gunicorn: 1 worker (in-memory cache), gthread for concurrent audio streaming + downloads
CMD .venv/bin/gunicorn "spoofify.player:app" \
    --bind "0.0.0.0:${PORT:-8000}" \
    --workers 1 \
    --worker-class gthread \
    --threads 4 \
    --timeout 300
