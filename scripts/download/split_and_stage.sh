#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

is_video_file() {
  local name="$1"
  case "${name,,}" in
    *.mp4|*.mkv|*.webm|*.mov|*.m4v|*.avi) return 0 ;;
    *) return 1 ;;
  esac
}

split_video_with_ffmpeg() {
  local file="$1"
  local limit_bytes="$2"

  local base ext size duration target_parts segment_time pattern
  base="${file%.*}"
  ext="${file##*.}"
  size=$(stat -c%s "$file")

  duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" || echo "")
  if [ -z "$duration" ]; then
    return 1
  fi

  target_parts=$(( (size + limit_bytes - 1) / limit_bytes ))
  [ "$target_parts" -lt 2 ] && target_parts=2
  segment_time=$(awk -v d="$duration" -v p="$target_parts" 'BEGIN { t = int(d / p); if (t < 30) t = 30; print t }')
  pattern="${base}.part%03d.${ext}"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$file" \
    -c copy \
    -map 0 \
    -f segment \
    -segment_time "$segment_time" \
    -reset_timestamps 1 \
    "$pattern"

  rm -f "$file"
}

split_with_zip_fallback() {
  local file="$1"
  local target="$2"
  local chunk_mb="$3"
  zip -s "${chunk_mb}m" "$target" "$file"
  rm -f "$file"
}

enforce_repo_size_limits() {
  local chunk_target_mb="${1:-$MAX_REPO_MB_DEFAULT}"
  local limit_bytes=$(( chunk_target_mb * 1024 * 1024 ))

  shopt -s globstar nullglob
  for file in downloads/**/*; do
    [ -f "$file" ] || continue
    local size basename target parent_dir
    size=$(stat -c%s "$file")
    basename=$(basename "$file")
    parent_dir=$(dirname "$file")

    if [ "$size" -le "$limit_bytes" ]; then
      continue
    fi

    log_info "Large file detected ($basename): $(( size / 1024 / 1024 )) MB"

    if is_video_file "$basename"; then
      log_info "Attempting ffmpeg split for video: $basename"
      if split_video_with_ffmpeg "$file" "$limit_bytes"; then
        continue
      fi
      log_warn "ffmpeg split failed for $basename. Falling back to split zip."
    fi

    if [ "${basename##*.}" = "zip" ]; then
      target="$parent_dir/${basename%.zip}-split.zip"
    else
      target="$parent_dir/${basename}.zip"
    fi
    split_with_zip_fallback "$file" "$target" "$chunk_target_mb"
  done
  shopt -u globstar nullglob
}
