#!/usr/bin/env bash
# One-shot setup for Linux and macOS. Windows users: run scripts\setup-windows.ps1
#
#   git clone <repo> && cd AutoDVDBackup && ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

bold "AutoDVDBackup setup"
echo

case "$(uname -s)" in

  Linux)
    command -v docker >/dev/null || die "Docker not found. Install Docker Engine, then re-run."
    docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Start it (or add yourself to the 'docker' group)."

    echo "Platform: Linux — optical drives are available natively, no extra plumbing."
    echo

    shopt -s nullglob
    drives=(/dev/sr*)
    if (( ${#drives[@]} == 0 )); then
      warn "No /dev/sr* devices found. Plug in a drive; the ripper picks it up automatically."
    else
      echo "Drives detected:"
      for d in "${drives[@]}"; do echo "  $d"; done
    fi
    echo

    # Reading a raw optical device needs group access; the container runs
    # privileged, so this only matters if you also run the script on the host.
    if [ -e /dev/sr0 ] && [ ! -r /dev/sr0 ]; then
      warn "You lack read access to /dev/sr0 on the host (group 'cdrom')."
      warn "The container runs privileged so it works regardless, but for host use:"
      warn "  sudo usermod -aG cdrom \$USER   # then log out and back in"
      echo
    fi

    bold "Building image..."
    docker compose build
    echo
    bold "Done. Start it with:"
    echo "  docker compose up -d       # background"
    echo "  docker compose logs -f     # watch the status display"
    echo
    echo "ISOs are written to ./out/"
    ;;

  Darwin)
    command -v docker >/dev/null || die "Docker not found. Install Docker Desktop, then re-run."

    warn "Platform: macOS — this is the one platform where drive passthrough is not possible."
    echo
    echo "Docker Desktop on macOS runs a Linux VM on Virtualization.framework, which"
    echo "exposes no USB or optical device passthrough, and macOS has no usbipd"
    echo "equivalent. A container here will start and render its display, but will"
    echo "never see a drive. This is a platform limitation, not a configuration one."
    echo
    bold "Your options on a Mac:"
    echo "  1. Run the ripper natively (no Docker):"
    echo "       brew install dvdbackup cdrtools"
    echo "       BASE_OUTPUT_DIR=\"\$HOME/Videos/DVDs\" DEVICE_GLOB='/dev/disk*' \\"
    echo "         ./04_gum_auto_dvd_backup.sh"
    echo "     Note macOS names optical devices /dev/disk*, not /dev/sr*, and ships"
    echo "     no libdvdcss — encrypted discs need it from Homebrew."
    echo "  2. Run this repo on a Linux box that has the drives attached."
    echo
    read -r -p "Build the image anyway (useful for testing the pipeline)? [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      docker compose build
      echo
      warn "Image built. It will report 'No disc' forever until run somewhere with drives."
    fi
    ;;

  *)
    die "Unsupported platform: $(uname -s). Windows users run: scripts\\setup-windows.ps1"
    ;;
esac
