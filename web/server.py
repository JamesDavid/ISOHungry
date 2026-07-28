#!/usr/bin/env python3
"""
ISOHungry web UI — read-only status, plus naming.

Deliberately narrow write surface: you can set a friendly name for a rip in
progress, or rename a finished ISO. There is no eject, no delete, no way to
destroy data through this server.

Runs alongside the terminal display, reading the same state files the TUI does.
"""
import errno
import json
import os
import re
import shutil
import subprocess
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

OUTPUT_DIR  = os.environ.get("BASE_OUTPUT_DIR", "/output")
STATUS_DIR  = "/tmp/dvd_rip_status"
META_DIR    = "/tmp/dvd_rip_meta"
PENDING_DIR = os.path.join(OUTPUT_DIR, ".pending")
FP_DIR      = os.path.join(OUTPUT_DIR, ".ripped")
LOG_DIR     = os.path.join(OUTPUT_DIR, "logs")
PORT        = int(os.environ.get("WEB_PORT", "8080"))
HERE        = os.path.dirname(os.path.abspath(__file__))

# Same character policy the ripper's sanitize_label uses, so a name chosen here
# produces exactly the filename the ripper would produce.
SAFE = re.compile(r"[^A-Za-z0-9._-]")


def sanitize(name):
    clean = SAFE.sub("_", (name or "").strip())
    clean = clean.lstrip("._-")[:64]
    return clean


def read_kv(path):
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                if "=" in line:
                    k, _, v = line.partition("=")
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def collect_drives():
    drives = []
    try:
        names = sorted(os.listdir(STATUS_DIR))
    except OSError:
        names = []

    for dev in names:
        try:
            with open(os.path.join(STATUS_DIR, dev)) as fh:
                raw = fh.read().strip()
        except OSError:
            continue

        state, _, start = raw.partition("|")
        meta = read_kv(os.path.join(META_DIR, dev))

        total = int(meta.get("total_bytes") or 0)
        done = 0
        scratch = meta.get("scratch")
        phase = meta.get("phase", "")
        kind = meta.get("kind", "")

        # Audio is measured in tracks, not bytes: abcde replaces each ripped
        # WAV with a much smaller encoded file, so bytes-on-disk against the
        # raw CDDA size would crawl and finish near 10%.
        prog = read_kv(os.path.join(META_DIR, dev + ".progress"))
        tracks_done = int(prog.get("tracks_done") or 0)
        tracks_total = int(prog.get("tracks_total") or meta.get("tracks_total") or 0)

        if kind != "audio":
            if phase == "ripping" and scratch and os.path.isdir(scratch):
                done = dir_size(scratch)
            elif phase in ("iso", "done") and total:
                done = total

        drives.append({
            "device": dev,
            "status": state,
            "start": int(start) if start.isdigit() else None,
            "label": meta.get("label", ""),
            "fp": meta.get("fp", ""),
            "kind": kind,
            "phase": phase,
            "bytes_done": done,
            "bytes_total": 0 if kind == "audio" else total,
            "tracks_done": tracks_done,
            "tracks_total": tracks_total,
            "pending_name": read_pending(meta.get("fp", "")),
        })
    return drives


def read_pending(fp):
    if not fp:
        return ""
    try:
        with open(os.path.join(PENDING_DIR, fp)) as fh:
            return fh.read().strip()
    except OSError:
        return ""


AUDIO_EXT = (".mp3", ".flac", ".ogg", ".m4a", ".wav")

SETTINGS_FILE = os.path.join(OUTPUT_DIR, "settings.conf")

# Everything the UI may change, with how to validate it. The ripper applies
# the same whitelist when reading the file, so a bad value can never reach a
# command line even if the file is edited by hand.
SETTINGS = {
    "AUDIO_FORMAT":          {"type": "choice", "values": ["mp3", "flac"], "default": "mp3"},
    "RIP_DATA_DISCS":        {"type": "choice", "values": ["1", "0"], "default": "1"},
    "AUDIO_CDPARANOIA_OPTS": {"type": "choice", "values": ["", "-Y", "-Z"], "default": ""},
    "MAX_PARALLEL":          {"type": "int", "min": 1, "max": 8, "default": "2"},
    "AUDIO_RIP_TIMEOUT":     {"type": "int", "min": 0, "max": 86400, "default": "5400"},
}


