#!/usr/bin/env bash
set -euo pipefail

MAX_REPO_MB_DEFAULT=95

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

ensure_work_dirs() {
  mkdir -p downloads tmp_downloads
}

normalize_url() {
  local url="$1"
  url="${url//\\&/&}"
  url="${url//\\?/\?}"
  url="${url//\\=/=}"
  url="${url//\\#/#}"
  url="${url//\\%/%}"
  url="${url%\"}"
  url="${url#\"}"
  url="${url%\'}"
  url="${url#\'}"
  printf "%s" "$url"
}

parse_url_list() {
  local raw="$1"
  # read only consumes one line from a here-string; normalize newlines/tabs so
  # workflow_dispatch / env vars with multiple lines still become multiple URLs.
  raw="${raw//$'\r'/ }"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\t'/ }"
  read -r -a PARSED_URLS <<< "$raw"
}

require_urls() {
  if [ "${#PARSED_URLS[@]}" -eq 0 ]; then
    log_error "No URLs were provided."
    return 1
  fi
}

build_link_folder_name() {
  local url="$1"
  local slug hash
  slug="$(printf "%s" "$url" \
    | sed -E 's#https?://##; s#[^A-Za-z0-9]+#-#g; s#^-+##; s#-+$##' \
    | cut -c1-48)"
  [ -z "$slug" ] && slug="link"
  hash="$(printf "%s" "$url" | sha1sum | awk '{print substr($1,1,8)}')"
  printf "%s-%s" "$slug" "$hash"
}

# Move nested downloads into dir root so copies/zips are flat (aria2c URL paths).
flatten_tmp_download_dir() {
  local dir="$1"
  local f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [[ "$(basename "$f")" == *.aria2 ]] && continue
    move_with_unique_name "$f" "$dir"
  done < <(find "$dir" -mindepth 2 -type f 2>/dev/null || true)
  find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

is_aria2_sidecar_file() {
  case "$(basename "$1")" in
    *.aria2|*.aria2.bak) return 0 ;;
    *) return 1 ;;
  esac
}

# Largest non-sidecar file under dir (expects flat layout after flatten_tmp_download_dir).
pick_primary_download_file() {
  local dir="$1"
  local best="" best_size=-1 f size
  shopt -s nullglob
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    is_aria2_sidecar_file "$f" && continue
    size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [ "$size" -gt "$best_size" ] && { best_size=$size; best="$f"; }
  done
  shopt -u nullglob
  [ -n "$best" ] && printf "%s" "$best"
}

count_download_files() {
  local dir="$1"
  local n=0 f
  shopt -s nullglob
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    is_aria2_sidecar_file "$f" && continue
    n=$((n + 1))
  done
  shopt -u nullglob
  printf "%s" "$n"
}

# Outer archive name from the real downloaded filename (not the URL slug).
safe_zip_filename_for_download_dir() {
  local dir="$1"
  local url="$2"
  local primary base stem hash n
  n="$(count_download_files "$dir")"
  hash="$(printf "%s" "$url" | sha1sum | awk '{print substr($1,1,8)}')"
  if [ "$n" -eq 0 ]; then
    printf "download_%s.zip" "$hash"
    return
  fi
  if [ "$n" -gt 1 ]; then
    printf "bundle_%s.zip" "$hash"
    return
  fi
  primary="$(pick_primary_download_file "$dir")"
  base="$(basename "$primary")"
  base="${base//$'\r'/}"
  base="${base//$'\n'/}"
  base="$(printf "%s" "$base" | sed 's/[<>:"|?*\\\/]/_/g')"
  [ -z "$base" ] || [ "$base" = "." ] || [ "$base" = ".." ] && {
    printf "download_%s.zip" "$hash"
    return
  }
  if [ "${#base}" -gt 120 ]; then
    stem="${base%.*}"
    [ "$stem" = "$base" ] && stem="$base"
    stem="${stem:0:100}"
    case "${base,,}" in
      *.*) printf "%s.%s.zip" "$stem" "${base##*.}" ;;
      *) printf "%s.zip" "$stem" ;;
    esac
    return
  fi
  case "${base,,}" in
    *.zip)
      stem="${base%.*}"
      [ -z "$stem" ] && stem="archive"
      printf "%s_archive.zip" "$stem"
      ;;
    *) printf "%s.zip" "$base" ;;
  esac
}

cleanup_tmp() {
  rm -rf tmp_downloads
}

move_with_unique_name() {
  local src="$1"
  local dest_dir="$2"
  local basename stem ext candidate suffix

  basename="$(basename "$src")"
  mkdir -p "$dest_dir"
  candidate="$dest_dir/$basename"
  if [ ! -e "$candidate" ]; then
    mv -f "$src" "$candidate"
    return 0
  fi

  stem="${basename%.*}"
  ext="${basename##*.}"
  suffix="$(date -u +%H%M%S)"
  if [ "$stem" = "$basename" ]; then
    candidate="$dest_dir/${basename}_$suffix"
  else
    candidate="$dest_dir/${stem}_$suffix.$ext"
  fi
  mv -f "$src" "$candidate"
}

classify_download_file() {
  local filename="${1,,}"

  case "$filename" in
    *.mp4|*.mkv|*.webm|*.mov|*.m4v|*.avi)
      printf "videos"
      return 0
      ;;
    *.z[0-9][0-9]|*.part[0-9][0-9][0-9].*|*-split.zip)
      printf "chunks"
      return 0
      ;;
    *.zip|*.7z|*.rar|*.tar|*.gz|*.bz2|*.xz)
      printf "archives"
      return 0
      ;;
    *.html|*.mhtml|*.offline)
      printf "web"
      return 0
      ;;
    *)
      printf "files"
      return 0
      ;;
  esac
}

organize_downloads_layout() {
  local date_bucket category target_dir
  date_bucket="$(date -u +%Y-%m-%d)"

  if [ -d downloads/downloads ]; then
    shopt -s nullglob
    for nested in downloads/downloads/*; do
      [ -f "$nested" ] || continue
      move_with_unique_name "$nested" "downloads"
    done
    shopt -u nullglob
    rmdir downloads/downloads 2>/dev/null || true
  fi

  shopt -s nullglob
  for file in downloads/*; do
    [ -f "$file" ] || continue
    category="$(classify_download_file "$(basename "$file")")"
    target_dir="downloads/$category/$date_bucket"
    move_with_unique_name "$file" "$target_dir"
  done
  shopt -u nullglob
}
