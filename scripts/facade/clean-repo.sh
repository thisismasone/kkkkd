#!/usr/bin/env bash
set -euo pipefail

# Local: temp dirs, local extract output, workflow marker; optional downloads/ wipe, git gc.
# Remote: optional git history rewrite + force-push via download-and-commit.sh (destructive).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../download/common.sh
source "$SCRIPT_DIR/../download/common.sh"

DO_LOCAL="true"
WIPE_DOWNLOADS="false"
DO_GC="false"
REMOTE_PURGE="false"
PURGE_PUSH="false"
AUTO_YES="false"
PURGE_PATH="downloads"
PURGE_REMOTE="origin"

usage() {
  cat <<'EOF'
Usage: bash scripts/facade/clean-repo.sh [options]

Local cleanup (default):
  - Removes tmp_downloads/ (same as orchestrate cleanup_tmp)
  - Removes extracted_downloads/ (local extract script output)
  - Removes .workflow-trigger if present

Options:
  --no-local            Skip scratch cleanup above (tmp / extracted / trigger)
  --wipe-downloads      Delete working-tree downloads/ (destructive; use --yes to skip prompt)
  --gc                  Run: git gc --prune=now

Remote (git history — removes path from ALL commits; use with care):
  --purge-history       Run scripts/facade/download-and-commit.sh --purge-download-history
  --purge-push          Also force-push rewritten history (passes through to that script)
  --purge-path <path>   Path to strip from history (default: downloads)
  --purge-remote <name> Remote name (default: origin)
  --yes, -y             Non-interactive confirms for purge and wipe-downloads

Typical:
  bash scripts/facade/clean-repo.sh
  bash scripts/facade/clean-repo.sh --gc
  bash scripts/facade/clean-repo.sh --wipe-downloads --yes
  bash scripts/facade/clean-repo.sh --purge-history --yes
  bash scripts/facade/clean-repo.sh --purge-history --purge-push --yes
EOF
}

confirm() {
  local prompt="$1"
  if [ "$AUTO_YES" = "true" ]; then
    return 0
  fi
  local answer
  read -r -p "$prompt [y/N]: " answer || true
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

clean_scratch_artifacts() {
  echo "[local] cleanup_tmp (tmp_downloads/)"
  cleanup_tmp

  if [ -d "$ROOT_DIR/extracted_downloads" ]; then
    echo "[local] rm -rf extracted_downloads/"
    rm -rf "$ROOT_DIR/extracted_downloads"
  fi

  if [ -f "$ROOT_DIR/.workflow-trigger" ]; then
    echo "[local] rm -f .workflow-trigger"
    rm -f "$ROOT_DIR/.workflow-trigger"
  fi

  echo "[local] scratch artifacts done"
}

run_wipe_downloads() {
  if [ -d "$ROOT_DIR/downloads" ]; then
    echo "[local] removing working tree downloads/"
    rm -rf "$ROOT_DIR/downloads"
  else
    echo "[local] no downloads/ directory to remove"
  fi
}

run_git_gc() {
  echo "[local] git gc --prune=now"
  (cd "$ROOT_DIR" && git gc --prune=now)
}

run_remote_purge() {
  local -a args=(--purge-download-history --purge-path "$PURGE_PATH" --purge-remote "$PURGE_REMOTE")
  [ "$PURGE_PUSH" = "true" ] && args+=(--purge-push)
  [ "$AUTO_YES" = "true" ] && args+=(--yes)

  echo "[remote] bash scripts/facade/download-and-commit.sh ${args[*]}"
  bash "$ROOT_DIR/scripts/facade/download-and-commit.sh" "${args[@]}"
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-local) DO_LOCAL="false"; shift ;;
      --wipe-downloads) WIPE_DOWNLOADS="true"; shift ;;
      --gc) DO_GC="true"; shift ;;
      --purge-history) REMOTE_PURGE="true"; shift ;;
      --purge-push) PURGE_PUSH="true"; shift ;;
      --purge-path)
        PURGE_PATH="${2:-}"
        shift 2
        ;;
      --purge-remote)
        PURGE_REMOTE="${2:-}"
        shift 2
        ;;
      --yes | -y) AUTO_YES="true"; shift ;;
      -h | --help) usage; exit 0 ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "$ROOT_DIR"

  if [ "$WIPE_DOWNLOADS" = "true" ]; then
    echo "[WARN] --wipe-downloads removes the downloads/ folder from your working tree only."
    confirm "Proceed?" || { echo "Cancelled."; exit 0; }
  fi

  did_any="false"

  if [ "$DO_LOCAL" = "true" ]; then
    clean_scratch_artifacts
    did_any="true"
  fi

  if [ "$WIPE_DOWNLOADS" = "true" ]; then
    run_wipe_downloads
    did_any="true"
  fi

  if [ "$DO_GC" = "true" ]; then
    run_git_gc
    did_any="true"
  fi

  if [ "$REMOTE_PURGE" = "true" ]; then
    echo
    echo "[WARN] --purge-history rewrites git history for this clone (and optionally force-pushes)."
    run_remote_purge
    did_any="true"
  fi

  if [ "$did_any" != "true" ]; then
    echo "[ERROR] Nothing to do (e.g. only --no-local with no other flags)." >&2
    usage >&2
    exit 1
  fi

  echo "[done]"
}

main "$@"
