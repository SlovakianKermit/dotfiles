#!/usr/bin/env bash
# Usage: flatten.sh [levels] [/path/to/target]
# Pulls all files up by the specified number of levels. Defaults to 1.

LEVELS="${1:-1}"
TARGET="${2:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: '$TARGET' is not a directory."
  exit 1
fi

if ! [[ "$LEVELS" =~ ^[0-9]+$ ]] || [ "$LEVELS" -lt 1 ]; then
  echo "Error: levels must be a positive integer."
  exit 1
fi

for ((i = 0; i < LEVELS; i++)); do
  find "$TARGET" -mindepth 2 -type f -print0 | while IFS= read -r -d '' file; do
    parent="$(dirname "$file")"
    grandparent="$(dirname "$parent")"
    filename="$(basename "$file")"
    dest="$grandparent/$filename"

    if [ -e "$dest" ]; then
      base="${filename%.*}"
      ext="${filename##*.}"
      [ "$base" = "$ext" ] && ext=""
      counter=1
      while [ -e "$dest" ]; do
        [ -n "$ext" ] && dest="$grandparent/${base}_${counter}.${ext}" || dest="$grandparent/${base}_${counter}"
        ((counter++))
      done
    fi

    mv "$file" "$dest"
  done

  find "$TARGET" -mindepth 1 -type d -empty -delete
done

echo "Done."
