#!/usr/bin/env bash
set -euo pipefail

COOKIE_FILE="cookies.txt"
SECRET_NAME="YOUTUBE_COOKIES_B64"
SET_WITH_GH="false"
REPO_TARGET=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/facade/prepare-youtube-secrets.sh [options] [cookies-file]

Defaults:
  cookies-file: cookies.txt

What it does:
  1) Validates cookie file format (Netscape export).
  2) Prints the GitHub Secret name and generated value (base64).
  3) Prints ready-to-run gh commands to set the secret safely.
  4) Optional: creates/updates secret automatically with GitHub CLI.

Options:
  --gh-set             Create/update secret immediately using gh CLI.
  --repo <owner/name>  Set secret in a specific repository.
  --secret-name <name> Override default secret name.
  -h, --help           Show this help.

Important:
  - Keep cookies.txt local only (never commit it).
  - Rotate cookies periodically by re-exporting from browser.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}


validate_cookie_format() {
  local file="$1"
  local first_line
  first_line="$(awk 'NR==1 { print; exit }' "$file" | tr -d '\r')"
  if [ "$first_line" != "# Netscape HTTP Cookie File" ]; then
    echo "Invalid cookie format in '$file'." >&2
    echo "Expected first line: # Netscape HTTP Cookie File" >&2
    exit 1
  fi
}

to_base64_single_line() {
  local file="$1"
  base64 < "$file" | tr -d '\r\n'
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gh-set)
        SET_WITH_GH="true"
        shift
        ;;
      --repo)
        REPO_TARGET="${2:-}"
        shift 2
        ;;
      --secret-name)
        SECRET_NAME="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        COOKIE_FILE="$1"
        shift
        ;;
    esac
  done

  require_cmd awk
  require_cmd base64
  require_cmd git

  if [ ! -f "$COOKIE_FILE" ]; then
    echo "Cookie file not found: $COOKIE_FILE" >&2
    exit 1
  fi

 
  validate_cookie_format "$COOKIE_FILE"

  local secret_value
  secret_value="$(to_base64_single_line "$COOKIE_FILE")"

  local gh_repo_args=()
  if [ -n "$REPO_TARGET" ]; then
    gh_repo_args=(--repo "$REPO_TARGET")
  fi

  cat <<EOF
GitHub Secret to create:
  Name : $SECRET_NAME
  Value: $secret_value

Recommended command (GitHub CLI):
  gh secret set $SECRET_NAME --body '$secret_value' ${gh_repo_args[*]}

Alternative (pipe directly, no value echoed on terminal):
  base64 < "$COOKIE_FILE" | tr -d '\\r\\n' | gh secret set $SECRET_NAME --body - ${gh_repo_args[*]}
EOF

  if [ "$SET_WITH_GH" = "true" ]; then
    require_cmd gh
    base64 < "$COOKIE_FILE" | tr -d '\r\n' | gh secret set "$SECRET_NAME" --body - "${gh_repo_args[@]}"
    echo
    echo "Secret '$SECRET_NAME' has been created/updated via gh."
  fi
}

main "$@"
