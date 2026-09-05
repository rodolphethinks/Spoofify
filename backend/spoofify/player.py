"""
Flask web player for Spoofify.

Routes:
  GET  /                              → URL input form (or redirect if SPOTIFY_URL env set)
  GET  /player?url=<spotify_url>      → load playlist and show the player
  POST /player/<pid>/download/<index> → search YouTube + download track as MP3
  GET  /audio/<filename>              → stream an MP3 with Range support
  GET  /api/stream                    → JSON-free audio proxy for the Android app
"""

import os
import re
from pathlib import Path

import requests as http_requests
from flask import Flask, Response, abort, jsonify, redirect, render_template, request, stream_with_context, url_for

from spoofify import spotify, youtube

app = Flask(__name__, template_folder="templates")

API_KEY = os.environ.get("API_KEY", "").strip()
_VIDEO_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{11}$")

DOWNLOAD_FOLDER = Path(os.environ.get("DOWNLOAD_FOLDER", "downloads"))

# In-memory playlist cache: { playlist_id: {"name": str, "tracks": list[dict]} }
_cache: dict[str, dict] = {}


def _load_playlist(url: str) -> tuple[str, dict]:
    """Fetch (or return cached) playlist. Returns (pid, cache_entry)."""
    _, pid = spotify.parse_spotify_url(url)
    if pid not in _cache:
        name, raw_tracks = spotify.get_tracks(url)
        tracks = []
        for t in raw_tracks:
            safe = youtube._safe_filename(
                f"{t['artists']} - {t['title']}" if t["artists"] else t["title"]
            )
            mp3_path = DOWNLOAD_FOLDER / f"{safe}.mp3"
            tracks.append({
                "title": t["title"],
                "artists": t["artists"],
                "file": safe,
                "ready": mp3_path.exists(),
            })
        _cache[pid] = {"name": name, "tracks": tracks}
    return pid, _cache[pid]


@app.get("/")
def index():
    default_url = os.environ.get("SPOTIFY_URL", "").strip()
    if default_url:
        return redirect(url_for("player_view", url=default_url))
    return render_template("index.html")


@app.get("/player")
def player_view():
    url = request.args.get("url", "").strip()
    if not url:
        return redirect(url_for("index"))
    try:
        pid, data = _load_playlist(url)
    except (ValueError, RuntimeError) as exc:
        return render_template("index.html", error=str(exc)), 400
    return render_template(
        "player.html",
        playlist=data["name"],
        tracks=data["tracks"],
        pid=pid,
    )


@app.get("/player/<pid>/youtube/<int:index>")
def get_youtube_id(pid: str, index: int):
    """Return the YouTube video ID for a track (for IFrame embed streaming)."""
    if pid not in _cache:
        return jsonify(video_id=None, error="Playlist not loaded — reload the page"), 404
    tracks = _cache[pid]["tracks"]
    if index < 0 or index >= len(tracks):
        return jsonify(video_id=None, error="Invalid track index"), 400
    track = tracks[index]
    if track.get("yt_video_id"):
        return jsonify(video_id=track["yt_video_id"])
    vid = youtube.search_youtube_video_id(track["title"], track["artists"])
    if vid:
        track["yt_video_id"] = vid
        return jsonify(video_id=vid)
    return jsonify(video_id=None, error="No YouTube result found")


@app.get("/player/<pid>/stream/<int:index>")
def proxy_stream(pid: str, index: int):
    """Proxy ad-free audio stream via yt-dlp android_vr client."""
    if pid not in _cache:
        abort(404)
    tracks = _cache[pid]["tracks"]
    if index < 0 or index >= len(tracks):
        abort(400)
    track = tracks[index]

    # Serve already-downloaded MP3 directly
    mp3_path = DOWNLOAD_FOLDER / f"{track['file']}.mp3"
    if mp3_path.exists():
        return redirect(url_for("audio", filename=track["file"]))

    # Cache video_id lookup
    if not track.get("yt_video_id"):
        vid = youtube.search_youtube_video_id(track["title"], track["artists"])
        if not vid:
            abort(404)
        track["yt_video_id"] = vid

    stream_url, content_type = youtube.get_stream_url(track["yt_video_id"])
    if not stream_url:
        abort(502)

    def generate():
        with http_requests.get(stream_url, stream=True, timeout=300) as r:
            r.raise_for_status()
            for chunk in r.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk

    return Response(
        stream_with_context(generate()),
        content_type=content_type,
        headers={"Cache-Control": "no-store"},
    )


