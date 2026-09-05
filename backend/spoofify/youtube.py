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

    # googlevideo (and some other CDNs) return 403 for requests without a
    # Range header, even for otherwise-valid signed/PO-tokened URLs.
    resp = requests.get(url, stream=True, timeout=180, headers={**_REQ_HEADERS, "Range": "bytes=0-"})
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

# Remembers which get_stream_url() strategy last worked, so it's tried first
# for the next track (self-reordering retries).
_last_successful_strategy = "mweb_pot"


def _set_last_successful_strategy(name: str) -> None:
    global _last_successful_strategy
    _last_successful_strategy = name


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


def get_stream_response(video_id: str) -> tuple["requests.Response | None", str]:
    """
    Open a direct audio stream for a YouTube video.
    Tries multiple strategies, in an order that adapts based on whichever
    strategy last succeeded (so the working one is tried first next time):
      1. mweb client + local bgutil PO-Token provider — bypasses the
         "Sign in to confirm you're not a bot" check on flagged/datacenter
         IPs (like Render's) without needing cookies
      2. android_vr client — no PO token needed, but as of late 2026 YouTube
         403s actual playback for it even though extraction succeeds
      3. web client with cookies — extra fallback if YOUTUBE_COOKIES is set
    googlevideo URLs are single-use (a second request against the same URL
    gets a 403), so each candidate is validated by opening the *real*
    streaming request (with the Range header the CDN requires) and reusing
    that same open connection for playback — never a separate throwaway
    verification request.
    Returns (open streaming response, content_type), caller must close it.
    """
    yt_url = f"https://www.youtube.com/watch?v={video_id}"
    base_opts = {"quiet": True, "no_warnings": True, "skip_download": True,
                 "format": "bestaudio/best"}

    def try_android_vr():
        opts = {**base_opts, "extractor_args": {"youtube": {"player_client": ["android_vr"]}}}
        if _COOKIE_FILE:
            opts["cookiefile"] = _COOKIE_FILE
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(yt_url, download=False)
        return (info or {}).get("url"), (info or {}).get("ext", "webm")

    def try_mweb_pot():
        opts = {**base_opts, "js_runtimes": {"node": {}},
                "extractor_args": {"youtube": {"player_client": ["mweb"]}}}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(yt_url, download=False)
        return (info or {}).get("url"), (info or {}).get("ext", "webm")

    def try_web_cookies():
        if not _COOKIE_FILE:
            print("[spoofify] no cookies set — set YOUTUBE_COOKIES env var on Render", flush=True)
            return None, "webm"
        opts = {**base_opts, "cookiefile": _COOKIE_FILE, "js_runtimes": {"node": {}},
                "extractor_args": {"youtube": {"player_client": ["web"]}}}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(yt_url, download=False)
        return (info or {}).get("url"), (info or {}).get("ext", "webm")

    def _open(url: str):
        """Open the real streaming request; return it only if the CDN accepts it."""
        r = requests.get(url, stream=True, timeout=300,
                          headers={**_REQ_HEADERS, "Range": "bytes=0-"})
        if r.status_code in (200, 206):
            return r
        r.close()
        return None

    strategies = {"mweb_pot": try_mweb_pot, "android_vr": try_android_vr, "web_cookies": try_web_cookies}
    order = [_last_successful_strategy, *[s for s in strategies if s != _last_successful_strategy]]

    for name in order:
        try:
            url, ext = strategies[name]()
            if not url:
                continue
            resp = _open(url)
            if resp:
                print(f"[spoofify] stream URL ok ({name}) ext={ext}", flush=True)
                _set_last_successful_strategy(name)
                return resp, f"audio/{ext}"
            print(f"[spoofify] {name} returned a URL but CDN rejected it", flush=True)
        except Exception as exc:
            print(f"[spoofify] {name} failed: {exc}", flush=True)

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