def read_settings():
    """Effective values: the file wins, then the environment, then the default."""
    onfile = {}
    try:
        with open(SETTINGS_FILE) as fh:
            for line in fh:
                if "=" in line:
                    k, _, v = line.partition("=")
                    onfile[k.strip()] = v.strip()
    except OSError:
        pass
    out = {}
    for key, spec in SETTINGS.items():
        val = onfile.get(key, os.environ.get(key, spec["default"]))
        if spec["type"] == "choice" and val not in spec["values"]:
            val = spec["default"]
        elif spec["type"] == "int":
            try:
                n = int(val)
                val = str(min(max(n, spec["min"]), spec["max"]))
            except (TypeError, ValueError):
                val = spec["default"]
        out[key] = val
    return out


def write_settings(incoming):
    """Validate and persist. Returns (ok, error)."""
    current = read_settings()
    for key, raw in incoming.items():
        if key not in SETTINGS:
            return False, "unknown setting: %s" % key
        spec = SETTINGS[key]
        val = "" if raw is None else str(raw)
        if spec["type"] == "choice":
            if val not in spec["values"]:
                return False, "%s must be one of %r" % (key, spec["values"])
        else:
            try:
                n = int(val)
            except ValueError:
                return False, "%s must be a number" % key
            if not (spec["min"] <= n <= spec["max"]):
                return False, "%s must be %d-%d" % (key, spec["min"], spec["max"])
            val = str(n)
        current[key] = val

    tmp = SETTINGS_FILE + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("# Written by the ISOHungry web UI. Applies to the next disc.\n")
        for k in SETTINGS:
            fh.write("%s=%s\n" % (k, current[k]))
    os.replace(tmp, SETTINGS_FILE)
    return True, None


