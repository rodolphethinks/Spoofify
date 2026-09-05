# --- Stage 1: build the bgutil PO-Token provider server (Node/TypeScript) ---
# This lets yt-dlp bypass YouTube's "Sign in to confirm you're not a bot"
# check that datacenter IPs (like Render's) hit even with android_vr.
# https://github.com/Brainicism/bgutil-ytdlp-pot-provider
FROM node:20-slim AS potbuilder
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --single-branch --branch 1.3.2 --depth 1 \
    https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /pot
WORKDIR /pot/server
RUN npm ci && npx tsc

# --- Stage 2: the actual app image ---
FROM python:3.11-slim

# ffmpeg (yt-dlp MP3 conversion) + Node.js runtime (to run the built POT server)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install uv
RUN pip install --no-cache-dir uv

# Install Python deps (cached layer — only re-runs when lock file changes)
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --frozen --no-dev

# Copy backend source only (Flutter app lives alongside it in the repo, not needed here)
COPY backend/ .
RUN chmod +x start.sh

# Built PO-Token provider server from stage 1
COPY --from=potbuilder /pot/server/build /opt/bgutil-pot/build
COPY --from=potbuilder /pot/server/node_modules /opt/bgutil-pot/node_modules

ENV DOWNLOAD_FOLDER=/tmp/spoofify

CMD ["./start.sh"]
