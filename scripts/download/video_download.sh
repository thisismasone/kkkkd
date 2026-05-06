#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

prepare_youtube_cookies_file() {
  local target_file="$1"
  local cookie_b64="${YOUTUBE_COOKIES_B64:-}"
  local cookie_raw="${YOUTUBE_COOKIES:-}"

  rm -f "$target_file"
  if [ -n "$cookie_b64" ]; then
    printf "%s" "$cookie_b64" | base64 -d > "$target_file"
  elif [ -n "$cookie_raw" ]; then
    printf "%s\n" "$cookie_raw" > "$target_file"
  else
    return 1
  fi

  chmod 600 "$target_file"
  return 0
}

download_video_urls() {
  local mode="$1"
  local url_line="$2"
  local yt_format="${3:-}"
  local yt_quality="${4:-1080p}"
  local download_count=0
  local cookies_file="$ROOT_DIR/tmp_downloads/youtube.cookies.txt"
  local has_cookie_auth="false"
  local date_bucket
  local resolved_format
  local -a yt_args
  local -a youtube_dl_args
  date_bucket="$(date -u +%Y-%m-%d)"

  if [ -z "$yt_format" ]; then
    local max_height
    case "${yt_quality,,}" in
      *p) max_height="${yt_quality%p}" ;;
      *) max_height="$yt_quality" ;;
    esac
    if ! [[ "$max_height" =~ ^[0-9]+$ ]]; then
      case "${yt_quality,,}" in
        low) max_height="720" ;;
        medium) max_height="1080" ;;
        high) max_height="2160" ;;
        *) max_height="1080" ;;
      esac
    fi
    resolved_format="bv*[height<=${max_height}][vcodec!=none]+ba[acodec!=none]/b[height<=${max_height}][acodec!=none]"
  else
    resolved_format="$yt_format"
  fi

  yt_args=(
    --no-progress
    --restrict-filenames
    --merge-output-format mp4
    --js-runtimes node
    --remote-components "ejs:github"
    --concurrent-fragments 4
    --retries 15
    --fragment-retries 15
    --file-access-retries 10
    --retry-sleep "http:linear=1::2"
    --retry-sleep "fragment:exp=1:20"
    --throttled-rate 100K
    -f "$resolved_format"
    -o "%(title)s [%(id)s].%(ext)s"
  )
  youtube_dl_args=(
    --restrict-filenames
    -f "bestvideo+bestaudio/best"
    -o "%(title)s [%(id)s].%(ext)s"
  )

  if prepare_youtube_cookies_file "$cookies_file"; then
    log_info "Using YouTube cookies from secure environment input."
    has_cookie_auth="true"
    yt_args+=(--cookies "$cookies_file")
    youtube_dl_args+=(--cookies "$cookies_file")
  fi

  # With account cookies, yt-dlp already has a session visitor id.
  # Manual visitor headers are primarily useful for no-cookie sessions.
  if [ "$has_cookie_auth" = "false" ]; then
    local visitor_data_file
    visitor_data_file="${YOUTUBE_VISITOR_DATA_FILE:-$ROOT_DIR/scripts/download/youtube_visitor_data.txt}"
    if [ -f "$visitor_data_file" ]; then
      local visitor_data
      visitor_data="$(awk 'NF && $1 !~ /^#/ { print; exit }' "$visitor_data_file" | tr -d '\r')"
      if [ -n "$visitor_data" ]; then
        log_info "Using YouTube visitor data from $(basename "$visitor_data_file")."
        yt_args+=(--add-header "X-Goog-Visitor-Id: $visitor_data")
      fi
    fi
  fi

  if [ "$mode" = "split" ]; then
    # Chapter-aware splitting first; size-based splitting is applied afterwards.
    yt_args+=(--split-chapters)
  fi

  parse_url_list "$url_line"
  require_urls
  ensure_work_dirs

  for raw_url in "${PARSED_URLS[@]}"; do
    local url
    local folder_name
    local per_url_tmp_dir
    local per_url_output_dir
    local -a retry_args
    url="$(normalize_url "$raw_url")"
    [ -z "$url" ] && continue

    folder_name="$(build_link_folder_name "$url")"
    per_url_tmp_dir="tmp_downloads/$folder_name"
    per_url_output_dir="downloads/yt/$date_bucket/$folder_name"
    mkdir -p "$per_url_tmp_dir" "$per_url_output_dir"

    if [ "$has_cookie_auth" = "true" ]; then
      retry_args=(--extractor-args "youtube:player_client=tv_downgraded,web_safari,web_creator")
    else
      retry_args=(--extractor-args "youtube:player_client=android_vr,web_safari,web")
    fi

    log_info "Downloading video: $url"
    if ! yt-dlp "${yt_args[@]}" -P "$per_url_tmp_dir" "$url"; then
      log_warn "yt-dlp failed for $url. Retrying with alternate YouTube clients."
      if ! yt-dlp "${yt_args[@]}" \
        "${retry_args[@]}" \
        -P "$per_url_tmp_dir" \
        "$url"; then
        log_warn "Alternate yt-dlp strategy failed for $url. Retrying with youtube-dl fallback."
        if ! youtube-dl "${youtube_dl_args[@]}" -o "$per_url_tmp_dir/%(title)s [%(id)s].%(ext)s" "$url"; then
          log_warn "All video download strategies failed for $url (likely YouTube anti-bot/cookie challenge)."
          rm -rf "$per_url_tmp_dir"
          continue
        fi
      fi
    fi

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
    download_count=$((download_count + 1))
  done

  if [ "$download_count" -eq 0 ]; then
    log_error "No videos were downloaded. If YouTube blocks the runner, use cookies (--cookies) from a trusted account."
    return 1
  fi

  rm -f "$cookies_file"
}
