#!/usr/bin/env bash

set -uo pipefail

ROOT="${1:-.}"

find "$ROOT" -type f -iname "*.zip" -print0 | while IFS= read -r -d '' zipfile; do
  dir="$(dirname "$zipfile")"
  name="$(basename "$zipfile" .zip)"
  target="$dir/$name"

  mkdir -p "$target"

  if unzip -q "$zipfile" -d "$target"; then
    rm -f "$zipfile"
    echo "Extracted and removed: $zipfile"
  else
    echo "Extraction failed, zip kept: $zipfile"
  fi
done
