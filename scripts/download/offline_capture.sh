#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

capture_web_urls() {
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
    per_url_output_dir="downloads/web/$date_bucket/$folder_name"
    mkdir -p "$per_url_tmp_dir" "$per_url_output_dir"

    local capture_mode="singlefile"
    if [ "$mode" = "web-crawl" ]; then
      capture_mode="crawl"
    elif [[ "$url" == *"youtube.com"* || "$url" == *"youtu.be"* ]]; then
      # Video-heavy pages with long-lived network activity are more stable via MHTML path.
      capture_mode="mhtml"
    fi

    log_info "Capturing webpage offline ($capture_mode): $url"
    if ! node "$ROOT_DIR/scripts/offline/capture.mjs" \
      --mode "$capture_mode" \
      --url "$url" \
      --output "$ROOT_DIR/$per_url_tmp_dir"; then
      if [ "$capture_mode" = "singlefile" ]; then
        log_warn "SingleFile capture failed, retrying with MHTML fallback."
        node "$ROOT_DIR/scripts/offline/capture.mjs" \
          --mode "mhtml" \
          --url "$url" \
          --output "$ROOT_DIR/$per_url_tmp_dir"
      else
        rm -rf "$per_url_tmp_dir"
        return 1
      fi
    fi

    cp -f "$per_url_tmp_dir"/* "$per_url_output_dir/" 2>/dev/null || true
    rm -rf "$per_url_tmp_dir"
  done
}
