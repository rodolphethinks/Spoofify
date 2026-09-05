"""
Search for a track via Invidious (open-source YouTube frontend, no bot-detection),
with SoundCloud and YouTube as fallbacks. Downloads as MP3.
"""

import os
import re
import subprocess
import tempfile
import unicodedata
from pathlib import Path

import requests
import yt_dlp

# ---------------------------------------------------------------------------
# Invidious – primary source on server environments (bypasses YT bot-detection)
# ---------------------------------------------------------------------------

_INVIDIOUS_INSTANCES = [
    "https://invidious.io.lol",
    "https://inv.nadeko.net",
    "https://iv.datura.network",
    "https://invidious.privacyredirect.com",
    "https://invidious.nerdvpn.de",
]

_REQ_HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; spoofify/1.0)"}


def _search_invidious(query: str) -> str | None:
    """
    Search via public Invidious API instances.
    Returns a direct audio stream URL (googlevideo.com) on success, else None.
    """
    for instance in _INVIDIOUS_INSTANCES:
        try:
            r = requests.get(
                f"{instance}/api/v1/search",
                params={"q": query, "type": "video"},
                headers=_REQ_HEADERS,
                timeout=8,
            )
            if r.status_code != 200:
                continue
            results = r.json()
            if not results:
                continue
            video_id = results[0].get("videoId")
            if not video_id:
                continue
            print(f"[spoofify] Invidious videoId={video_id} via {instance}", flush=True)

            r2 = requests.get(
                f"{instance}/api/v1/videos/{video_id}",
                headers=_REQ_HEADERS,
                timeout=8,
            )
            if r2.status_code != 200:
                continue
            data = r2.json()

            # Prefer audio-only adaptive streams
            adaptive = data.get("adaptiveFormats", [])
            audio_streams = [f for f in adaptive if "audio" in f.get("type", "")]
            if audio_streams:
                audio_streams.sort(key=lambda x: x.get("bitrate", 0), reverse=True)
                url = audio_streams[0].get("url")
                if url:
                    print("[spoofify] Invidious audio stream URL obtained", flush=True)
                    return url

            # Fallback to mixed format streams
            formats = data.get("formatStreams", [])
            if formats:
                url = formats[0].get("url")
                if url:
                    print("[spoofify] Invidious format stream URL obtained", flush=True)
                    return url

        except Exception as exc:
            print(f"[spoofify] Invidious {instance} error: {exc}", flush=True)

    print("[spoofify] All Invidious instances failed", flush=True)
    return None


def _download_direct_mp3(url: str, dest_folder: Path, filename: str) -> Path:
    """Download a direct audio stream URL and convert to MP3 via ffmpeg."""
    dest_folder.mkdir(parents=True, exist_ok=True)
    raw_path = dest_folder / f"{filename}.raw"
    mp3_path = dest_folder / f"{filename}.mp3"

    resp = requests.get(url, stream=True, timeout=180, headers=_REQ_HEADERS)
    resp.raise_for_status()
    with open(raw_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=65536):
            if chunk:
                f.write(chunk)

    subprocess.run(
        [
            "ffmpeg", "-y",
            "-i", str(raw_path),
            "-vn", "-ar", "44100", "-ac", "2", "-b:a", "192k",
            str(mp3_path),
        ],
        check=True,
        capture_output=True,
    )
    raw_path.unlink(missing_ok=True)
    return mp3_path


# ---------------------------------------------------------------------------
# yt-dlp helpers (kept as fallbacks)
# ---------------------------------------------------------------------------

_YT_EXTRACTOR_ARGS = {"youtube": {"player_client": ["tv_embedded", "web_creator"]}}

_COOKIE_FILE: str | None = None
_cookie_env = os.environ.get("YOUTUBE_COOKIES", "").strip()
if _cookie_env:
    _tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False)
    _tmp.write(_cookie_env)
    _tmp.flush()
    _COOKIE_FILE = _tmp.name


def _sc_opts(extra: dict | None = None) -> dict:
    opts = {"quiet": True, "no_warnings": True}
    if extra:
        opts.update(extra)
    return opts


def _yt_opts(extra: dict | None = None) -> dict:
    opts = {"quiet": True, "no_warnings": True, "extractor_args": _YT_EXTRACTOR_ARGS}
    if _COOKIE_FILE:
        opts["cookiefile"] = _COOKIE_FILE
    if extra:
        opts.update(extra)
    return opts


