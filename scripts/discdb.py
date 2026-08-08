#!/usr/bin/env python3
"""
Name a ripped disc from TheDiscDb instead of from its volume label.

A disc's volume label is what the pressing plant happened to write: squashed
(BENDITLIKEBECKHAM_4X3), generic (WB_DVD, half of Warner's catalogue), or
absent. ISOHungry already handles those cases as well as they can be handled
without knowing what the disc actually is.

TheDiscDb (https://thediscdb.com, MIT-licensed data at
github.com/TheDiscDb/data) knows what the disc actually is, and identification
is exact rather than fuzzy: every disc is keyed on an MD5 over the sizes of the
files in VIDEO_TS, sorted by name, which is reproducible from a finished ISO.

    discdb.py sync              fetch or refresh the catalogue
    discdb.py identify <iso>    print the disc's proper name, or nothing
"""

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import unicodedata

DISCDB_DIR = os.environ.get("DISCDB_DIR", os.path.join(
    os.environ.get("BASE_OUTPUT_DIR", "/output"), ".discdb"))
REPO_DIR = os.path.join(DISCDB_DIR, "repo")
INDEX_PATH = os.path.join(DISCDB_DIR, "index.json")
REPO_URL = os.environ.get("DISCDB_REPO", "https://github.com/TheDiscDb/data.git")

# Only the JSON is needed. The full repository is 2.1 GB, most of it cover art
# and MakeMKV logs; a blobless sparse checkout of just these is ~290 MB.
SPARSE_PATTERNS = ["/data/**/disc*.json", "/data/**/metadata.json",
                   "/data/**/release.json"]

OWNER_UID = int(os.environ.get("EXTRAS_UID", "99"))
OWNER_GID = int(os.environ.get("EXTRAS_GID", "100"))



class DiscDbError(Exception):
    pass


def log(msg):
    print(msg, flush=True)


# --------------------------------------------------------------- content hash

def iso_video_ts_files(iso_path):
    """(name, size) for every file in the ISO's VIDEO_TS directory."""
    try:
        out = subprocess.run(["isoinfo", "-l", "-i", iso_path],
                             capture_output=True, timeout=300)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        raise DiscDbError("could not read %s: %s" % (os.path.basename(iso_path), e))

    text = out.stdout.decode("utf-8", "replace")
    files, in_video_ts = [], False
    for line in text.splitlines():
        line = line.rstrip()
        if line.startswith("Directory listing of "):
            in_video_ts = line.strip().upper().endswith("/VIDEO_TS/")
            continue
        if not in_video_ts or not line or line.startswith("d"):
            continue
        # ----------   0 0 0   26624 Aug  7 2026 [   1192 00]  VIDEO_TS.BUP;1
        m = re.match(r"^-\S*\s+\d+\s+\d+\s+\d+\s+(\d+)\s+.*\]\s+(\S+)\s*$", line)
        if not m:
            continue
        size, name = int(m.group(1)), m.group(2)
        name = name.split(";")[0]          # strip the ISO9660 version suffix
        files.append((name, size))
    return files


def content_hash(iso_path):
    """TheDiscDb's disc identity for a ripped ISO.

    MD5 over the little-endian int64 size of each VIDEO_TS file, in name order.
    Names, timestamps and contents are deliberately not part of it, which is
    why a re-rip of the same pressing still matches.
    """
    files = iso_video_ts_files(iso_path)
    if not files:
        raise DiscDbError("no VIDEO_TS files in %s — not a video DVD?"
                          % os.path.basename(iso_path))
    h = hashlib.md5()
    for _name, size in sorted(files, key=lambda f: f[0]):
        h.update(struct.pack("<q", size))
    return h.hexdigest().upper(), files


# ---------------------------------------------------------------------- index

def parse_duration(text):
    """'1:28:42' or '0:06:33' -> seconds."""
    if not text:
        return 0
    parts = [p for p in str(text).split(":") if p != ""]
    try:
        parts = [int(float(p)) for p in parts]
    except ValueError:
        return 0
    secs = 0
    for p in parts:
        secs = secs * 60 + p
    return secs


def _iter_disc_files(repo_dir):
    data_root = os.path.join(repo_dir, "data")
    for root, dirs, files in os.walk(data_root):
        for name in files:
            if re.fullmatch(r"disc\d+\.json", name):
                yield os.path.join(root, name)


