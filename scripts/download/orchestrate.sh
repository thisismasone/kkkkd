#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=./file_download.sh
source "$SCRIPT_DIR/file_download.sh"
# shellcheck source=./video_download.sh
source "$SCRIPT_DIR/video_download.sh"
# shellcheck source=./offline_capture.sh
source "$SCRIPT_DIR/offline_capture.sh"
# shellcheck source=./split_and_stage.sh
source "$SCRIPT_DIR/split_and_stage.sh"

resolve_from_commit_message() {
  local message="$1"
  local command_line
  local quality_line
  command_line="$(printf "%s\n" "$message" | awk '/^(download(-yt)?(-zip|-split)?|download-web(-crawl)?):/ {print; exit}')"
  if [ -z "$command_line" ]; then
    log_info "No download command found in commit message."
    return 1
  fi

  quality_line="$(printf "%s\n" "$message" | awk '/^yt-quality:/ {print; exit}')"
  RESOLVED_CMD="${command_line%%:*}"
  # Same-line URLs after "command:", plus optional following lines that are only https URLs
  # (stops at another key:value header like yt-quality:).
  RESOLVED_URLS="$(printf "%s\n" "$message" | awk '
    /^[[:space:]]*$/ { next }
    /^(download(-yt)?(-zip|-split)?|download-web(-crawl)?):/ {
      rest=$0
      sub(/^[^:]+:[[:space:]]*/, "", rest)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
      if (length(rest)) printf "%s ", rest
      collecting=1
      next
    }
    collecting && /^[[:space:]]*https?:\/\// {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      printf "%s ", line
      next
    }
    collecting && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]*https?:/ && /:/ { collecting=0 }
  ')"
  RESOLVED_URLS="${RESOLVED_URLS%"${RESOLVED_URLS##*[![:space:]]}"}"
  RESOLVED_YT_QUALITY="${quality_line#*:}"
  RESOLVED_YT_QUALITY="${RESOLVED_YT_QUALITY#"${RESOLVED_YT_QUALITY%%[![:space:]]*}"}"
  [ -z "$RESOLVED_YT_QUALITY" ] && RESOLVED_YT_QUALITY="1080p"
  return 0
}

resolve_mode() {
  local event_name="$1"
  local dispatch_mode="${2:-}"
  local dispatch_url_list="${3:-}"
  local offline_url="${4:-}"
  local dispatch_yt_quality="${5:-1080p}"
  local message="${6:-}"

  RESOLVED_CMD=""
  RESOLVED_URLS=""
  RESOLVED_YT_QUALITY="1080p"

  if [ "$event_name" = "workflow_dispatch" ]; then
    case "$dispatch_mode" in
      file) RESOLVED_CMD="download"; RESOLVED_URLS="$dispatch_url_list";;
      file-zip) RESOLVED_CMD="download-zip"; RESOLVED_URLS="$dispatch_url_list";;
      yt) RESOLVED_CMD="download-yt"; RESOLVED_URLS="$dispatch_url_list"; RESOLVED_YT_QUALITY="$dispatch_yt_quality";;
      yt-zip) RESOLVED_CMD="download-yt-zip"; RESOLVED_URLS="$dispatch_url_list"; RESOLVED_YT_QUALITY="$dispatch_yt_quality";;
      yt-split) RESOLVED_CMD="download-yt-split"; RESOLVED_URLS="$dispatch_url_list"; RESOLVED_YT_QUALITY="$dispatch_yt_quality";;
      web) RESOLVED_CMD="download-web"; RESOLVED_URLS="$offline_url" ;;
      web-crawl) RESOLVED_CMD="download-web-crawl"; RESOLVED_URLS="$offline_url" ;;
      *)
        log_error "Unsupported dispatch mode: $dispatch_mode"
        return 1
        ;;
    esac
    return 0
  fi

  resolve_from_commit_message "$message"
}

run_download_mode() {
  local resolved_cmd="$1"
  local urls="$2"
  local yt_format="${3:-}"
  local yt_quality="${4:-1080p}"
  local chunk_target_mb="${5:-$MAX_REPO_MB_DEFAULT}"

  case "$resolved_cmd" in
    download)
      download_file_urls "normal" "$urls"
      ;;
    download-zip)
      download_file_urls "zip" "$urls"
      ;;
    download-yt)
      download_video_urls "normal" "$urls" "$yt_format" "$yt_quality"
      ;;
    download-yt-zip)
      download_video_urls "zip" "$urls" "$yt_format" "$yt_quality"
      ;;
    download-yt-split)
      download_video_urls "split" "$urls" "$yt_format" "$yt_quality"
      ;;
    download-web)
      capture_web_urls "web" "$urls"
      ;;
    download-web-crawl)
      capture_web_urls "web-crawl" "$urls"
      ;;
    *)
      log_error "Invalid command: $resolved_cmd"
      return 1
      ;;
  esac

  enforce_repo_size_limits "$chunk_target_mb"
  organize_downloads_layout
}

