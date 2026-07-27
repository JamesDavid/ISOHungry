# 🍪 ISOHungry

**ME EAT DVD. ME MAKE ISO. OM NOM NOM.**

Feed it discs, it eats them. Watches every optical drive it can see, works out
what each disc *is* — film, album or data — rips it, burps, ejects, and waits
for the next one. Several drives at once. Runs in a container, so the only
thing you install is Docker.

```
🍪 ISOHungry — me eat DVD! (updated 14:22:07)
========================================================
sr0   | 🍪 NOM NOM NOM! Eating BLADE_RUN | 00:12:41
sr1   | 🎵 NOM NOM! Slurping CD          | 00:04:52
sr2   | 🤤 BUUURP! Me ate THE_MATRIX     | 00:44:52
sr3   | 🍪 Me hungry... feed me disc!    | --:--:--
```

There's a web UI too, on `:8080` — same information, plus a log viewer, and
you can name a disc while it's still ripping.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/web-ui-dark.png">
    <img src="docs/web-ui.png" alt="ISOHungry web UI on a phone: two drives ripping with progress bars, finished films, an album and a data image below" width="330">
  </picture>
</p>

---

## Quick start

**Linux** — the easy case, drives just work:

```bash
git clone <this-repo> && cd ISOHungry
./setup.sh
docker compose up -d
docker compose logs -f
```

