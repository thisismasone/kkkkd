#!/usr/bin/env bash
set -euo pipefail

# Avoid HTTP 500 / hangups when pushing large packs over HTTPS (GitHub recommends raising this).
configure_git_for_large_pushes() {
  git config user.name "github-actions"
  git config user.email "github-actions@github.com"
  git config http.postBuffer 524288000
  git config http.version HTTP/1.1
  git config http.lowSpeedLimit 0
  git config http.lowSpeedTime 999999
}

push_with_retry() {
  local branch="$1"
  local attempt=1
  local max=6
  local delay
  while [ "$attempt" -le "$max" ]; do
    if git push origin "HEAD:$branch"; then
      return 0
    fi
    if [ "$attempt" -eq "$max" ]; then
      echo "[ERROR] git push failed after $max attempts." >&2
      echo "[ERROR] Large pushes often trigger HTTP 500; try smaller commits (incremental push) or Git LFS." >&2
      return 1
    fi
    delay=$((15 * (2 ** (attempt - 1))))
    echo "[WARN] git push failed (attempt $attempt/$max); retrying in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
    git pull --rebase origin "$branch" || true
  done
}

pull_rebase_with_retry() {
  local branch="$1"
  local attempt=1
  local max=4
  local delay
  while [ "$attempt" -le "$max" ]; do
    if git pull --rebase origin "$branch"; then
      return 0
    fi
    delay=$((10 * attempt))
    echo "[WARN] git pull --rebase failed (attempt $attempt/$max); retrying in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  return 1
}

commit_and_push_downloads() {
  local branch="${1:-${GITHUB_REF_NAME:-main}}"

  configure_git_for_large_pushes

  git add downloads/
  if git diff --cached --quiet; then
    echo "Nothing to commit."
    return 0
  fi

  git commit -m "Add downloaded files [skip ci]"
  pull_rebase_with_retry "$branch"
  push_with_retry "$branch"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  commit_and_push_downloads "${1:-}"
fi