def build_index(repo_dir=REPO_DIR, index_path=INDEX_PATH, dvd_only=True):
    """Condense the repository into the few fields a lookup needs.

    The checkout is ~290 MB of JSON, most of it per-title audio and subtitle
    track listings. The index is a fraction of that and is what ships around.
    """
    discs, seen_movies = [], {}
    scanned = kept = 0

    for path in _iter_disc_files(repo_dir):
        scanned += 1
        try:
            with open(path, encoding="utf-8") as fh:
                disc = json.load(fh)
        except (OSError, ValueError):
            continue

        fmt = (disc.get("Format") or "").upper()
        if dvd_only and fmt != "DVD":
            continue

        release_dir = os.path.dirname(path)
        movie_dir = os.path.dirname(release_dir)
        if movie_dir not in seen_movies:
            meta = {}
            try:
                with open(os.path.join(movie_dir, "metadata.json"),
                          encoding="utf-8") as fh:
                    meta = json.load(fh)
            except (OSError, ValueError):
                pass
            seen_movies[movie_dir] = {
                "title": meta.get("Title") or os.path.basename(movie_dir),
                "year": meta.get("Year"),
                "tmdb": (meta.get("ExternalIds") or {}).get("Tmdb"),
                "slug": meta.get("Slug"),
                "kind": (meta.get("Type") or "Movie"),
            }
        movie = seen_movies[movie_dir]

        titles = []
        for t in disc.get("Titles") or []:
            item = t.get("Item") or {}
            name = (item.get("Title") or "").strip()
            if not name:
                continue                    # unnamed title tells us nothing
            row = {
                "src": str(t.get("SourceFile") or ""),
                "s": parse_duration(t.get("Duration")),
                "n": name,
                "t": item.get("Type") or "Extra",
            }
            # Box sets carry the numbers outright, which is the whole answer to
            # "which episode is title 7" — no ordering heuristic needed.
            if row["t"] == "Episode":
                for key, short in (("Season", "se"), ("Episode", "ep")):
                    try:
                        row[short] = int(str(item.get(key)).strip())
                    except (TypeError, ValueError):
                        pass
            titles.append(row)
        if not titles:
            continue

        kept += 1
        discs.append({
            "h": (disc.get("ContentHash") or "").upper(),
            "movie": movie["title"], "year": movie["year"],
            "tmdb": movie["tmdb"], "kind": movie["kind"],
            "release": os.path.basename(release_dir),
            "disc": disc.get("Index"), "fmt": fmt,
            "titles": titles,
        })

    index = {"built": int(time.time()), "count": len(discs),
             "dvd_only": dvd_only, "discs": discs}
    os.makedirs(os.path.dirname(index_path), exist_ok=True)
    tmp = index_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, index_path)
    try:
        os.chown(index_path, OWNER_UID, OWNER_GID)
    except (PermissionError, OSError):
        pass
    log("indexed %d discs with named titles (from %d disc files) -> %s"
        % (kept, scanned, index_path))
    return index


def sync(rebuild_only=False):
    """Fetch or refresh the catalogue, then rebuild the index."""
    if not rebuild_only:
        os.makedirs(DISCDB_DIR, exist_ok=True)
        if os.path.isdir(os.path.join(REPO_DIR, ".git")):
            log("updating TheDiscDb checkout ...")
            _git(["fetch", "--depth", "1", "origin"], cwd=REPO_DIR)
            _git(["checkout", "-f", "FETCH_HEAD"], cwd=REPO_DIR)
        else:
            log("fetching TheDiscDb (blobless sparse clone, ~290 MB) ...")
            _git(["clone", "--depth", "1", "--filter=blob:none", "--no-checkout",
                  REPO_URL, REPO_DIR])
            _git(["sparse-checkout", "init", "--no-cone"], cwd=REPO_DIR)
            _git(["sparse-checkout", "set", "--no-cone"] + SPARSE_PATTERNS,
                 cwd=REPO_DIR)
            _git(["checkout"], cwd=REPO_DIR)
    return build_index()


def _git(args, cwd=None):
    proc = subprocess.run(["git"] + args, cwd=cwd, capture_output=True,
                          text=True, timeout=1800)
    if proc.returncode != 0:
        raise DiscDbError("git %s failed: %s"
                          % (" ".join(args[:2]), (proc.stderr or "")[-300:]))
    return proc.stdout


_index_cache = {"mtime": None, "data": None}