# Smaller git pushes per URL reduce HTTP 500 failures on large batches (see commit_push.sh).
incremental_push_enabled() {
  local flag="${INPUT_INCREMENTAL_PUSH:-auto}"
  case "$flag" in
    false | False | 0)
      return 1
      ;;
    true | True | 1)
      parse_url_list "$RESOLVED_URLS"
      [ "${#PARSED_URLS[@]}" -ge 1 ]
      return
      ;;
    auto | "" | *)
      [ "$RESOLVED_CMD" = "download-web-crawl" ] && return 1
      parse_url_list "$RESOLVED_URLS"
      [ "${#PARSED_URLS[@]}" -gt 1 ]
      return
      ;;
  esac
}

main() {
  local event_name="${EVENT_NAME:-push}"
  local commit_message="${COMMIT_MESSAGE:-}"
  local dispatch_mode="${INPUT_MODE:-}"
  local dispatch_url_list="${INPUT_URL_LIST:-}"
  local yt_format="${INPUT_YT_FORMAT:-}"
  local yt_quality="${INPUT_YT_QUALITY:-1080p}"
  local offline_url="${INPUT_OFFLINE_URL:-}"
  local storage_mode="${INPUT_STORAGE_MODE:-repo}"
  local chunk_target_mb="${INPUT_CHUNK_TARGET_MB:-$MAX_REPO_MB_DEFAULT}"
  local dry_run="${INPUT_DRY_RUN:-false}"

  ensure_work_dirs
  if ! resolve_mode "$event_name" "$dispatch_mode" "$dispatch_url_list" "$offline_url" "$yt_quality" "$commit_message"; then
    exit 0
  fi

  # Single-line string for logs and consistent splitting (workflow_dispatch allows newline URLs).
  if [ -n "$RESOLVED_URLS" ]; then
    local _collapsed="${RESOLVED_URLS//$'\r'/ }"
    _collapsed="${_collapsed//$'\n'/ }"
    _collapsed="${_collapsed//$'\t'/ }"
    local -a _url_parts
    read -r -a _url_parts <<< "$_collapsed"
    RESOLVED_URLS="${_url_parts[*]}"
  fi

  if [ -z "$RESOLVED_URLS" ]; then
    log_error "No URLs found for mode '$RESOLVED_CMD'."
    exit 1
  fi

  log_info "Resolved command: $RESOLVED_CMD"
  log_info "Resolved URLs: $RESOLVED_URLS"
  log_info "YouTube quality: $RESOLVED_YT_QUALITY"
  log_info "Storage mode: $storage_mode"
  log_info "Chunk target MB: $chunk_target_mb"

  if [ "$storage_mode" != "repo" ]; then
    log_warn "Storage mode '$storage_mode' is not implemented yet. Falling back to repo mode."
  fi

  if [ "$dry_run" = "true" ]; then
    log_info "Dry run enabled; skipping execution."
    exit 0
  fi

  if incremental_push_enabled; then
    log_info "Incremental commit/push after each URL (INPUT_INCREMENTAL_PUSH=${INPUT_INCREMENTAL_PUSH:-auto})."
    local u
    parse_url_list "$RESOLVED_URLS"
    for u in "${PARSED_URLS[@]}"; do
      [ -z "${u// }" ] && continue
      u="$(normalize_url "$u")"
      [ -z "$u" ] && continue
      log_info "Downloading (incremental step): $u"
      run_download_mode "$RESOLVED_CMD" "$u" "$yt_format" "$RESOLVED_YT_QUALITY" "$chunk_target_mb"
      bash "$SCRIPT_DIR/commit_push.sh" "${GITHUB_REF_NAME:-main}"
    done
  else
    run_download_mode "$RESOLVED_CMD" "$RESOLVED_URLS" "$yt_format" "$RESOLVED_YT_QUALITY" "$chunk_target_mb"
  fi
  cleanup_tmp
}

main "$@"