def collect_isos():
    """Everything ISOHungry has produced: movie/data images and music albums."""
    out = []

    # Disc images live one level down, in movies/ and data/ (plus the repo's
    # original flat layout, kept working for anything ripped before subdirs).
    for sub in ("movies", "data", ""):
        d = os.path.join(OUTPUT_DIR, sub) if sub else OUTPUT_DIR
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        for name in entries:
            if not name.endswith(".iso"):
                continue
            path = os.path.join(d, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            out.append({
                "name": name,
                "rel": os.path.relpath(path, OUTPUT_DIR).replace(os.sep, "/"),
                "kind": sub or "movies",
                "size": st.st_size,
                "mtime": int(st.st_mtime),
                "tracks": 0,
            })

    # Music is a directory of tracks, not a single file; report it as an album.
    music = os.path.join(OUTPUT_DIR, "music")
    for root, dirs, files in os.walk(music):
        tracks = [f for f in files if f.lower().endswith(AUDIO_EXT)]
        if not tracks:
            continue
        dirs[:] = []                      # an album is a leaf; don't descend
        size = 0
        newest = 0
        for f in tracks:
            try:
                st = os.stat(os.path.join(root, f))
            except OSError:
                continue
            size += st.st_size
            newest = max(newest, int(st.st_mtime))
        rel = os.path.relpath(root, OUTPUT_DIR).replace(os.sep, "/")
        name = os.path.relpath(root, music).replace(os.sep, "/")
        # A disc missing from the lookup database lands as "Unknown Artist /
        # Unknown Album" with "Track 1..N". Flag those so they can be
        # identified from the UI instead of sitting there unnoticed.
        needs_id = ("unknown" in name.lower()
                    or any(re.match(r"^\d+ - Track[ _]?\d+\.", t) for t in tracks))
        out.append({
            "name": name,
            "rel": rel,
            "kind": "music",
            "size": size,
            "mtime": newest,
            "tracks": len(tracks),
            "needs_id": needs_id,
        })

    out.sort(key=lambda i: i["mtime"], reverse=True)
    return out


def free_bytes():
    try:
        return shutil.disk_usage(OUTPUT_DIR).free
    except OSError:
        return 0


class Handler(BaseHTTPRequestHandler):
    server_version = "ISOHungry"

    def log_message(self, *args):
        pass  # the terminal display owns the console

    # ------------------------------------------------------------- responses
    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _resolve(self, rel, want="any"):
        """Resolve a client-supplied relative path to something inside
        OUTPUT_DIR. Returns None for anything that escapes, or that isn't the
        kind of thing asked for. `want` is "file", "album" or "any"."""
        rel = unquote(rel or "").strip().lstrip("/")
        if not rel:
            return None
        root = os.path.realpath(OUTPUT_DIR)
        path = os.path.realpath(os.path.join(root, rel))
        # Containment check: must be strictly under OUTPUT_DIR.
        if path != root and not path.startswith(root + os.sep):
            return None
        if want in ("file", "any") and os.path.isfile(path) and path.endswith(".iso"):
            return path
        if want in ("album", "any") and os.path.isdir(path):
            # Only album directories under music/ are addressable.
            music = os.path.realpath(os.path.join(root, "music"))
            if path.startswith(music + os.sep):
                return path
        return None

    # An unhandled exception in a handler closes the connection with no
    # response at all, which surfaces in the browser as a silent failure.
    # Always answer, even if the answer is "something went wrong".
    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _guard(self, fn):
        try:
            fn()
        except (BrokenPipeError, ConnectionResetError):
            raise
        except Exception:
            traceback.print_exc()
            try:
                self._send(500, {"error": "internal error — see container logs"})
            except Exception:
                pass

    # ------------------------------------------------------------------ GET
    def do_GET(self):
        self._guard(self._do_GET)

    def do_POST(self):
        self._guard(self._do_POST)

    def _do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "index.html missing", "text/plain")
            return

        if path == "/api/status":
            self._send(200, {
                "drives": collect_drives(),
                "isos": collect_isos(),
                "free_bytes": free_bytes(),
                "output_dir": OUTPUT_DIR,
            })
            return

        if path == "/api/settings":
            self._send(200, {"settings": read_settings(),
                             "spec": SETTINGS})
            return

        if path == "/api/logs":
            out = []
            try:
                for name in os.listdir(LOG_DIR):
                    if not name.endswith(".log"):
                        continue
                    try:
                        st = os.stat(os.path.join(LOG_DIR, name))
                    except OSError:
                        continue
                    out.append({"name": name, "size": st.st_size,
                                "mtime": int(st.st_mtime)})
            except OSError:
                pass
            out.sort(key=lambda l: l["mtime"], reverse=True)
            self._send(200, out)
            return

        if path.startswith("/api/log/"):
            name = os.path.basename(unquote(path[len("/api/log/"):]))
            if not name.endswith(".log"):
                self._send(404, {"error": "not found"})
                return
            target = os.path.realpath(os.path.join(LOG_DIR, name))
            if os.path.dirname(target) != os.path.realpath(LOG_DIR) \
                    or not os.path.isfile(target):
                self._send(404, {"error": "not found"})
                return
            # Tail only: these grow without bound and the browser wants the end.
            try:
                with open(target, "rb") as fh:
                    fh.seek(0, os.SEEK_END)
                    size = fh.tell()
                    fh.seek(max(0, size - 256 * 1024))
                    text = fh.read().decode("utf-8", "replace")
            except OSError:
                self._send(500, {"error": "unreadable"})
                return
            lines = text.splitlines()[-500:]
            self._send(200, {"name": name, "lines": lines, "size": size})
            return

        if path.startswith("/download/"):
            target = self._resolve(path[len("/download/"):], want="file")
            if not target:
                self._send(404, {"error": "not found"})
                return
            size = os.path.getsize(target)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition",
                             'attachment; filename="%s"' % os.path.basename(target))
            self.end_headers()
            with open(target, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile, 1024 * 512)
            return

        self._send(404, {"error": "not found"})

    # Identify an album the disc lookup missed, by searching MusicBrainz by
    # name. Reaches outward, so it gets a longer leash than the local calls.
    def _identify(self, payload):
        target = self._resolve(payload.get("rel"), want="album")
        if not target:
            self._send(404, {"error": "no such album"})
            return
        cmd = [sys.executable, os.path.join(HERE, "identify-album.py"),
               "--dir", target, "--json"]
        q = (payload.get("query") or "").strip()
        if q:
            cmd += ["--query", q[:200]]
        if payload.get("apply"):
            cmd += ["--apply", "--pick", str(int(payload.get("pick") or 0))]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            self._send(504, {"error": "MusicBrainz took too long"})
            return
        try:
            self._send(200, json.loads(p.stdout or "{}"))
        except ValueError:
            self._send(500, {"error": (p.stderr or "lookup failed").strip()[:300]})

    # ----------------------------------------------------------------- POST
    def _do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 64 * 1024:
            self._send(413, {"error": "too large"})
            return
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return

        path = self.path.split("?", 1)[0]

        # Name a rip that is still running; applied when the ISO is finalised.
        if path == "/api/pending":
            # Fingerprints are exactly 10 hex chars (md5 truncated by the
            # ripper). Demand that shape rather than filtering junk down to
            # something hex-ish and accepting it.
            fp = (payload.get("fp") or "").strip()
            if not re.fullmatch(r"[a-f0-9]{10}", fp):
                self._send(400, {"error": "invalid fingerprint"})
                return
            name = sanitize(payload.get("name"))
            os.makedirs(PENDING_DIR, exist_ok=True)
            target = os.path.join(PENDING_DIR, fp)
            if name:
                with open(target, "w") as fh:
                    fh.write(name)
            elif os.path.exists(target):
                os.remove(target)          # empty name clears it
            self._send(200, {"ok": True, "fp": fp, "name": name})
            return

        if path == "/api/settings":
            ok, err = write_settings(payload or {})
            if not ok:
                self._send(400, {"error": err})
            else:
                self._send(200, {"ok": True, "settings": read_settings()})
            return

        if path == "/api/identify":
            self._identify(payload)
            return

        # Rename a finished ISO, keeping its fingerprint marker in step so the
        # disc is still recognised as already-ripped.
        if path == "/api/rename":
            src = self._resolve(payload.get("from"))
            if not src:
                self._send(404, {"error": "no such item"})
                return
            new = sanitize(payload.get("to"))
            if not new:
                self._send(400, {"error": "invalid name"})
                return

            # Renaming keeps the item where it is: an ISO stays in movies/ or
            # data/, an album stays under music/ beside its siblings.
            is_file = os.path.isfile(src)
            dst = os.path.join(os.path.dirname(src), new + (".iso" if is_file else ""))
            if os.path.exists(dst):
                self._send(409, {"error": "something with that name already exists"})
                return
            try:
                os.rename(src, dst)
            except OSError as e:
                # The usual cause is the file being held open elsewhere — on
                # Windows, mounting an ISO as a virtual drive locks it.
                if e.errno in (errno.EACCES, errno.EPERM, errno.EBUSY, errno.ETXTBSY):
                    self._send(409, {"error": "file is in use — if you mounted "
                                              "this ISO, eject it and try again"})
                else:
                    self._send(500, {"error": "rename failed: %s" % e.strerror})
                return

            root = os.path.realpath(OUTPUT_DIR)
            old_rel = os.path.relpath(src, root).replace(os.sep, "/")
            new_rel = os.path.relpath(dst, root).replace(os.sep, "/")
            # Keep the fingerprint marker pointing at the renamed item, or the
            # disc would no longer be recognised as already ripped.
            try:
                for fp in os.listdir(FP_DIR):
                    marker = os.path.join(FP_DIR, fp)
                    with open(marker) as fh:
                        cur = fh.read().strip()
                    if cur in (old_rel, os.path.basename(src)):
                        with open(marker, "w") as out:
                            out.write(new_rel + "\n")
                        break
            except OSError:
                pass
            self._send(200, {"ok": True, "name": os.path.basename(dst), "rel": new_rel})
            return

        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    os.makedirs(PENDING_DIR, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
