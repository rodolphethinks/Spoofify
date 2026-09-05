"""
Spoofify CLI

Usage:
    # Print track list only
    python main.py <spotify_url>

    # Print track list + start web player (open http://localhost:5000 on Android)
    python main.py <spotify_url> --play

    # Pre-download all tracks as MP3 then start player
    python main.py <spotify_url> --play --download-all
"""

import argparse
import os
import sys
from pathlib import Path

from spoofify import spotify, youtube
from spoofify.player import app as flask_app

MP3_FOLDER = Path("downloads")


def main():
    parser = argparse.ArgumentParser(description="Spoofify – Spotify → YouTube → MP3 player")
    parser.add_argument("url", nargs="?", default="https://open.spotify.com/playlist/0ve9XHkPzMTrAwrYTfJCCs")
    parser.add_argument("--play", action="store_true", help="Start the web player at http://localhost:5000")
    parser.add_argument("--download-all", action="store_true", help="Pre-download all tracks as MP3")
    parser.add_argument("--port", type=int, default=5000)
    args = parser.parse_args()

    print(f"Fetching Spotify playlist…")
    try:
        name, tracks = spotify.get_tracks(args.url)
    except (ValueError, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"\n  {name or 'Playlist'}  ({len(tracks)} tracks)\n")
    for i, t in enumerate(tracks, 1):
        artists = f" — {t['artists']}" if t["artists"] else ""
        print(f"{i:>3}. {t['title']}{artists}")

    if args.download_all:
        print(f"\nDownloading {len(tracks)} tracks to ./{MP3_FOLDER}/…\n")
        for i, t in enumerate(tracks, 1):
            safe = youtube._safe_filename(
                f"{t['artists']} - {t['title']}" if t["artists"] else t["title"]
            )
            dest = MP3_FOLDER / f"{safe}.mp3"
            if dest.exists():
                print(f"  [{i}/{len(tracks)}] Already downloaded: {t['title']}")
                continue
            print(f"  [{i}/{len(tracks)}] Searching: {t['title']}…", end=" ", flush=True)
            yt_url = youtube.search_youtube_url(t["title"], t["artists"])
            if not yt_url:
                print("not found")
                continue
            try:
                youtube.download_mp3(yt_url, MP3_FOLDER, safe)
                print("done")
            except Exception as exc:
                print(f"error: {exc}")

    if args.play:
        os.environ["SPOTIFY_URL"] = args.url
        player_url = f"http://localhost:{args.port}/player?url={args.url}"
        print(f"\nStarting player → {player_url}\n")
        flask_app.run(host="0.0.0.0", port=args.port, debug=False)


if __name__ == "__main__":
    main()




