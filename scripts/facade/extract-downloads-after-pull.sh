#!/usr/bin/env bash
set -euo pipefail

# Extract archives and copy loose files under downloads/ that appeared or changed
# since the last git pull (uses ORIG_HEAD). Run from repo root after: git pull
#
# Examples:
#   bash scripts/facade/extract-downloads-after-pull.sh
#   bash scripts/facade/extract-downloads-after-pull.sh --out ~/Downloads/from-ci
#   bash scripts/facade/extract-downloads-after-pull.sh --since origin/main
#   bash scripts/facade/extract-downloads-after-pull.sh --dry-run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

BASE_REV=""
OUT_DIR=""
DRY_RUN="false"
DIFF_FILTER="AM"

usage() {
  cat <<'EOF'
Usage: bash scripts/facade/extract-downloads-after-pull.sh [options]

Compares two revisions and processes paths under downloads/ that were added or
modified (default). Intended right after `git pull` (git leaves ORIG_HEAD at
the pre-pull HEAD).

Options:
  --out <dir>           Output directory (default: <repo>/extracted_downloads)
  --since <rev>         Compare <rev>..HEAD instead of ORIG_HEAD..HEAD
  --added-only          Only added files (--diff-filter=A), not updates
  --dry-run             Print actions only
  -h, --help            This help

Requires: unzip (for .zip). Other extensions are copied as-is.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --since)
      BASE_REV="$2"
      shift 2
      ;;
    --added-only)
      DIFF_FILTER="A"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT_DIR/extracted_downloads"
fi

if [[ -z "$BASE_REV" ]]; then
  if git rev-parse --verify -q ORIG_HEAD >/dev/null 2>&1; then
    BASE_REV="ORIG_HEAD"
  else
    echo "[ERROR] No ORIG_HEAD (only set after operations like git pull/merge)." >&2
    echo "        Run:  git pull" >&2
    echo "        Or pass an explicit base:  --since origin/main" >&2
    exit 1
  fi
fi

if ! git rev-parse --verify -q "$BASE_REV" >/dev/null 2>&1; then
  echo "[ERROR] Not a valid revision: $BASE_REV" >&2
  exit 1
fi

HEAD_REV="$(git rev-parse HEAD)"
if [[ "$(git rev-parse "$BASE_REV")" == "$HEAD_REV" ]]; then
  echo "[INFO] Base and HEAD are the same; nothing to extract."
  exit 0
fi

mkdir -p "$OUT_DIR"

unique_dest_dir() {
  local preferred="$1"
  local d="$preferred"
  local n=0
  while [[ -e "$d" ]]; do
    n=$((n + 1))
    d="${preferred}_${n}"
  done
  printf "%s" "$d"
}

unique_dest_file() {
  local dest="$1"
  local d stem ext dir base n=0
  d="$dest"
  if [[ ! -e "$d" ]]; then
    printf "%s" "$d"
    return
  fi
  dir="$(dirname "$dest")"
  base="$(basename "$dest")"
  stem="${base%.*}"
  ext="${base##*.}"
  while [[ -e "$d" ]]; do
    n=$((n + 1))
    if [[ "$stem" == "$base" ]]; then
      d="$dir/${base}_$n"
    else
      d="$dir/${stem}_$n.$ext"
    fi
  done
  printf "%s" "$d"
}

process_zip() {
  local zip_path="$1"
  local stem dest
  stem="$(basename "$zip_path")"
  stem="${stem%.zip}"
  stem="${stem%.ZIP}"
  [[ -z "$stem" ]] && stem="archive"
  dest="$(unique_dest_dir "$OUT_DIR/$stem")"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] unzip $zip_path -> $dest/"
    return 0
  fi
  mkdir -p "$dest"
  if ! command -v unzip >/dev/null 2>&1; then
    echo "[ERROR] unzip not found; install unzip or extract manually: $zip_path" >&2
    return 1
  fi
  unzip -o -q "$zip_path" -d "$dest"
  echo "[OK] $zip_path -> $dest/"
}

process_plain_file() {
  local file_path="$1"
  local bn dest
  bn="$(basename "$file_path")"
  dest="$(unique_dest_file "$OUT_DIR/$bn")"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] cp $file_path -> $dest"
    return 0
  fi
  cp -f "$file_path" "$dest"
  echo "[OK] $file_path -> $dest"
}

count=0
while IFS= read -r -d '' path; do
  [[ -z "$path" ]] && continue
  [[ "$path" != downloads/* ]] && continue
  full="$ROOT_DIR/$path"
  [[ -f "$full" ]] || continue

  case "${full,,}" in
    *.zip)
      process_zip "$full"
      ;;
    *)
      process_plain_file "$full"
      ;;
  esac
  count=$((count + 1))
done < <(git diff -z --name-only --diff-filter="$DIFF_FILTER" "$BASE_REV" "$HEAD_REV" -- downloads/)

if [[ "$count" -eq 0 ]]; then
  echo "[INFO] No added/modified files under downloads/ between $BASE_REV and HEAD."
  exit 0
fi

echo "[INFO] Done ($count item(s)) -> $OUT_DIR"