**Windows** — needs a one-time kernel swap (see [why](#why-windows-needs-work)):

```powershell
git clone <this-repo>; cd ISOHungry
powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1   # once, ~20 min
.\scripts\attach-drives.ps1                                          # after each reboot
docker compose up -d
```

**macOS** — not possible. Docker Desktop on macOS has no USB or optical
passthrough and there's no usbipd equivalent. `./setup.sh` explains your
options: run the script natively via Homebrew, or point a Linux box at it.

Then open **http://localhost:8080**, or watch the terminal display with
`docker compose logs -f`. Output is sorted by what the disc turned out to be:

```
out/
├── movies/   THE_MATRIX.iso, THE_MATRIX_disc2.iso, …
├── music/    Radiohead/OK Computer/01 - Airbag.mp3, …
├── data/     BACKUP_2019.iso, …
└── logs/     sr0.log, sr1.log, …
```

---

## Why Windows needs work

Docker Desktop runs containers inside the WSL2 VM, and Microsoft's stock WSL2
kernel is built without optical-drive support:

```
# CONFIG_BLK_DEV_SR is not set      <- no /dev/sr* can ever appear
# CONFIG_USB_STORAGE is not set     <- USB mass storage not recognised
```

No container flag works around a missing driver — not `--privileged`, not
`--device`, not bind-mounting `/dev`. `setup-windows.ps1` builds a WSL2 kernel
from Microsoft's own source with exactly three symbols added
(`BLK_DEV_SR`, `USB_STORAGE`, `USB_UAS`), points `.wslconfig` at it, and
installs usbipd-win. Everything else the ripper needs — SCSI core, `sg`,
ISO9660, UDF, the usbip virtual hub — is already enabled upstream.

**USB drives only on Windows.** Internal SATA optical drives cannot be
forwarded into WSL2; there is no SATA passthrough. Linux has no such limit.

---

## What it eats

Discs are identified automatically and sorted into subdirectories.

| Disc | Goes to | How |
|---|---|---|
| **Video DVD** | `out/movies/` | `dvdbackup` + `genisoimage`, CSS handled by libdvdcss |
| **Audio CD** | `out/music/` | `abcde`: MusicBrainz lookup, cdparanoia read, tagged MP3 (LAME `-V0`) or FLAC |
| **Data disc** | `out/data/` | Sector-for-sector image, bounded by the volume size |

Audio is checked first, so an *enhanced CD* (audio tracks plus a data session)
is ripped as music rather than as a data image. Music lands as
`music/Artist/Album/01 - Track.mp3`, tagged from MusicBrainz; set
`AUDIO_FORMAT=flac` for lossless. `RIP_DATA_DISCS=0` ignores data discs.

## How things get named

Nothing ever silently overwrites or gets skipped as a duplicate.

| Disc label | Result |
|---|---|
| Distinctive (`THE_MATRIX`) | `THE_MATRIX.iso` |
| Generic (`DVD_VIDEO`, `WB_DVD`, `UNTITLED`…) | `DVD_VIDEO_2026-07-27_150000.iso` |
| No label at all | `unknown_sr0_2026-07-27_150000.iso` |
| **Distinctive, already seen** | `THE_MATRIX_disc2.iso`, `_disc3`, … |

That last row is the box-set case. Multi-disc sets routinely stamp every disc
with the *same* volume label, so a repeated distinctive label is treated as
another disc in the set and numbered, keeping the set together on disk. A
repeated *generic* label is treated as an unrelated film and timestamped
instead — half of Warner's catalogue is stamped `WB_DVD`, and those discs have
nothing to do with each other. `GENERIC_LABELS` controls that list.

**Duplicate detection doesn't use the label.** Each disc is fingerprinted —
ISO9660 metadata for discs, the TOC for audio CDs — so two different films both
labelled `DVD_VIDEO` are seen as different discs, while the *same* disc
reinserted next week is recognised and skipped rather than becoming `_disc2`.
Markers live in `out/.ripped/<fp>`; delete one to make ISOHungry hungry for
that disc again.

## Web UI

`http://localhost:8080` — a status page that mirrors the terminal display:
every drive, what it's eating, progress bars, finished items with download
links, and a log viewer. The terminal display stays exactly as it was; the web
UI is additive and reads the same state files.

Progress is measured in whatever unit is honest for the disc: bytes for films
and data images, **tracks for audio CDs**. Encoded audio is a small fraction of
the raw disc, so measuring bytes against CD size would show a finished album
sitting at about 10%.

Two things it can change, and nothing else: **name a rip while it's running**
(applied when the ISO is finalised, so you can type the real film title while
the disc spins) and **rename a finished item**, which keeps its fingerprint
marker in step so the disc stays recognised. There is no eject, no delete.

`WEB_UI=0` disables it entirely.

### Reaching it from other machines

It binds to `127.0.0.1` by default, so only the host can see it. To open it to
your LAN, create a `.env` file next to `docker-compose.yml`:

```ini
WEB_BIND=0.0.0.0
```

then `docker compose up -d --force-recreate`. It's now at
`http://<host-lan-ip>:8080` from any device on the network — phone included,
which is the point.

On **Windows** you also need a firewall rule, once:

```powershell
New-NetFirewallRule -DisplayName "ISOHungry web UI" -Direction Inbound `
  -LocalPort 8080 -Protocol TCP -Action Allow -Profile Private
```

Note `-Profile Private`. If your network is classified Public, either change
the network to Private or add `Public` here — but understand what that means
before you do it on a network you don't control.

**Know what you're exposing.** There is no authentication and no TLS. Anyone
who can reach the port can browse your library, download whole ISOs, and
rename things. That's fine on a home LAN and a bad idea anywhere else.

### Better: a private network instead of a firewall hole

If you run **Tailscale** (or another WAN), bind to its interface rather than
opening a LAN port. You get device-authenticated access from anywhere, no
firewall rule, and nothing exposed to other machines on the local network:

```ini
# .env — substitute your own tailnet address
WEB_BIND=100.x.y.z
```

Then reach it at `http://100.x.y.z:8080` from any device on your tailnet.
`tailscale ip -4` prints the address.

Or tunnel over SSH and skip network exposure altogether:

```bash
ssh -L 8080:127.0.0.1:8080 you@host    # then use http://localhost:8080
```

---

## What it says

| Status | Meaning |
|---|---|
| 🍪 `Me hungry... feed me disc!` | Drive empty, waiting |
| 🍪 `NOM NOM NOM! Eating X` | Ripping a video DVD |
| 🎵 `NOM NOM! Slurping X` | Ripping and encoding an audio CD |
| 🍪 `NOM NOM! Eating data X` | Imaging a data disc |
| 😋 `Om nom nom... chewing into ISO` | Building the ISO |
| 🤤 `BUUURP! Me ate X` | Done |
| 💨 `BURP! Spit out X` | Ejected, ready for the next |
| 🙃 `Me already ate dis! (X)` | Seen before, ejected untouched |
| 😋 `Me full! Waiting (2/2 eating)` | At `MAX_PARALLEL`, queued |
| 😢 `Tummy full! Need NNNMB` | Not enough disk space; waits |
| 🙅 `Me no eat data discs` | A data disc, and `RIP_DATA_DISCS=0` |
| 🤮 `Me no like dis disc!` | Video/data rip failed — check `out/logs/` |
| 🤮 `Me no like dis CD!` | Audio rip failed — check `out/logs/` |
| 😝 `Dis not movie!` | Claimed to have `VIDEO_TS`, but the extract had none |
| 😝 `No music came out!` | Audio CD produced no encoded tracks |
| 😤 `Disc stuck in me teeth!` | Eject failed, pull it out yourself |
| 😵 `Drive no talk to me!` | Drive stopped responding |

---

## Configuration

Set these in `docker-compose.yml` under `environment:`, except `WEB_BIND`,
which belongs in a `.env` file beside it because it's machine-specific.

| Variable | Default | Meaning |
|---|---|---|
| `BASE_OUTPUT_DIR` | `/output` | Where output is written |
| `POLL_INTERVAL` | `5` | Seconds between drive scans |
| `MAX_PARALLEL` | `2` | Concurrent rips — USB drives on one controller thrash above this |
| `SPACE_FACTOR` | `22` | Free space required, in tenths of disc size (2.2×) |
| `PROBE_TIMEOUT` | `30` | Seconds before a wedged drive is given up on |
| `GENERIC_LABELS` | see script | Labels too common to trust as filenames |
| `AUDIO_FORMAT` | `mp3` | `mp3` (LAME `-V0`, ~245 kbps VBR) or `flac` |
| `RIP_DATA_DISCS` | `1` | `0` to ignore non-video, non-audio discs |
| `WEB_UI` / `WEB_PORT` | `1` / `8080` | Web status page |
| `WEB_BIND` *(.env)* | `127.0.0.1` | Interface the UI listens on |
| `DEVICE_GLOB` | `/dev/sr*` | Which devices to watch |
| `TZ` | — | Timezone for the clock |

**Disk space.** Video DVDs are the hungry case: `dvdbackup` extracts the disc
and then `genisoimage` builds the ISO from the extract, so roughly **2× disc
size** is needed while working — the default `SPACE_FACTOR=22` reserves 2.2×.
Data discs need about 1×, and audio CDs need far less once encoded. If there
isn't room, the drive waits rather than failing partway through.

---

## Attaching drives on Windows

`.\scripts\attach-drives.ps1` finds every USB optical drive, binds it (one UAC
prompt) and attaches it into the VM. Re-run after every reboot or
`wsl --shutdown` — binding persists, attaching doesn't. `-Detach` gives the
drives back to Windows.

Drives are matched by USB *instance* ID, not vendor/product ID, so two
identical drives are never mixed up.

<details>
<summary>Why not just <code>usbipd attach --wsl</code>?</summary>

It fails here. usbipd insists on `modprobe vhci_hcd`, which can't succeed when
the driver is built into the kernel rather than a module — and our kernel
builds it in. The script drives the `usbip` client directly instead.

It must run with `--network host`. The TCP socket backing the virtual USB port
lives in the caller's network namespace; in a normal container namespace that
socket dies with the container, leaving the device present but wedged in
**unkillable** I/O that survives `timeout` and needs `wsl --shutdown` to clear.
</details>

---

## Troubleshooting

**No drives listed** — on Windows, did you run `attach-drives.ps1`? Check with
`docker run --rm --privileged -v /dev:/dev alpine ls /dev/sr0`.

**`🤮 Me no like dis disc!` / `Me no like dis CD!`** — usually a scratched or
unusually protected disc. The real error is in `out/logs/<device>.log`.

**`😝 Dis not movie!`** — the disc's index advertised a `VIDEO_TS` directory,
but the extraction produced none. That means a failed or partial `dvdbackup`
run, not a data disc: discs without `VIDEO_TS` are detected up front and
imaged into `out/data/` instead. Check the log.

**`😝 No music came out!`** — `abcde` finished but wrote no tracks. Usually a
MusicBrainz lookup that failed alongside a read error; the log has both.

**Music has no artist or album name** — MusicBrainz had no match for that
disc, so `abcde` fell back to placeholder names. Rename it from the web UI, or
name it while it rips.

**Rename says "file is in use"** — something has the file open. On Windows the
usual culprit is the ISO being *mounted* as a virtual drive: double-clicking an
ISO in Explorer mounts it, and Windows then holds an exclusive lock, so neither
the container nor Windows itself can rename it. Eject the virtual drive and try
again. To check:

```powershell
Get-DiskImage -ImagePath C:\path\to\out\movies\YOUR.iso | Select-Object Attached
Dismount-DiskImage -ImagePath C:\path\to\out\movies\YOUR.iso
```

**`😵 Drive no talk to me!`** — the drive stopped responding. On Windows this
usually means the usbip attachment dropped; re-run `attach-drives.ps1`.

**Rips are slow** — USB optical drives read at 2–10 MB/s, so a full disc takes
20–60 minutes. That's the drive, not the software.

**Kernel didn't take** — `uname -r` inside a container should end in `+`.
Docker Desktop pins the VM alive, so `wsl --shutdown` without quitting Docker
Desktop first often leaves the old kernel running.

---

## Reverting (Windows)

Delete the `kernel=` line from `%USERPROFILE%\.wslconfig` and run
`wsl --shutdown`. Optionally `winget uninstall dorssel.usbipd-win` and delete
`%USERPROFILE%\wsl-kernel`.

---

## Layout

| Path | Purpose |
|---|---|
| `isohungry.sh` | The ripper |
| `web/server.py`, `web/index.html` | Web status page (stdlib only) |
| `entrypoint.sh` | Starts the web UI, then runs the terminal display |
| `Dockerfile` | Two stages: libdvdcss + gum, then a Debian runtime |
| `docker-compose.yml` | Privileged service, `/dev` and `./out` mounts |
| `.env` *(optional, untracked)* | Machine-specific settings — currently just `WEB_BIND` |
| `setup.sh` | Linux/macOS setup |
| `scripts/setup-windows.ps1` | Windows one-time setup |
| `scripts/attach-drives.ps1` | Per-boot USB attach/detach |
| `kernel/build-wsl-kernel.sh` | Reproducible WSL2 kernel build |

Commercial DVDs are CSS-scrambled; libdvdcss is built from VideoLAN source in
a throwaway stage, so `libdvdread` finds it at rip time with nothing extra to
install. Audio CDs go through `abcde`, which wraps cdparanoia, MusicBrainz and
LAME/FLAC.

---

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free for personal, hobby,
research and educational use. Commercial use or resale requires a separate
written licence from the author.

ISOHungry ships no third-party code itself. The container image installs
dvdbackup, cdrkit, libdvdcss, abcde, cdparanoia, LAME, FLAC and usbip at build
time, and each stays under its own terms (mostly GPL/LGPL); `gum` is MIT, and
the custom WSL2 kernel remains GPLv2.

Rip only discs you're entitled to copy — rules vary by jurisdiction, and what
you do with this is on you.
