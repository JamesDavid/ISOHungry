#!/bin/bash
#  ___ ____   ___  _   _
# |_ _/ ___| / _ \| | | |_   _ _ __   __ _ _ __ _   _
#  | |\___ \| | | | |_| | | | | '_ \ / _` | '__| | | |
#  | | ___) | |_| |  _  | |_| | | | | (_| | |  | |_| |
# |___|____/ \___/|_| |_|\__,_|_| |_|\__, |_|   \__, |
#                                    |___/      |___/
# ME EAT DVD. ME MAKE ISO. OM NOM NOM.
#
# Watches every optical drive, devours each disc into an ISO, burps, ejects,
# and waits for the next one. Several drives at once, bounded by MAX_PARALLEL.
#
# Config (all optional, read from the environment):
#   BASE_OUTPUT_DIR  where ISOs are written        (default ~/Videos/DVDs)
#   POLL_INTERVAL    seconds between drive scans   (default 5)
#   MAX_PARALLEL     concurrent rips               (default 2)
#   SPACE_FACTOR     free space required, in tenths of disc size (default 22 = 2.2x)
#   PROBE_TIMEOUT    seconds before a wedged drive is given up on (default 30)
#   GENERIC_LABELS   labels too common to trust as filenames; these get a timestamp

set -uo pipefail
shopt -s extglob nullglob

BASE_OUTPUT_DIR="${BASE_OUTPUT_DIR:-$HOME/Videos/DVDs}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_PARALLEL="${MAX_PARALLEL:-2}"
SPACE_FACTOR="${SPACE_FACTOR:-22}"
DEVICE_GLOB="${DEVICE_GLOB:-/dev/sr*}"   # overridable so the state machine can be tested
# A drive that stops responding (flaky USB, dying disc) can block a read
# indefinitely. Without a cap, one bad drive stalls the scan for every drive.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"

AUDIO_FORMAT="${AUDIO_FORMAT:-mp3}"      # mp3 (LAME -V0 VBR, ~245kbps) or flac
RIP_DATA_DISCS="${RIP_DATA_DISCS:-1}"    # 0 to ignore non-video, non-audio discs

# Persistent, on the output volume. Each disc kind lands in its own subdirectory.
LOG_DIR="$BASE_OUTPUT_DIR/logs"
FP_DIR="$BASE_OUTPUT_DIR/.ripped"     # fingerprint -> output name, "have I seen this disc"
WORK_DIR="$BASE_OUTPUT_DIR/.work"     # scratch space for extraction and encoding
MOVIE_DIR="$BASE_OUTPUT_DIR/movies"
MUSIC_DIR="$BASE_OUTPUT_DIR/music"
DATA_DIR="$BASE_OUTPUT_DIR/data"

PENDING_DIR="$BASE_OUTPUT_DIR/.pending"  # fingerprint -> friendly name chosen from the web UI

# Ephemeral, per run
LOCK_DIR="/tmp/dvd_rip_processed"     # one file per ACTIVE rip (also the concurrency counter)
STATUS_DIR="/tmp/dvd_rip_status"      # one file per drive, drives the TUI
HANDLED_DIR="/tmp/dvd_rip_handled"    # per drive: fingerprint of the disc already dealt with
META_DIR="/tmp/dvd_rip_meta"          # per drive: structured detail for the web UI
                                      # (kept out of STATUS_DIR, whose glob feeds the TUI)

mkdir -p "$BASE_OUTPUT_DIR" "$LOG_DIR" "$FP_DIR" "$WORK_DIR" "$PENDING_DIR" \
         "$MOVIE_DIR" "$MUSIC_DIR" "$DATA_DIR" \
         "$LOCK_DIR" "$STATUS_DIR" "$HANDLED_DIR" "$META_DIR"

