#!/usr/bin/env bash
# Rewrite download file basenames to be valid on Windows (no : * ? " < > | etc.),
# rebuild the index, refresh the working tree, and optionally commit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

sanitize_base() {
  # Last path segment only; keep directory layout under downloads/
  local base="$1"
  printf '%s' "$base" | tr ':<>"/\\|?*' '-' | sed 's/[[:cntrl:]]/-/g' | sed 's/[. ]\+$//'
}

build_index_lines() {
  git ls-tree -r HEAD | while IFS=$'\t' read -r meta path; do
    read -r mode typ sha _ <<<"${meta}"
    [[ "$typ" == blob ]] || continue
    out="$path"
    if [[ "$path" == downloads/* ]]; then
      dir="${path%/*}"
      base="${path##*/}"
      safe="$(sanitize_base "$base")"
      [[ -n "$safe" ]] || safe="unnamed.bin"
      out="${dir}/${safe}"
    fi
    printf '%s %s\t%s\n' "$mode" "$sha" "$out"
  done
}

rm -rf downloads
mkdir -p downloads

rm -f .git/index
build_index_lines | git update-index --index-info

git checkout-index -f -a

echo "Indexed $(git ls-files | wc -l) paths; downloads on disk with safe names."