def _safe_filename(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = text.encode("ascii", "ignore").decode()
    text = re.sub(r'[\\/*?:"<>|]', "", text)
    return text.strip()[:180]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def search_track_url(title: str, artists: str) -> str | None:
    """
    Return a URL for the track audio.
    Priority: Invidious (direct stream) → SoundCloud → YouTube.
    """
    base = f"{artists} - {title}" if artists else title

    # 1. Invidious (works on server IPs, no bot-detection)
    url = _search_invidious(f"{base} lyrics")
    if url:
        return url

    # 2. SoundCloud via yt-dlp (works on some server IPs / local)
    try:
        opts = _sc_opts({"extract_flat": True, "skip_download": True})
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"scsearch1:{base}", download=False)
            entries = (info or {}).get("entries") or []
            print(f"[spoofify] SC entries count: {len(entries)}", flush=True)
            if entries:
                sc_url = entries[0].get("url") or entries[0].get("webpage_url")
                if sc_url:
                    print(f"[spoofify] SC found: {sc_url}", flush=True)
                    return sc_url
    except Exception as exc:
        print(f"[spoofify] SC search failed: {exc}", flush=True)

    # 3. YouTube via yt-dlp (last resort)
    try:
        opts = _yt_opts({"extract_flat": True, "skip_download": True})
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch1:{base} lyrics", download=False)
            entries = (info or {}).get("entries") or []
            if entries:
                yt_url = entries[0].get("url") or f"https://www.youtube.com/watch?v={entries[0]['id']}"
                print(f"[spoofify] YT found: {yt_url}", flush=True)
                return yt_url
    except Exception as exc:
        print(f"[spoofify] YT search failed: {exc}", flush=True)

    return None


# Keep old name as alias for backward compatibility
search_youtube_url = search_track_url


def search_youtube_video_id(title: str, artists: str) -> str | None:
    base = f"{artists} - {title}" if artists else title
    try:
        opts = _yt_opts({"extract_flat": True, "skip_download": True})
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch1:{base} lyrics", download=False)
            entries = (info or {}).get("entries") or []
            if entries:
                vid = entries[0].get("id")
                if vid:
                    print(f"[spoofify] YT video_id={vid}", flush=True)
                    return vid
    except Exception as exc:
        print(f"[spoofify] YT video_id search failed: {exc}", flush=True)
    return None


def get_stream_url(video_id: str) -> tuple[str | None, str]:
    """
    Extract a direct audio stream URL for a YouTube video.
    Tries multiple strategies:
      1. android_vr client — works on home/VPS IPs without cookies
      2. web client with cookies — works on datacenter IPs (Render) when
         YOUTUBE_COOKIES env var is set
    Returns (url, content_type).
    """
    yt_url = f"https://www.youtube.com/watch?v={video_id}"
    base_opts = {"quiet": True, "no_warnings": True, "skip_download": True,
                 "format": "bestaudio/best"}

    # Strategy 1: android_vr (no PO token needed, works on many IPs)
    opts1 = {**base_opts, "extractor_args": {"youtube": {"player_client": ["android_vr"]}}}
    if _COOKIE_FILE:
        opts1["cookiefile"] = _COOKIE_FILE
    try:
        with yt_dlp.YoutubeDL(opts1) as ydl:
            info = ydl.extract_info(yt_url, download=False)
            url = (info or {}).get("url")
            ext = (info or {}).get("ext", "webm")
            if url:
                print(f"[spoofify] stream URL ok (android_vr) ext={ext}", flush=True)
                return url, f"audio/{ext}"
    except Exception as exc:
        print(f"[spoofify] android_vr failed: {exc}", flush=True)

    # Strategy 2: web client with cookies (required for datacenter IPs like Render)
    if _COOKIE_FILE:
        opts2 = {**base_opts, "cookiefile": _COOKIE_FILE,
                 "extractor_args": {"youtube": {"player_client": ["web"]}}}
        try:
            with yt_dlp.YoutubeDL(opts2) as ydl:
                info = ydl.extract_info(yt_url, download=False)
                url = (info or {}).get("url")
                ext = (info or {}).get("ext", "webm")
                if url:
                    print(f"[spoofify] stream URL ok (web+cookies) ext={ext}", flush=True)
                    return url, f"audio/{ext}"
        except Exception as exc:
            print(f"[spoofify] web+cookies failed: {exc}", flush=True)
    else:
        print("[spoofify] no cookies set — set YOUTUBE_COOKIES env var on Render", flush=True)

    return None, "audio/webm"


def download_mp3(source_url: str, dest_folder: Path, filename: str) -> Path:
    """
    Download audio from source_url and save as MP3 in dest_folder.
    Direct stream URLs (googlevideo.com) are downloaded via requests + ffmpeg.
    SoundCloud / YouTube URLs are handled by yt-dlp.
    """
    # Direct audio stream URL from Invidious
    if "googlevideo.com" in source_url:
        return _download_direct_mp3(source_url, dest_folder, filename)

    dest_folder.mkdir(parents=True, exist_ok=True)
    out_template = str(dest_folder / f"{filename}.%(ext)s")
    postprocessors = [
        {"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}
    ]

    if "soundcloud.com" in source_url:
        opts = _sc_opts({"format": "bestaudio/best", "outtmpl": out_template, "postprocessors": postprocessors})
    else:
        opts = _yt_opts({"format": "bestaudio/best", "outtmpl": out_template, "postprocessors": postprocessors})

    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([source_url])
    return dest_folder / f"{filename}.mp3"
