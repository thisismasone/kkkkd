#!/usr/bin/env bash
set -euo pipefail

MODE=""
URL_LIST=""
OFFLINE_URL=""
YT_FORMAT=""
YT_QUALITY=""
CHUNK_TARGET_MB="95"
BRANCH=""
DRY_RUN="false"
AUTO_YES="false"
ACTION="download"
PURGE_PATH="downloads"
PURGE_REMOTE="origin"
PURGE_PUSH="false"

usage() {
  cat <<'EOF'
Usage: scripts/facade/download-and-commit.sh [options]

Options:
  --purge-download-history
  --purge-path <path>                (default: downloads)
  --purge-remote <name>              (default: origin)
  --purge-push                       force-push rewritten history
  --mode <file|file-zip|yt|yt-zip|yt-split|web|web-crawl>
  --url "<space separated urls>"
  --offline-url "<single url>"
  --yt-format "<yt-dlp format>"
  --yt-quality <144p|240p|360p|480p|720p|1080p|1440p|2160p>
  --chunk-target-mb <number>
  --branch <name>
  --dry-run
  --yes
EOF
}

confirm() {
  local prompt="$1"
  if [ "$AUTO_YES" = "true" ]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

prompt_mode() {
  echo "Select download mode:"
  echo "  1) file"
  echo "  2) file-zip"
  echo "  3) yt"
  echo "  4) yt-zip"
  echo "  5) yt-split"
  echo "  6) web"
  echo "  7) web-crawl"
  read -r -p "Choice [1-7]: " choice

  case "$choice" in
    1) MODE="file" ;;
    2) MODE="file-zip" ;;
    3) MODE="yt" ;;
    4) MODE="yt-zip" ;;
    5) MODE="yt-split" ;;
    6) MODE="web" ;;
    7) MODE="web-crawl" ;;
    *) echo "Invalid choice." ; exit 1 ;;
  esac
}

collect_inputs() {
  if [ "$ACTION" = "purge-history" ]; then
    return 0
  fi

  if [ -z "$MODE" ]; then
    prompt_mode
  fi

  case "$MODE" in
    file|file-zip|yt|yt-zip|yt-split)
      if [ -z "$URL_LIST" ]; then
        read -r -p "Enter one or more URLs (space-separated): " URL_LIST
      fi
      ;;
    web|web-crawl)
      if [ -z "$OFFLINE_URL" ]; then
        read -r -p "Enter webpage URL: " OFFLINE_URL
      fi
      ;;
  esac

  if [[ "$MODE" == yt* ]]; then
    if [ -z "${YT_QUALITY:-}" ]; then
      echo "Select YouTube max quality:"
      echo "  1) 144p"
      echo "  2) 240p"
      echo "  3) 360p"
      echo "  4) 480p"
      echo "  5) 720p"
      echo "  6) 1080p"
      echo "  7) 1440p"
      echo "  8) 2160p"
      read -r -p "Choice [1-8, default 6]: " quality_choice
      case "$quality_choice" in
        1) YT_QUALITY="144p" ;;
        2) YT_QUALITY="240p" ;;
        3) YT_QUALITY="360p" ;;
        4) YT_QUALITY="480p" ;;
        5) YT_QUALITY="720p" ;;
        7) YT_QUALITY="1440p" ;;
        8) YT_QUALITY="2160p" ;;
        *) YT_QUALITY="1080p" ;;
      esac
    fi
  fi

  if [[ "$MODE" == yt* ]] && [ -z "$YT_FORMAT" ]; then
    read -r -p "Optional custom yt-dlp format (Enter to use quality profile): " maybe_format
    if [ -n "$maybe_format" ]; then
      YT_FORMAT="$maybe_format"
    fi
  fi

  if [ -z "$BRANCH" ]; then
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  fi
}

