#!/usr/bin/env bash
# Fails if any two tracked paths (files or any parent folder) differ only by letter case.
# macOS and Windows filesystems are case-insensitive and silently merge them.
set -euo pipefail
ref="${1:-HEAD}"
collisions=$(git ls-tree -r --name-only "$ref" \
  | awk -F/ '{p=""; for (i=1;i<=NF;i++){p=(p==""?$i:p"/"$i); print p}}' \
  | sort -u | awk '{print tolower($0)}' | sort | uniq -d)
if [ -n "$collisions" ]; then
  echo "Paths that collide on case-insensitive filesystems:"; echo "$collisions"; exit 1
fi
echo "No case collisions."