# A previous run may have died mid-write. Partial ISOs are never valid, and
# leaving one behind would make it look like the disc was already ripped.
find "$BASE_OUTPUT_DIR" -maxdepth 2 -name '*.iso.partial' -delete 2>/dev/null
rm -rf "${WORK_DIR:?}"/*
rm -f "${LOCK_DIR:?}"/* "${HANDLED_DIR:?}"/*

command -v gum >/dev/null 2>&1 && USE_GUM=1 || USE_GUM=0

# ---------------------------------------------------------------- utilities

# Display width, approximated: emoji and CJK occupy two terminal columns but
# one character, so printf's %-30s (which counts characters) misaligns them.
vwidth() {
  local s=$1 w=0 i c cp
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    printf -v cp '%d' "'$c" 2>/dev/null || cp=63
    if (( cp == 0xFE0F || cp == 0x200D || cp < 32 )); then
      continue                                    # variation selector / ZWJ / control
    elif (( (cp >= 0x1100  && cp <= 0x115F)  || (cp >= 0x2E80  && cp <= 0x303E) || \
            (cp >= 0x3041  && cp <= 0x33FF)  || (cp >= 0x3400  && cp <= 0x4DBF) || \
            (cp >= 0x4E00  && cp <= 0x9FFF)  || (cp >= 0xA000  && cp <= 0xA4CF) || \
            (cp >= 0xAC00  && cp <= 0xD7A3)  || (cp >= 0xF900  && cp <= 0xFAFF) || \
            (cp >= 0xFE30  && cp <= 0xFE6F)  || (cp >= 0xFF00  && cp <= 0xFF60) || \
            (cp >= 0xFFE0  && cp <= 0xFFE6)  || (cp >= 0x23E9  && cp <= 0x23FA) || \
            (cp >= 0x25FD  && cp <= 0x25FE)  || (cp >= 0x2614  && cp <= 0x2615) || \
            (cp >= 0x2648  && cp <= 0x2653)  || (cp >= 0x26AA  && cp <= 0x26AB) || \
            (cp >= 0x26BD  && cp <= 0x26BE)  || (cp >= 0x26C4  && cp <= 0x26C5) || \
            (cp >= 0x2753  && cp <= 0x2755)  || (cp >= 0x2795  && cp <= 0x2797) || \
            (cp >= 0x2B1B  && cp <= 0x2B1C)  || (cp >= 0x1F300 && cp <= 0x1F64F) || \
            (cp >= 0x1F680 && cp <= 0x1F6FF) || (cp >= 0x1F900 && cp <= 0x1F9FF) || \
            (cp >= 0x1FA70 && cp <= 0x1FAFF) || \
            cp == 0x2705 || cp == 0x270A || cp == 0x270B || cp == 0x2728 || \
            cp == 0x274C || cp == 0x274E || cp == 0x2757 || cp == 0x27B0 || \
            cp == 0x27BF || cp == 0x26A1 || cp == 0x26D4 || cp == 0x2B50 || \
            cp == 0x2B55 || cp == 0x231A || cp == 0x231B )); then
      (( w += 2 ))
    else
      (( w += 1 ))
    fi
  done
  printf '%d' "$w"
}

# Truncate to a display width, then pad out to it. Replaces printf %-Ns.
fit() {
  local s=$1 target=$2 out="" w=0 i c cw
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    cw=$(vwidth "$c")
    (( w + cw > target )) && break
    out+=$c
    (( w += cw ))
  done
  printf '%s%*s' "$out" "$(( target - w ))" ''
}

# Labels that countless unrelated discs share. Anything matching gets a
# timestamp appended so two different films never fight over one filename.
GENERIC_LABELS="${GENERIC_LABELS:-DVD_VIDEO DVDVIDEO DVD DVD_ROM DVDROM VIDEO VIDEO_DVD VIDEO_TS UNTITLED UNNAMED UNKNOWN NEW_VOLUME MOVIE FEATURE WB_DVD DVDVOLUME}"

is_generic_label() {
  local l=${1^^} g
  for g in $GENERIC_LABELS; do [ "$l" = "$g" ] && return 0; done
  return 1
}

sanitize_label() {
  local raw=$1 clean
  clean=${raw//[^A-Za-z0-9._-]/_}   # keep paths safe; label goes into rm -rf later
  clean=${clean##+([._-])}          # no leading dot/dash: hidden files, getopt confusion
  clean=${clean:0:64}
  [ -z "$clean" ] && clean="unknown"
  printf '%s' "$clean"
}

set_status() { printf '%s|%s\n' "$2" "${3:-}" > "$STATUS_DIR/$1"; }

# Identify a disc by its ISO9660 metadata. Two unrelated discs both labelled
# DVD_VIDEO hash differently, so they no longer collide.
disc_fingerprint() { printf '%s' "$1" | md5sum | cut -c1-10; }

disc_bytes() {
  local info=$1 bs vs
  bs=$(sed -n 's/^Logical block size is: *//p' <<< "$info" | head -1)
  vs=$(sed -n 's/^Volume size is: *//p'        <<< "$info" | head -1)
  [[ "$bs" =~ ^[0-9]+$ ]] || bs=2048
  [[ "$vs" =~ ^[0-9]+$ ]] || { printf '0'; return; }
  printf '%d' $(( bs * vs ))
}

