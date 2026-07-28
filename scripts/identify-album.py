#!/usr/bin/env python3
"""Identify an album that ripped without metadata, and tag it properly.

CDDB/MusicBrainz lookup at rip time is by disc TOC: if the disc isn't in the
database, you get "Unknown Artist / Unknown Album" and "Track 1..N". That disc
is long since ejected, but the album can still be identified by *searching*
MusicBrainz by name and matching on track count.

    identify-album.py --dir "/output/music/Unknown_Artist/Smash_Mouth_Astro_Lounge"
    identify-album.py --dir "..." --query "smash mouth astro lounge" --apply

Dry run by default: nothing is written until --apply.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

MB = "https://musicbrainz.org/ws/2"
UA = "ISOHungry/1.0 (https://github.com/JamesDavid/ISOHungry)"
AUDIO = (".mp3", ".flac", ".ogg", ".m4a")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def munge(s):
    """Match the filename style abcde produces for the rest of the library."""
    s = re.sub(r'[/\\:*?"<>|]', "_", s).strip()
    return s.replace(" ", "_")


def tracks_in(d):
    return sorted(f for f in os.listdir(d) if f.lower().endswith(AUDIO))


def search_releases(query, want, limit=25):
    """Releases matching the text, ranked by how well the track count fits."""
    url = "%s/release/?query=%s&fmt=json&limit=%d" % (MB, urllib.parse.quote(query), limit)
    out = []
    for rel in get(url).get("releases", []):
        count = sum(m.get("track-count", 0) for m in rel.get("media", []) or [])
        out.append({
            "id": rel["id"],
            "title": rel.get("title", "?"),
            "artist": "".join(c.get("name", "") + c.get("joinphrase", "")
                              for c in rel.get("artist-credit", [])) or "?",
            "date": (rel.get("date") or "")[:4],
            "country": rel.get("country", ""),
            "count": count,
            "score": rel.get("score", 0),
        })
    # Exact track-count matches first, then MusicBrainz' own relevance score.
    out.sort(key=lambda r: (r["count"] != want, -r["score"]))
    return out


def release_tracks(mbid):
    url = "%s/release/%s?inc=recordings+artist-credits&fmt=json" % (MB, mbid)
    rel = get(url)
    album = rel.get("title", "")
    year = (rel.get("date") or "")[:4]
    albumartist = "".join(c.get("name", "") + c.get("joinphrase", "")
                          for c in rel.get("artist-credit", []))
    out = []
    for medium in rel.get("media", []):
        for t in medium.get("tracks", []):
            ac = t.get("artist-credit") or rel.get("artist-credit", [])
            out.append({
                "num": int(t.get("position", len(out) + 1)),
                "title": t.get("title", ""),
                "artist": "".join(c.get("name", "") + c.get("joinphrase", "") for c in ac),
            })
    return albumartist, album, year, out


def apply_release(d, files, chosen_id, no_move):
    """Tag, rename and (optionally) reorganise. Returns the final directory."""
    albumartist, album, year, tracks = release_tracks(chosen_id)
    by_num = {t["num"]: t for t in tracks}

    plan = []
    for f in files:
        m = re.match(r"^(\d+)", f)
        if not m:
            continue
        n = int(m.group(1))
        t = by_num.get(n)
        if t:
            plan.append((f, n, t["artist"], t["title"]))

    total = len(plan)
    for old, n, artist, title in plan:
        src = os.path.join(d, old)
        if src.lower().endswith(".mp3"):
            subprocess.run(["eyeD3", "--encoding", "utf8", "-a", artist, "-A", album,
                            "-t", title, "-n", str(n), "-N", str(total)]
                           + (["-Y", year] if year else []) + [src],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        elif src.lower().endswith(".flac"):
            subprocess.run(["metaflac", "--remove-tag=ARTIST", "--remove-tag=ALBUM",
                            "--remove-tag=TITLE", "--remove-tag=TRACKNUMBER", src], check=False)
            subprocess.run(["metaflac", "--set-tag=ARTIST=" + artist,
                            "--set-tag=ALBUM=" + album, "--set-tag=TITLE=" + title,
                            "--set-tag=TRACKNUMBER=" + str(n), src], check=False)
        dst = os.path.join(d, "%02d - %s%s" % (n, munge(title), os.path.splitext(old)[1]))
        if dst != src and not os.path.exists(dst):
            os.rename(src, dst)

    final = d
    if not no_move:
        music_root = os.path.dirname(os.path.dirname(d))
        target = os.path.join(music_root, munge(albumartist), munge(album))
        if os.path.abspath(target) != d and not os.path.exists(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            os.rename(d, target)
            final = target
            try:
                os.rmdir(os.path.dirname(d))
            except OSError:
                pass
    return final, albumartist, album, year, total


def main_json(args):
    """Used by the web UI: candidates, or the result of applying one."""
    d = os.path.abspath(args.dir)
    if not os.path.isdir(d):
        print(json.dumps({"error": "not a directory"})); return
    files = tracks_in(d)
    if not files:
        print(json.dumps({"error": "no audio files"})); return

    query = args.query or os.path.basename(d).replace("_", " ")
    try:
        matches = search_releases(query, len(files))
    except Exception as e:
        print(json.dumps({"error": "MusicBrainz lookup failed: %s" % e})); return
    if not matches:
        print(json.dumps({"error": "no matches for %r" % query, "query": query})); return

    if not args.apply:
        print(json.dumps({"query": query, "files": len(files),
                          "matches": matches[:10]}))
        return

    chosen = matches[args.pick]
    time.sleep(1.1)
    try:
        final, artist, album, year, n = apply_release(d, files, chosen["id"], args.no_move)
    except Exception as e:
        print(json.dumps({"error": "apply failed: %s" % e})); return
    print(json.dumps({"ok": True, "artist": artist, "album": album,
                      "year": year, "tracks": n, "dir": final}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="album directory to identify")
    ap.add_argument("--query", help="search text (default: derived from the folder name)")
    ap.add_argument("--pick", type=int, default=0, help="use match N from the list")
    ap.add_argument("--apply", action="store_true", help="write tags and rename")
    ap.add_argument("--no-move", action="store_true",
                    help="tag in place; don't reorganise into Artist/Album")
    ap.add_argument("--json", action="store_true",
                    help="machine-readable output, for the web UI")
    args = ap.parse_args()

    if args.json:
        return main_json(args)

    d = os.path.abspath(args.dir)
    if not os.path.isdir(d):
        sys.exit("not a directory: %s" % d)
    files = tracks_in(d)
    if not files:
        sys.exit("no audio files in %s" % d)

    query = args.query or os.path.basename(d).replace("_", " ")
    print("album dir : %s" % d)
    print("files     : %d" % len(files))
    print("query     : %s\n" % query)

    matches = search_releases(query, len(files))
    if not matches:
        sys.exit("no MusicBrainz matches for %r" % query)

    print("matches (* = track count agrees):")
    for i, m in enumerate(matches[:10]):
        print("  %s%d  %-28s %-34s %-6s %2d tracks  score=%d"
              % ("*" if m["count"] == len(files) else " ", i,
                 m["artist"][:28], m["title"][:34], m["date"], m["count"], m["score"]))
    print()

    chosen = matches[args.pick]
    if chosen["count"] != len(files):
        print("!! chosen release has %d tracks, the folder has %d"
              % (chosen["count"], len(files)))
        print("   pass --pick N to choose another, or --query to search differently")

    time.sleep(1.1)                       # MusicBrainz asks for <=1 request/sec
    albumartist, album, year, tracks = release_tracks(chosen["id"])
    print("using: %s / %s (%s)  https://musicbrainz.org/release/%s\n"
          % (albumartist, album, year, chosen["id"]))

    by_num = {t["num"]: t for t in tracks}
    plan = []
    for f in files:
        m = re.match(r"^(\d+)", f)
        if not m:
            print("  ?? %s (no leading track number)" % f)
            continue
        n = int(m.group(1))
        t = by_num.get(n)
        if not t:
            print("  ?? %s (no track %d in release)" % (f, n))
            continue
        ext = os.path.splitext(f)[1]
        newname = "%02d - %s%s" % (n, munge(t["title"]), ext)
        plan.append((f, newname, n, t["artist"], t["title"]))
        print("  %02d  %-26s %s" % (n, t["artist"][:26], t["title"]))

    if not args.apply:
        print("\n(dry run - pass --apply to write tags and rename)")
        return

    total = len(plan)
    for old, newname, n, artist, title in plan:
        src = os.path.join(d, old)
        if src.lower().endswith(".mp3"):
            subprocess.run(["eyeD3", "--encoding", "utf8", "-a", artist, "-A", album,
                            "-t", title, "-n", str(n), "-N", str(total)]
                           + (["-Y", year] if year else []) + [src],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        elif src.lower().endswith(".flac"):
            subprocess.run(["metaflac", "--remove-tag=ARTIST", "--remove-tag=ALBUM",
                            "--remove-tag=TITLE", "--remove-tag=TRACKNUMBER", src], check=False)
            subprocess.run(["metaflac", "--set-tag=ARTIST=" + artist,
                            "--set-tag=ALBUM=" + album, "--set-tag=TITLE=" + title,
                            "--set-tag=TRACKNUMBER=" + str(n), src], check=False)
        dst = os.path.join(d, newname)
        if dst != src and not os.path.exists(dst):
            os.rename(src, dst)

    final = d
    if not args.no_move:
        music_root = os.path.dirname(os.path.dirname(d))
        target = os.path.join(music_root, munge(albumartist), munge(album))
        if os.path.abspath(target) != d:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target):
                print("!! %s already exists; leaving files in place" % target)
            else:
                os.rename(d, target)
                final = target
                parent = os.path.dirname(d)
                try:
                    os.rmdir(parent)          # drop Unknown_Artist if now empty
                except OSError:
                    pass
    print("\ndone: %s" % final)


if __name__ == "__main__":
    main()