def load_index(index_path=INDEX_PATH):
    try:
        mtime = os.path.getmtime(index_path)
    except OSError:
        return None
    if _index_cache["mtime"] == mtime:
        return _index_cache["data"]
    try:
        with open(index_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    _index_cache.update(mtime=mtime, data=data)
    return data


# --------------------------------------------------------------------- lookup

def _fingerprint(seconds_list, tol=2):
    return sorted(int(round(s / float(tol))) for s in seconds_list if s)


def match_disc(iso_path=None, durations=None, index=None):
    """Identify a disc. Returns (entry, how, confidence) or (None, reason, 0).

    `how` is "contenthash" for an exact filesystem-level identification, or
    "duration" for the fallback, which is a guess and labelled as one.
    """
    index = index or load_index()
    if not index:
        return None, "no local index — run: discdb.py sync", 0.0
    discs = index.get("discs") or []

    if iso_path:
        try:
            h, _files = content_hash(iso_path)
        except DiscDbError:
            h = None
        if h:
            for entry in discs:
                if entry.get("h") == h:
                    return entry, "contenthash", 1.0

    if not durations:
        return None, "not in TheDiscDb", 0.0

    # Fallback: same set of runtimes. Two different pressings of the same film
    # usually differ somewhere in their extras, so this is decent evidence -
    # but it is evidence, not identity, and the caller must not treat it as
    # settled without a human looking.
    want = set(_fingerprint(durations))
    if not want:
        return None, "not in TheDiscDb", 0.0
    best, best_score = None, 0.0
    for entry in discs:
        have = set(_fingerprint([t["s"] for t in entry["titles"]]))
        if not have:
            continue
        overlap = len(want & have)
        score = overlap / float(max(len(want), len(have)))
        if score > best_score:
            best, best_score = entry, score
    if best and best_score >= 0.6:
        return best, "duration", round(best_score, 3)
    return None, "not in TheDiscDb", 0.0


def name_titles(entry, titles, tol=2):
    """Map our scanned titles onto the catalogue's names.

    Matched by runtime rather than title number: our numbering comes from
    lsdvd and theirs from MakeMKV, and the two do not always agree, but a
    runtime is a runtime.
    """
    # Assign globally best-fit first rather than walking the titles in order.
    # Discs are full of near-duplicate runtimes - a 60s menu loop sits right
    # next to a 61s featurette - and first-come matching lets whichever title
    # happens to be scanned first take a name that belongs to the other.
    pairs = []
    for t in titles:
        secs = t["seconds"] if isinstance(t, dict) else t[1]
        ix = t["ix"] if isinstance(t, dict) else t[0]
        for ci, cand in enumerate(entry["titles"]):
            delta = abs(cand["s"] - secs)
            if delta <= tol:
                pairs.append((delta, ix, ci))
    pairs.sort(key=lambda p: (p[0], p[1]))

    out, used_titles, used_cands = {}, set(), set()
    for _delta, ix, ci in pairs:
        if ix in used_titles or ci in used_cands:
            continue
        used_titles.add(ix)
        used_cands.add(ci)
        cand = entry["titles"][ci]
        out[ix] = {
            "name": cand["n"],
            "type": cand["t"],
            "is_feature": cand["t"] == "MainMovie",
            "season": cand.get("se"),
            "episode": cand.get("ep"),
        }
    return out




def disc_name(iso_path, index=None):
    """The name this disc should have, or None if the catalogue has no idea.

    Deliberately conservative: only an exact content-hash match is used. The
    duration fallback is fine for a human choosing from a list, but a ripper
    renaming files unattended should not act on a guess.
    """
    entry, how, _conf = match_disc(iso_path, None, index)
    if not entry or how != "contenthash":
        return None
    name = entry.get("movie") or ""
    year = entry.get("year")
    if not name:
        return None
    return "%s (%s)" % (name, year) if year else name


def cmd_identify(args):
    name = disc_name(os.path.abspath(args.iso))
    if name:
        print(name)
    else:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="Name a disc from TheDiscDb.")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="fetch or refresh the catalogue")
    s.add_argument("--rebuild-only", action="store_true")
    s.set_defaults(func=lambda a: sync(rebuild_only=a.rebuild_only))
    i = sub.add_parser("identify", help="print this disc's proper name")
    i.add_argument("iso")
    i.set_defaults(func=cmd_identify)
    args = p.parse_args()
    try:
        args.func(args)
    except DiscDbError as e:
        print("error: %s" % e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