build_command_message() {
  if [ "$ACTION" = "purge-history" ]; then
    return 0
  fi
  if [ -z "$YT_QUALITY" ]; then
    YT_QUALITY="1080p"
  fi

  case "$MODE" in
    file) WORKFLOW_CMD="download: $URL_LIST" ;;
    file-zip) WORKFLOW_CMD="download-zip: $URL_LIST" ;;
    yt) WORKFLOW_CMD="download-yt: $URL_LIST"$'\n'"yt-quality: $YT_QUALITY" ;;
    yt-zip) WORKFLOW_CMD="download-yt-zip: $URL_LIST"$'\n'"yt-quality: $YT_QUALITY" ;;
    yt-split) WORKFLOW_CMD="download-yt-split: $URL_LIST"$'\n'"yt-quality: $YT_QUALITY" ;;
    web) WORKFLOW_CMD="download-web: $OFFLINE_URL" ;;
    web-crawl) WORKFLOW_CMD="download-web-crawl: $OFFLINE_URL" ;;
    *) echo "Unsupported mode: $MODE" ; exit 1 ;;
  esac
}

commit_and_push() {
  local marker_file
  marker_file=".workflow-trigger"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker_file"

  git add "$marker_file"
  git commit -m "$WORKFLOW_CMD"
  git push origin "HEAD:$BRANCH"
}

ensure_clean_working_tree() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit/stash changes before rewriting history."
    exit 1
  fi
}

run_history_purge() {
  ensure_clean_working_tree

  echo
  echo "About to rewrite git history."
  echo "Path to purge: $PURGE_PATH"
  echo "Remote: $PURGE_REMOTE"
  echo "Force push after rewrite: $PURGE_PUSH"
  echo
  echo "This removes files from ALL commits and can drop download-only commits."
  echo

  confirm "Continue with history rewrite?" || { echo "Cancelled."; exit 0; }

  if command -v git-filter-repo >/dev/null 2>&1 || git filter-repo --help >/dev/null 2>&1; then
    echo "Using git filter-repo."
    git filter-repo --path "$PURGE_PATH" --invert-paths --force
  else
    echo "git filter-repo not found; using slower git filter-branch fallback."
    git filter-branch --force \
      --index-filter "git rm -r --cached --ignore-unmatch '$PURGE_PATH'" \
      --prune-empty \
      --tag-name-filter cat \
      -- --all
  fi

  git for-each-ref --format='delete %(refname)' refs/original | git update-ref --stdin || true
  git reflog expire --expire=now --all
  git gc --prune=now --aggressive

  if [ "$PURGE_PUSH" = "true" ]; then
    confirm "Force-push rewritten history to $PURGE_REMOTE (--all and --tags)?" || {
      echo "Rewrite finished locally. Skipped force push."
      return 0
    }
    git push "$PURGE_REMOTE" --force --all
    git push "$PURGE_REMOTE" --force --tags
  fi

  echo
  echo "History purge completed."
  echo "If collaborating with others, they should re-clone or hard reset to the new history."
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --purge-download-history) ACTION="purge-history"; shift ;;
      --purge-path) PURGE_PATH="${2:-}"; shift 2 ;;
      --purge-remote) PURGE_REMOTE="${2:-}"; shift 2 ;;
      --purge-push) PURGE_PUSH="true"; shift ;;
      --url) URL_LIST="${2:-}"; shift 2 ;;
      --offline-url) OFFLINE_URL="${2:-}"; shift 2 ;;
      --yt-format) YT_FORMAT="${2:-}"; shift 2 ;;
      --yt-quality) YT_QUALITY="${2:-}"; shift 2 ;;
      --chunk-target-mb) CHUNK_TARGET_MB="${2:-}"; shift 2 ;;
      --branch) BRANCH="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --yes) AUTO_YES="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
  collect_inputs
  build_command_message

  if [ "$ACTION" = "purge-history" ]; then
    run_history_purge
    exit 0
  fi

  echo
  echo "Workflow command commit message:"
  echo "  $WORKFLOW_CMD"
  echo "Branch: $BRANCH"
  echo "yt-quality: $YT_QUALITY"
  echo "yt-format: $YT_FORMAT"
  echo "chunk-target-mb: $CHUNK_TARGET_MB"
  echo

  if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run enabled. Exiting."
    exit 0
  fi

  confirm "Create commit and push now?" || { echo "Cancelled."; exit 0; }
  commit_and_push
  echo "Pushed. GitHub workflow should start shortly."
}

main "$@"