free_bytes() { df -B1 --output=avail "$BASE_OUTPUT_DIR" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# --- disc identification ----------------------------------------------------
# What kind of disc is this? Audio is checked first: an "enhanced CD" carries
# both a data session and audio tracks, and the music is the interesting part.

disc_mode() {
  timeout "$PROBE_TIMEOUT" cd-info --no-device-info --no-cddb -q "$1" 2>/dev/null \
    | sed -n 's/^Disc mode: *//p' | head -1
}

# cdparanoia's TOC query is a fallback for drives cd-info can't read.
has_audio_tracks() {
  timeout "$PROBE_TIMEOUT" cdparanoia -Q -d "$1" 2>&1 | grep -qE '^ *[0-9]+\.'
}

# TOC-derived identity for audio CDs, which have no ISO9660 metadata to hash.
audio_toc() { timeout "$PROBE_TIMEOUT" cd-discid "$1" 2>/dev/null; }

# cd-discid's last field is the disc length in seconds; CDDA is 176400 B/s.
audio_bytes() {
  local toc=$1 secs
  secs=${toc##* }
  [[ "$secs" =~ ^[0-9]+$ ]] || { printf '0'; return; }
  printf '%d' $(( secs * 176400 ))
}

has_video_ts() {
  timeout "$PROBE_TIMEOUT" isoinfo -f -i "$1" 2>/dev/null | grep -qi '/VIDEO_TS'
}

try_eject() {
  local device=$1 dev_name=$2 start=$3 context=${4:-}
  if timeout "$PROBE_TIMEOUT" eject "$device" 2>>"$LOG_DIR/$dev_name.log"; then
    return 0
  fi
  # Keep naming the disc: this status replaces whatever it was doing, and
  # "eject failed" alone doesn't tell you which disc to pull out.
  set_status "$dev_name" "😤 Disc stuck in me teeth${context:+: $context}!" "$start"
  return 1
}

# ---------------------------------------------------------------------- TUI

render_status() {
  local buf now line status_file dev content state start elapsed hms
  local offset offset_file status_len scroll
  printf -v now '%(%H:%M:%S)T' -1

  line="🍪 ISOHungry — me eat DVD! (updated $now)"
  (( USE_GUM )) && line=$(gum style --bold --foreground 212 "$line")

  # Repaint over the previous frame instead of clear+redraw, which flickers.
  buf=$'\033[H'"$line"$'\033[K\n'
  buf+="========================================================"$'\033[K\n'

  for status_file in "$STATUS_DIR"/*; do
    [ -f "$status_file" ] || continue
    dev=${status_file##*/}
    content=$(< "$status_file")

    state=${content%%|*}
    start=${content#*|}
    [[ "$start" =~ ^[0-9]+$ ]] || start=""

    if [ -n "$start" ]; then
      elapsed=$(( $(printf '%(%s)T' -1) - start ))
      printf -v hms "%02d:%02d:%02d" \
        $(( elapsed / 3600 )) $(( (elapsed / 60) % 60 )) $(( elapsed % 60 ))
    else
      hms="--:--:--"
    fi

    # Scroll anything too long to fit. Slicing is character-wise, so with a
    # UTF-8 locale it no longer cuts multi-byte emoji in half.
    offset_file="/tmp/.scroll_offset_$dev"
    status_len=${#state}
    if (( $(vwidth "$state") > 30 )); then
      offset=0
      [ -f "$offset_file" ] && offset=$(< "$offset_file")
      [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
      scroll="$state   $state"
      state=${scroll:offset}
      printf '%d' $(( (offset + 1) % (status_len + 3) )) > "$offset_file"
    fi

    buf+="$(fit "$dev" 5) | $(fit "$state" 30) | $hms"$'\033[K\n'
  done

  buf+=$'\033[J'
  printf '%s' "$buf"
}

# --------------------------------------------------------------------- rip

# Structured detail for the web UI. The TUI reads STATUS_DIR only, so this is
# purely additive — nothing here changes what the terminal shows.
write_meta() {
  local dev_name=$1
  shift
  printf '%s\n' "$@" > "$META_DIR/$dev_name"
}

# Resolve the friendly name set from the web UI, if any. Echoes it or nothing.
pending_name() {
  local fp=$1 friendly
  [ -s "$PENDING_DIR/$fp" ] || return 1
  friendly=$(sanitize_label "$(< "$PENDING_DIR/$fp")")
  rm -f "$PENDING_DIR/$fp"
  [ -n "$friendly" ] && [ "$friendly" != "unknown" ] || return 1
  printf '%s' "$friendly"
}

# --- audio CDs --------------------------------------------------------------
# abcde handles the whole chain: MusicBrainz lookup, cdparanoia read, encode,
# tag and file layout. We rip into scratch and move the finished album into
# place, so a killed run never leaves a half-encoded album in the library.
rip_audio() {
  local device=$1 dev_name=$2 label=$4 fp=$5 start=$6 total_bytes=${7:-0}
  local logfile="$LOG_DIR/$dev_name.log"
  local scratch="$WORK_DIR/$dev_name"
  local conf="$scratch/abcde.conf"
  local album_src album_rel target friendly stamp

  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" "kind=audio" \
    "total_bytes=$total_bytes" "scratch=$scratch" "phase=ripping"

  echo "=== $(date -Is) $dev_name  AUDIO CD  fp=$fp  format=$AUDIO_FORMAT" >> "$logfile"

  rm -rf "$scratch"; mkdir -p "$scratch"

  mkdir -p "$scratch/wrk"
  cat > "$conf" <<EOF
# Try MusicBrainz, then fall back to gnudb: one flaky lookup shouldn't decide
# whether the disc gets ripped at all.
CDDBMETHOD=musicbrainz,cddb
CDDBCOPYLOCAL=n
CDDBTOUT=15
CDROMREADERSYNTAX=cdparanoia
# Without this abcde writes its temp WAVs to /, filling the container layer
# instead of the output volume.
WRKDIR="$scratch/wrk"
OUTPUTDIR="$scratch/out"
OUTPUTTYPE="$AUDIO_FORMAT"
LAMEOPTS="-V 0 --vbr-new -q 0"
FLACOPTS="-s -e -V -8"
MAXPROCS=2
PADTRACKS=y
EJECTCD=n
INTERACTIVE=n
ACTIONS=cddb,read,encode,tag,move,clean
OUTPUTFORMAT='\${ARTISTFILE}/\${ALBUMFILE}/\${TRACKNUM} - \${TRACKFILE}'
VAOUTPUTFORMAT='Various Artists/\${ALBUMFILE}/\${TRACKNUM} - \${ARTISTFILE} - \${TRACKFILE}'
EOF

  set_status "$dev_name" "🎵 NOM NOM! Slurping $label" "$start"
  if ! HOME="$scratch" abcde -N -d "$device" -c "$conf" >> "$logfile" 2>&1; then
    # A metadata lookup that times out shouldn't cost you the disc. Retry
    # without the lookup: untagged audio you can name later beats nothing.
    echo "=== lookup or rip failed; retrying without metadata lookup" >> "$logfile"
    set_status "$dev_name" "🎵 No match — slurping untagged" "$start"
    rm -rf "$scratch"/.abcde.* "$scratch/wrk" 2>/dev/null
    mkdir -p "$scratch/wrk"
    sed 's/^ACTIONS=.*/ACTIONS=read,encode,tag,move,clean/' "$conf" > "$conf.nolookup"
    if ! HOME="$scratch" abcde -N -d "$device" -c "$conf.nolookup" >> "$logfile" 2>&1; then
      set_status "$dev_name" "🤮 Me no like dis CD! see logs/$dev_name.log" "$start"
      echo "!!! abcde failed, with and without metadata" >> "$logfile"
      rm -rf "$scratch"; rm -f "$LOCK_DIR/$dev_name"
      try_eject "$device" "$dev_name" "$start" "$label"
      return 1
    fi
    echo "=== ripped without metadata; rename it from the web UI" >> "$logfile"
  fi

  # abcde writes <artist>/<album>/; find the deepest directory holding tracks.
  album_src=$(find "$scratch/out" -type f \( -name "*.$AUDIO_FORMAT" \) -printf '%h\n' 2>/dev/null | sort -u | head -1)
  if [ -z "$album_src" ]; then
    set_status "$dev_name" "😝 No music came out! see logs/$dev_name.log" "$start"
    echo "!!! no encoded tracks produced" >> "$logfile"
    rm -rf "$scratch"; rm -f "$LOCK_DIR/$dev_name"
    try_eject "$device" "$dev_name" "$start" "$label"
    return 1
  fi

  album_rel=${album_src#"$scratch/out/"}
  if friendly=$(pending_name "$fp"); then
    album_rel="$friendly"
    echo "=== friendly name applied: $friendly" >> "$logfile"
  fi

  target="$MUSIC_DIR/$album_rel"
  if [ -e "$target" ]; then
    printf -v stamp '%(%Y-%m-%d_%H%M%S)T' -1
    target="${target}_${stamp}"
  fi
  mkdir -p "$(dirname "$target")"
  mv -f "$album_src" "$target"
  sync

  printf '%s\n' "music/${target#"$MUSIC_DIR/"}" > "$FP_DIR/$fp"
  echo "=== done $(date -Is) -> $target" >> "$logfile"

  rm -rf "$scratch"
  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" "kind=audio" \
    "total_bytes=$total_bytes" "iso_path=$target" "phase=done"
  set_status "$dev_name" "🤤 BUUURP! Me ate ${target##*/}" "$start"
  try_eject "$device" "$dev_name" "$start" "$label" && \
    set_status "$dev_name" "💨 BURP! Spit out ${target##*/}" "$start"
  rm -f "$LOCK_DIR/$dev_name"
}

# --- data discs -------------------------------------------------------------
# A plain sector-for-sector image. The volume size from the ISO9660 descriptor
# bounds the read, so we don't run off the end of the disc.
rip_data() {
  local device=$1 dev_name=$2 iso_path=$3 label=$4 fp=$5 start=$6 total_bytes=${7:-0}
  local logfile="$LOG_DIR/$dev_name.log"
  local partial="$iso_path.partial"
  local blocks friendly stamp

  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" "kind=data" \
    "total_bytes=$total_bytes" "iso_path=$iso_path" "partial=$partial" "phase=ripping"

  echo "=== $(date -Is) $dev_name  DATA DISC  label=$label  fp=$fp -> $iso_path" >> "$logfile"

  set_status "$dev_name" "🍪 NOM NOM! Eating data $label" "$start"
  blocks=$(( total_bytes / 2048 ))
  if (( blocks > 0 )); then
    dd if="$device" of="$partial" bs=2048 count="$blocks" >> "$logfile" 2>&1
  else
    dd if="$device" of="$partial" bs=2048 >> "$logfile" 2>&1
  fi
  if (( $? != 0 )); then
    set_status "$dev_name" "🤮 Me no like dis disc! see logs/$dev_name.log" "$start"
    echo "!!! dd failed" >> "$logfile"
    rm -f "$partial"; rm -f "$LOCK_DIR/$dev_name"
    try_eject "$device" "$dev_name" "$start" "$label"
    return 1
  fi

  sync
  if friendly=$(pending_name "$fp"); then
    printf -v stamp '%(%Y-%m-%d_%H%M%S)T' -1
    iso_path="$DATA_DIR/${friendly}.iso"
    [ -e "$iso_path" ] && iso_path="$DATA_DIR/${friendly}_${stamp}.iso"
    echo "=== friendly name applied: $friendly" >> "$logfile"
  fi

  mv -f "$partial" "$iso_path"
  printf '%s\n' "data/${iso_path##*/}" > "$FP_DIR/$fp"
  echo "=== done $(date -Is) -> $iso_path" >> "$logfile"

  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" "kind=data" \
    "total_bytes=$total_bytes" "iso_path=$iso_path" "phase=done"
  set_status "$dev_name" "🤤 BUUURP! Me ate $label" "$start"
  try_eject "$device" "$dev_name" "$start" "$label" && \
    set_status "$dev_name" "💨 BURP! Spit out $label" "$start"
  rm -f "$LOCK_DIR/$dev_name"
}

# --- video DVDs -------------------------------------------------------------
rip_disc() {
  local device=$1 dev_name=$2 iso_path=$3 label=$4 fp=$5 start=$6 total_bytes=${7:-0}
  local logfile="$LOG_DIR/$dev_name.log"
  local scratch="$WORK_DIR/$dev_name"
  local partial="$iso_path.partial"
  local extract_dir friendly stamp

  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" \
    "total_bytes=$total_bytes" "iso_path=$iso_path" "scratch=$scratch" "phase=ripping"

  {
    echo "=== $(date -Is) $dev_name  label=$label  fp=$fp -> $iso_path"
  } >> "$logfile"

  rm -rf "$scratch"
  mkdir -p "$scratch"

  set_status "$dev_name" "🍪 NOM NOM NOM! Eating $label" "$start"
  if ! dvdbackup -M -i "$device" -o "$scratch" >> "$logfile" 2>&1; then
    set_status "$dev_name" "🤮 Me no like dis disc! see logs/$dev_name.log" "$start"
    echo "!!! dvdbackup failed" >> "$logfile"
    rm -rf "$scratch"; rm -f "$LOCK_DIR/$dev_name"
    try_eject "$device" "$dev_name" "$start" "$label"
    return 1
  fi

  extract_dir=$(find "$scratch" -type d -name VIDEO_TS -print -quit)
  if [ -z "$extract_dir" ]; then
    set_status "$dev_name" "😝 Dis not movie! Me spit it out" "$start"
    echo "!!! no VIDEO_TS in extract" >> "$logfile"
    rm -rf "$scratch"; rm -f "$LOCK_DIR/$dev_name"
    try_eject "$device" "$dev_name" "$start" "$label"
    return 1
  fi

  # Build to .partial and rename only on success, so an interrupted run can
  # never leave a truncated ISO that later looks like a completed rip.
  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" \
    "total_bytes=$total_bytes" "iso_path=$iso_path" "scratch=$scratch" "phase=iso"
  set_status "$dev_name" "😋 Om nom nom... chewing into ISO" "$start"
  if ! genisoimage -dvd-video -o "$partial" "$(dirname "$extract_dir")" >> "$logfile" 2>&1; then
    set_status "$dev_name" "🤮 Me choke on dis! see logs/$dev_name.log" "$start"
    echo "!!! genisoimage failed" >> "$logfile"
    rm -f "$partial"; rm -rf "$scratch"; rm -f "$LOCK_DIR/$dev_name"
    try_eject "$device" "$dev_name" "$start" "$label"
    return 1
  fi

  sync

  # A friendly name may have been set from the web UI while this was ripping.
  # It is applied here, at finalize, so it wins over the label-derived name.
  if friendly=$(pending_name "$fp"); then
    printf -v stamp '%(%Y-%m-%d_%H%M%S)T' -1
    iso_path="$MOVIE_DIR/${friendly}.iso"
    [ -e "$iso_path" ] && iso_path="$MOVIE_DIR/${friendly}_${stamp}.iso"
    echo "=== friendly name applied: $friendly" >> "$logfile"
  fi

  mv -f "$partial" "$iso_path"
  printf '%s\n' "movies/${iso_path##*/}" > "$FP_DIR/$fp"
  echo "=== done $(date -Is) -> $iso_path" >> "$logfile"

  rm -rf "$scratch"
  write_meta "$dev_name" \
    "device=$device" "label=$label" "fp=$fp" "start=$start" \
    "total_bytes=$total_bytes" "iso_path=$iso_path" "phase=done"
  set_status "$dev_name" "🤤 BUUURP! Me ate $label" "$start"
  try_eject "$device" "$dev_name" "$start" "$label" && \
    set_status "$dev_name" "💨 BURP! Spit out $label" "$start"
  rm -f "$LOCK_DIR/$dev_name"
}

# ----------------------------------------------------------------- lifecycle

RIP_PIDS=()

cleanup() {
  trap '' INT TERM
  kill "$TUI_PID" 2>/dev/null
  local pid
  for pid in "${RIP_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  # An in-flight rip was just killed; its ISO is incomplete by definition.
  find "$BASE_OUTPUT_DIR" -maxdepth 2 -name '*.iso.partial' -delete 2>/dev/null
  rm -rf "${WORK_DIR:?}"/*
  rm -f "${LOCK_DIR:?}"/*
  printf '\033[?25h\n🍪 ISOHungry going sleep now. Me still hungry...\n'
  exit 0
}
trap cleanup INT TERM

printf '\033[?25l\033[2J'
if (( USE_GUM )); then
  gum style --border rounded --padding "0 1" --border-foreground 212 \
    "🍪 ISOHungry" "ME WANT DISC! OM NOM NOM" \
    "tummy: $BASE_OUTPUT_DIR" "mouths: $MAX_PARALLEL"
  sleep 1
else
  echo "🍪 ISOHungry — ME WANT DISC! (tummy: $BASE_OUTPUT_DIR, mouths: $MAX_PARALLEL)"
fi

( while true; do render_status; sleep 1; done ) &
TUI_PID=$!

# --------------------------------------------------------------- main loop

while true; do
  for DEVICE in $DEVICE_GLOB; do
    [ -b "$DEVICE" ] || continue

    DEV_NAME=${DEVICE##*/}
    LOCKFILE="$LOCK_DIR/$DEV_NAME"

    # A rip is already running on this drive.
    [ -e "$LOCKFILE" ] && continue

    # No readable disc: reset the drive's state so the next insert is noticed.
    # Audio first: an enhanced CD has both a data session and audio tracks,
    # and the music is what you actually want off it.
    KIND=""; ISO_INFO=""; TOC=""
    MODE=$(disc_mode "$DEVICE")
    case "$MODE" in
      *CD-DA*|*Mixed*) KIND=audio ;;
    esac

    if [ -z "$KIND" ]; then
      ISO_INFO=$(timeout "$PROBE_TIMEOUT" isoinfo -d -i "$DEVICE" 2>/dev/null)
      PROBE_RC=$?
      if (( PROBE_RC == 124 )); then
        set_status "$DEV_NAME" "😵 Drive no talk to me!" ""
        continue
      fi
      if (( PROBE_RC == 0 )) && [ -n "$ISO_INFO" ]; then
        if has_video_ts "$DEVICE"; then KIND=video; else KIND=data; fi
      elif has_audio_tracks "$DEVICE"; then
        KIND=audio          # cd-info couldn't tell us, but there is audio here
      fi
    fi

    if [ -z "$KIND" ]; then
      rm -f "$HANDLED_DIR/$DEV_NAME" "$META_DIR/$DEV_NAME"
      set_status "$DEV_NAME" "🍪 Me hungry... feed me disc!" ""
      continue
    fi

    if [ "$KIND" = data ] && [ "$RIP_DATA_DISCS" != "1" ]; then
      set_status "$DEV_NAME" "🙅 Me no eat data discs" ""
      continue
    fi

    if [ "$KIND" = audio ]; then
      TOC=$(audio_toc "$DEVICE")
      if [ -z "$TOC" ]; then
        set_status "$DEV_NAME" "😵 Drive no talk to me!" ""
        continue
      fi
      FP=$(disc_fingerprint "$TOC")
    else
      FP=$(disc_fingerprint "$ISO_INFO")
    fi

    # Already dealt with this exact disc on this drive (incl. a failed eject).
    if [ -f "$HANDLED_DIR/$DEV_NAME" ] && [ "$(< "$HANDLED_DIR/$DEV_NAME")" = "$FP" ]; then
      continue
    fi

    # Seen this disc before, in any drive, in any run.
    if [ -f "$FP_DIR/$FP" ]; then
      printf '%s' "$FP" > "$HANDLED_DIR/$DEV_NAME"
      set_status "$DEV_NAME" "🙃 Me already ate dis! ($(< "$FP_DIR/$FP"))" ""
      try_eject "$DEVICE" "$DEV_NAME" "" "$(< "$FP_DIR/$FP")"
      continue
    fi

    # Bound concurrency: USB optical drives sharing a controller thrash badly.
    ACTIVE=$(find "$LOCK_DIR" -maxdepth 1 -type f | wc -l)
    if (( ACTIVE >= MAX_PARALLEL )); then
      set_status "$DEV_NAME" "😋 Me full! Waiting (${ACTIVE}/${MAX_PARALLEL} eating)" ""
      continue
    fi

    # Extract then build: video needs ~2x disc size, audio far less once encoded.
    if [ "$KIND" = audio ]; then
      DISC_BYTES=$(audio_bytes "$TOC")
    else
      DISC_BYTES=$(disc_bytes "$ISO_INFO")
    fi
    NEED=$(( DISC_BYTES * SPACE_FACTOR / 10 ))
    AVAIL=$(free_bytes)
    if [[ -n "$AVAIL" ]] && (( DISC_BYTES > 0 )) && (( AVAIL < NEED )); then
      set_status "$DEV_NAME" "😢 Tummy full! Need $(( NEED / 1000000 ))MB, got $(( AVAIL / 1000000 ))MB" ""
      continue
    fi

    RAW_LABEL=$(timeout "$PROBE_TIMEOUT" blkid -o value -s LABEL "$DEVICE" 2>/dev/null)
    LABEL=$(sanitize_label "$RAW_LABEL")
    [ "$LABEL" = "unknown" ] && LABEL="unknown_$DEV_NAME"
    printf -v STAMP '%(%Y-%m-%d_%H%M%S)T' -1

    # Audio CDs get their names from MusicBrainz inside abcde, so the ISO-style
    # naming below doesn't apply. An audio CD also carries no volume label, so
    # blkid gives nothing and "unknown_sr0" would be the only thing on screen —
    # describe the disc from its table of contents instead.
    if [ "$KIND" = audio ]; then
      read -ra TOC_FIELDS <<< "$TOC"
      TRACKS=${TOC_FIELDS[1]:-?}
      MINS=$(( DISC_BYTES / 176400 / 60 ))
      AUDIO_LABEL="CD, $TRACKS tracks, ${MINS}min"
      printf '%s' "$FP" > "$HANDLED_DIR/$DEV_NAME"
      touch "$LOCKFILE"
      printf -v START_TIME '%(%s)T' -1
      set_status "$DEV_NAME" "🎵 NOM NOM! Slurping $AUDIO_LABEL" "$START_TIME"
      rip_audio "$DEVICE" "$DEV_NAME" "" "$AUDIO_LABEL" "$FP" "$START_TIME" "$DISC_BYTES" &
      RIP_PIDS+=("$!")
      continue
    fi

    TARGET_DIR="$MOVIE_DIR"
    [ "$KIND" = data ] && TARGET_DIR="$DATA_DIR"

    # A generic or missing label tells us nothing about which film this is, and
    # is shared by countless discs, so stamp it with the rip time. A distinctive
    # label is used as-is, and only stamped if it would collide.
    if [ -z "$RAW_LABEL" ] || is_generic_label "$LABEL"; then
      ISO_BASE="${LABEL}_${STAMP}"
    else
      ISO_BASE="$LABEL"
    fi
    ISO_PATH="$TARGET_DIR/${ISO_BASE}.iso"

    # A repeated *distinctive* label is almost always a multi-disc set: box
    # sets routinely stamp every disc with the same volume label. Number those
    # rather than timestamping them, so a set reads as one thing on disk.
    # (Generic labels already carry a timestamp in ISO_BASE and never land
    # here — those really are unrelated films that merely share a label.)
    if [ -e "$ISO_PATH" ]; then
      DISC_N=2
      while [ -e "$TARGET_DIR/${ISO_BASE}_disc${DISC_N}.iso" ] && (( DISC_N < 99 )); do
        (( DISC_N++ ))
      done
      ISO_PATH="$TARGET_DIR/${ISO_BASE}_disc${DISC_N}.iso"
    fi
    [ -e "$ISO_PATH" ] && ISO_PATH="$TARGET_DIR/${ISO_BASE}_${STAMP}.iso"
    [ -e "$ISO_PATH" ] && ISO_PATH="$TARGET_DIR/${ISO_BASE}_${STAMP}_${FP}.iso"

    printf '%s' "$FP" > "$HANDLED_DIR/$DEV_NAME"
    touch "$LOCKFILE"
    printf -v START_TIME '%(%s)T' -1
    set_status "$DEV_NAME" "🍪 NOM NOM NOM! Eating $LABEL" "$START_TIME"

    if [ "$KIND" = data ]; then
      rip_data "$DEVICE" "$DEV_NAME" "$ISO_PATH" "$LABEL" "$FP" "$START_TIME" "$DISC_BYTES" &
    else
      rip_disc "$DEVICE" "$DEV_NAME" "$ISO_PATH" "$LABEL" "$FP" "$START_TIME" "$DISC_BYTES" &
    fi
    RIP_PIDS+=("$!")
  done

  # Reap finished rips so the PID list doesn't grow without bound.
  for i in "${!RIP_PIDS[@]}"; do
    kill -0 "${RIP_PIDS[i]}" 2>/dev/null || unset 'RIP_PIDS[i]'
  done
  RIP_PIDS=("${RIP_PIDS[@]}")

  sleep "$POLL_INTERVAL"
done
