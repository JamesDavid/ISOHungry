# 🍪 ISOHungry

**ME EAT DVD. ME MAKE ISO. OM NOM NOM.**

Feed it discs, it eats them. Watches every optical drive it can see, devours
each disc into an ISO, burps, ejects, and waits for the next one. Several
drives at once. Runs in a container, so the only thing you install is Docker.

```
🍪 ISOHungry — me eat DVD! (updated 14:22:07)
========================================================
sr0   | 🍪 NOM NOM NOM! Eating BLADE_RUN | 00:12:41
sr1   | 😋 Om nom nom... chewing into IS | 00:31:08
sr2   | 🤤 BUUURP! Me ate THE_MATRIX     | 00:44:52
sr3   | 🍪 Me hungry... feed me disc!    | --:--:--
```

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

ISOs land in `./out/`.

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

## How discs get named

Nothing ever silently overwrites or gets skipped as a duplicate.

| Disc label | Result |
|---|---|
| Distinctive (`THE_MATRIX`) | `THE_MATRIX.iso` |
| Generic (`DVD_VIDEO`, `WB_DVD`, `UNTITLED`…) | `DVD_VIDEO_2026-07-27_150000.iso` |
| No label at all | `unknown_sr0_2026-07-27_150000.iso` |
| Distinctive but already taken | `THE_MATRIX_2026-07-27_161500.iso` |

Generic labels are shared by countless unrelated discs — half of Warner's
catalogue is stamped `WB_DVD` — so those always get the rip timestamp. The
list is in `GENERIC_LABELS` and you can override it.

**Duplicate detection doesn't use the label.** Each disc is fingerprinted by
hashing its ISO9660 metadata, so two different films both labelled `DVD_VIDEO`
are correctly seen as different discs, while the *same* disc reinserted next
week is recognised and skipped. Markers live in `out/.ripped/<fp>`; delete one
to make ISOHungry hungry for that disc again.

---

## What it says

| Status | Meaning |
|---|---|
| 🍪 `Me hungry... feed me disc!` | Drive empty, waiting |
| 🍪 `NOM NOM NOM! Eating X` | Ripping the disc |
| 😋 `Om nom nom... chewing into ISO` | Building the ISO |
| 🤤 `BUUURP! Me ate X` | Done |
| 💨 `BURP! Spit out X` | Ejected, ready for the next |
| 🙃 `Me already ate dis! (X)` | Seen before, ejected untouched |
| 😋 `Me full! Waiting (2/2 eating)` | At `MAX_PARALLEL`, queued |
| 😢 `Tummy full! Need NNNMB` | Not enough disk space; waits |
| 🤮 `Me no like dis disc!` | Rip failed — check `out/logs/` |
| 😝 `Dis not movie!` | No `VIDEO_TS`; not a video DVD |
| 😤 `Disc stuck in me teeth!` | Eject failed, pull it out yourself |
| 😵 `Drive no talk to me!` | Drive stopped responding |

---

## Configuration

Set these in `docker-compose.yml` under `environment:`.

| Variable | Default | Meaning |
|---|---|---|
| `BASE_OUTPUT_DIR` | `/output` | Where ISOs are written |
| `POLL_INTERVAL` | `5` | Seconds between drive scans |
| `MAX_PARALLEL` | `2` | Concurrent rips — USB drives on one controller thrash above this |
| `SPACE_FACTOR` | `22` | Free space required, in tenths of disc size (2.2×) |
| `PROBE_TIMEOUT` | `30` | Seconds before a wedged drive is given up on |
| `GENERIC_LABELS` | see script | Labels too common to trust as filenames |
| `DEVICE_GLOB` | `/dev/sr*` | Which devices to watch |
| `TZ` | — | Timezone for the clock |

It needs roughly **2× disc size** free while working (the extract plus the
ISO), and waits rather than failing if there isn't room.

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

**`🤮 Me no like dis disc!`** — usually a scratched or unusually protected
disc. The real error is in `out/logs/<device>.log`.

**`😝 Dis not movie!`** — the disc has no `VIDEO_TS`. Data DVDs aren't handled.

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
| `04_gum_auto_dvd_backup.sh` | The ripper |
| `Dockerfile` | Two stages: libdvdcss + gum, then a slim Debian runtime |
| `docker-compose.yml` | Privileged service, `/dev` and `./out` mounts |
| `setup.sh` | Linux/macOS setup |
| `scripts/setup-windows.ps1` | Windows one-time setup |
| `scripts/attach-drives.ps1` | Per-boot USB attach/detach |
| `kernel/build-wsl-kernel.sh` | Reproducible WSL2 kernel build |

Commercial DVDs are CSS-scrambled; libdvdcss is built from VideoLAN source in
a throwaway stage, so `libdvdread` finds it at rip time with nothing extra to
install. Rip only discs you're entitled to copy — rules vary by jurisdiction.
