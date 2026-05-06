#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/download/orchestrate.sh"

run_case() {
  local name="$1"
  shift
  echo "== $name =="
  (
    cd "$ROOT_DIR"
    env "$@" bash "$SCRIPT"
  )
}

run_case "commit-file-command" \
  EVENT_NAME=push \
  COMMIT_MESSAGE="download: https://example.com/file.zip" \
  INPUT_DRY_RUN=true

run_case "dispatch-yt-split" \
  EVENT_NAME=workflow_dispatch \
  INPUT_MODE=yt-split \
  INPUT_URL_LIST="https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
  INPUT_CHUNK_TARGET_MB=95 \
  INPUT_DRY_RUN=true

run_case "dispatch-web" \
  EVENT_NAME=workflow_dispatch \
  INPUT_MODE=web \
  INPUT_OFFLINE_URL="https://example.com" \
  INPUT_DRY_RUN=true

run_case "dispatch-multiline-url-list" \
  EVENT_NAME=workflow_dispatch \
  INPUT_MODE=file \
  INPUT_URL_LIST=$'https://a.example/a.zip\nhttps://b.example/b.zip' \
  INPUT_DRY_RUN=true

run_case "commit-multiline-url-body" \
  EVENT_NAME=push \
  COMMIT_MESSAGE=$'download:\nhttps://a.example/a.zip\nhttps://b.example/b.zip\nyt-quality: 1080p' \
  INPUT_DRY_RUN=true

echo "All smoke checks passed."
