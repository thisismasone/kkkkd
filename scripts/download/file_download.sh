#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

download_file_urls() {
  local mode="$1"
  local url_line="$2"
  local date_bucket
  date_bucket="$(date -u +%Y-%m-%d)"

  parse_url_list "$url_line"
  require_urls
  ensure_work_dirs

  for raw_url in "${PARSED_URLS[@]}"; do
    local url
    local folder_name
    local per_url_tmp_dir
    local per_url_output_dir
    url="$(normalize_url "$raw_url")"
    [ -z "$url" ] && continue

    folder_name="$(build_link_folder_name "$url")"
    per_url_tmp_dir="tmp_downloads/$folder_name"
    per_url_output_dir="downloads/files/$date_bucket/$folder_name"
    mkdir -p "$per_url_tmp_dir" "$per_url_output_dir"

    log_info "Downloading file: $url"
    aria2c \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --retry-wait=3 \
      --max-tries=5 \
      --timeout=30 \
      --split=4 \
      --max-connection-per-server=4 \
      --min-split-size=90M \
      --dir="$per_url_tmp_dir" \
      "$url"

    flatten_tmp_download_dir "$per_url_tmp_dir"

    if [ "$mode" = "zip" ]; then
      local zip_name zip_path f
      local -a zip_files=()
      zip_name="$(safe_zip_filename_for_download_dir "$per_url_tmp_dir" "$url")"
      zip_path="$ROOT_DIR/$per_url_output_dir/$zip_name"
      shopt -s nullglob
      for f in "$per_url_tmp_dir"/*; do
        [ -f "$f" ] || continue
        is_aria2_sidecar_file "$f" && continue
        zip_files+=("$f")
      done
      shopt -u nullglob
      if [ "${#zip_files[@]}" -eq 0 ]; then
        log_warn "No files to zip under $per_url_tmp_dir for $url"
      else
        zip -j "$zip_path" "${zip_files[@]}"
      fi
    else
      shopt -s nullglob
      for f in "$per_url_tmp_dir"/*; do
        [ -f "$f" ] || continue
        is_aria2_sidecar_file "$f" && continue
        cp -f "$f" "$per_url_output_dir/" 2>/dev/null || true
      done
      shopt -u nullglob
    fi
    rm -rf "$per_url_tmp_dir"
  done
}