@app.get("/api/stream")
def api_stream():
    """
    Audio proxy for the Android app (no playlist cache needed).
    Query params: either `video_id` (11-char YouTube ID) or `title`(+`artists`).
    Requires header `X-Api-Key` matching the API_KEY env var, if set.
    """
    if API_KEY and request.headers.get("X-Api-Key", "") != API_KEY:
        abort(401)

    video_id = request.args.get("video_id", "").strip()
    title = request.args.get("title", "").strip()[:200]
    artists = request.args.get("artists", "").strip()[:200]

    if video_id:
        if not _VIDEO_ID_RE.match(video_id):
            abort(400)
    elif title:
        video_id = youtube.search_youtube_video_id(title, artists)
        if not video_id:
            abort(404)
    else:
        abort(400)

    stream_url, content_type = youtube.get_stream_url(video_id)
    if not stream_url:
        abort(502)

    def generate():
        with http_requests.get(stream_url, stream=True, timeout=300, headers=youtube._REQ_HEADERS) as r:
            r.raise_for_status()
            for chunk in r.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk

    return Response(
        stream_with_context(generate()),
        content_type=content_type,
        headers={"Cache-Control": "no-store"},
    )


@app.post("/player/<pid>/download/<int:index>")
def download(pid: str, index: int):
    """Search YouTube and download a track as MP3 on demand."""
    if pid not in _cache:
        return jsonify(ok=False, error="Playlist not loaded — reload the page"), 404
    tracks = _cache[pid]["tracks"]
    if index < 0 or index >= len(tracks):
        return jsonify(ok=False, error="Invalid track index"), 400
    track = tracks[index]
    if track["ready"]:
        return jsonify(ok=True, file=track["file"])
    try:
        yt_url = youtube.search_track_url(track["title"], track["artists"])
        if not yt_url:
            return jsonify(ok=False, error="No YouTube result found")
        youtube.download_mp3(yt_url, DOWNLOAD_FOLDER, track["file"])
        track["ready"] = True
        return jsonify(ok=True, file=track["file"])
    except Exception as exc:
        return jsonify(ok=False, error=str(exc))


@app.get("/audio/<filename>")
def audio(filename: str):
    """Stream an MP3 with HTTP Range support for seeking."""
    safe = Path(filename).name  # prevent path traversal
    path = DOWNLOAD_FOLDER / f"{safe}.mp3"
    if not path.exists():
        abort(404)
    file_size = path.stat().st_size
    range_header = request.headers.get("Range")

    if range_header:
        byte_start, byte_end = 0, file_size - 1
        m = re.search(r"bytes=(\d+)-(\d*)", range_header)
        if m:
            byte_start = int(m.group(1))
            byte_end = int(m.group(2)) if m.group(2) else file_size - 1
        length = byte_end - byte_start + 1

        def stream_range():
            with open(path, "rb") as f:
                f.seek(byte_start)
                remaining = length
                while remaining:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    yield chunk

        return Response(
            stream_range(),
            status=206,
            headers={
                "Content-Range": f"bytes {byte_start}-{byte_end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(length),
                "Content-Type": "audio/mpeg",
            },
        )

    def stream_full():
        with open(path, "rb") as f:
            while chunk := f.read(65536):
                yield chunk

    return Response(
        stream_full(),
        headers={
            "Content-Length": str(file_size),
            "Content-Type": "audio/mpeg",
            "Accept-Ranges": "bytes",
        },
    )

