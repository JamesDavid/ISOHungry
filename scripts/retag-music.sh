#!/bin/bash
# Retro-tag albums that were ripped before tagging worked.
#
# Metadata is reconstructed from the layout ISOHungry itself produced:
#
#   music/<Artist>/<Album>/NN - Title.mp3
#   music/Various Artists/<Album>/NN - Artist - Title.mp3
#
# abcde munges spaces to underscores inside each field, so a field can never
# contain a space -- which means " - " only ever appears as the separator abcde
# inserted, and splitting on it is unambiguous. Underscores are turned back
# into spaces, which is right except for the rare title that genuinely contains
# one.
#
# Files that already carry tags are left alone unless --force is given.
#
#   docker exec isohungry /opt/isohungry/retag-music.sh [--force] [--dry-run]
set -uo pipefail
shopt -s nullglob

MUSIC_DIR="${MUSIC_DIR:-${BASE_OUTPUT_DIR:-/output}/music}"
FORCE=0
DRY=0
for a in "$@"; do
  case "$a" in
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "usage: $0 [--force] [--dry-run]" >&2; exit 2 ;;
  esac
done

unmunge() { printf '%s' "${1//_/ }"; }

# No pipelines here on purpose: with `set -o pipefail`, `grep -q` exits as soon
# as it matches, the producer takes SIGPIPE, and the pipeline reports failure --
# so a tagged file would look untagged and get overwritten.
has_tags() {
  local out
  case "$1" in
    *.mp3)
      out=$(eyeD3 "$1" 2>/dev/null)
      [[ $out =~ (^|$'\n')(artist|title):[[:space:]]*[^[:space:]] ]] ;;
    *.flac)
      out=$(metaflac --show-tag=TITLE "$1" 2>/dev/null)
      [[ $out =~ =[^[:space:]] ]] ;;
    *) return 0 ;;
  esac
}

tagged=0; skipped=0; failed=0; albums=0

for album_dir in "$MUSIC_DIR"/*/*; do
  [ -d "$album_dir" ] || continue
  album=$(basename "$album_dir")
  artist=$(basename "$(dirname "$album_dir")")
  album=$(unmunge "$album")
  artist=$(unmunge "$artist")

  files=( "$album_dir"/*.mp3 "$album_dir"/*.flac )
  (( ${#files[@]} )) || continue
  albums=$(( albums + 1 ))
  total=${#files[@]}
  echo "== $artist / $album  ($total files)"

  for f in "${files[@]}"; do
    base=${f##*/}
    stem=${base%.*}

    # "NN - Title" or "NN - Artist - Title"
    IFS=$'\n' read -r -d '' -a parts < <(printf '%s\n' "${stem// - /$'\n'}"; printf '\0')
    num=${parts[0]:-}
    num=${num#0}
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
      echo "   ?? $base (no track number)"; skipped=$(( skipped + 1 )); continue
    fi

    if (( ${#parts[@]} >= 3 )); then
      tartist=$(unmunge "${parts[1]}")
      title=$(unmunge "$(printf '%s - ' "${parts[@]:2}" | sed 's/ - $//')")
    elif (( ${#parts[@]} == 2 )); then
      tartist=$artist
      title=$(unmunge "${parts[1]}")
    else
      echo "   ?? $base (unrecognised name)"; skipped=$(( skipped + 1 )); continue
    fi

    if (( ! FORCE )) && has_tags "$f"; then
      skipped=$(( skipped + 1 )); continue
    fi

    if (( DRY )); then
      printf '   -> %-3s %-24s %s\n' "$num" "$tartist" "$title"
      tagged=$(( tagged + 1 )); continue
    fi

    ok=1
    case "$f" in
      *.mp3)
        eyeD3 --encoding utf8 -a "$tartist" -A "$album" -t "$title" \
              -n "$num" -N "$total" "$f" >/dev/null 2>&1 || ok=0 ;;
      *.flac)
        metaflac --remove-tag=ARTIST --remove-tag=ALBUM --remove-tag=TITLE \
                 --remove-tag=TRACKNUMBER "$f" 2>/dev/null
        metaflac --set-tag=ARTIST="$tartist" --set-tag=ALBUM="$album" \
                 --set-tag=TITLE="$title" --set-tag=TRACKNUMBER="$num" \
                 "$f" 2>/dev/null || ok=0 ;;
    esac
    if (( ok )); then tagged=$(( tagged + 1 ))
    else echo "   !! failed: $base"; failed=$(( failed + 1 )); fi
  done
done

echo
echo "albums: $albums   tagged: $tagged   skipped (already tagged): $skipped   failed: $failed"
(( DRY )) && echo "(dry run - nothing was written)"
exit $(( failed > 0 ))
