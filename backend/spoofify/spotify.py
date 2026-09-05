"""Fetch track list from any public Spotify playlist, album, or track URL."""

import json
import re

import requests
from bs4 import BeautifulSoup

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}

_URL_RE = re.compile(
    r"https?://open\.spotify\.com/"
    r"(?P<type>playlist|album|track|episode|show)/(?P<id>[A-Za-z0-9]+)"
)


def parse_spotify_url(url: str) -> tuple[str, str]:
    m = _URL_RE.search(url)
    if not m:
        raise ValueError(f"Unrecognised Spotify URL: {url!r}")
    return m.group("type"), m.group("id")


def get_tracks(url: str) -> tuple[str, list[dict]]:
    """
    Return (playlist_name, tracks) where each track is:
        {"title": str, "artists": str}
    """
    content_type, content_id = parse_spotify_url(url)
    embed_url = f"https://open.spotify.com/embed/{content_type}/{content_id}"

    resp = requests.get(embed_url, headers=HEADERS, timeout=15)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    nd_tag = soup.find("script", id="__NEXT_DATA__")
    if not nd_tag or not nd_tag.string:
        raise RuntimeError("__NEXT_DATA__ not found in Spotify embed page.")

    data = json.loads(nd_tag.string)
    entity = data["props"]["pageProps"]["state"]["data"]["entity"]

    playlist_name: str = entity.get("name") or entity.get("title") or ""
    track_list: list[dict] = entity.get("trackList", [])

    if not track_list and content_type == "track":
        track_list = [entity]

    tracks = []
    for item in track_list:
        title = (item.get("title") or item.get("name") or "").strip()
        subtitle = item.get("subtitle") or item.get("artists") or ""
        artists = subtitle.replace("\u00a0", " ").strip()
        if title:
            tracks.append({"title": title, "artists": artists})

    return playlist_name, tracks
