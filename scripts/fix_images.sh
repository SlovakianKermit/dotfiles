#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="${1:-.}"

declare -A group_title
declare -A group_files

# Pass 1: scan and group files by leading number
while IFS= read -r -d '' file; do
  filename="$(basename "$file")"
  ext="${filename##*.}"
  name="${filename%.*}"

  # Extract leading number
  leading_num="${name%%_*}"
  if ! [[ "$leading_num" =~ ^[0-9]+$ ]]; then
    echo "Skipping (no leading number): $filename"
    continue
  fi

  # Extract title: everything between first _ and _02-
  remainder="${name#*_}"
  title="${remainder%%_02-*}"

  if [[ -z "$title" || "$title" == "$remainder" ]]; then
    echo "Skipping (can't parse title): $filename"
    continue
  fi

  # Extract trailing sequence number
  trailing="${name##*_}"
  if ! [[ "$trailing" =~ ^[0-9]+$ ]]; then
    trailing="0"
  fi

  group_title["$leading_num"]="$title"

  # Store as: trailingnum|filepath
  if [[ -v group_files["$leading_num"] ]]; then
    group_files["$leading_num"]+=$'\n'"${trailing}|${file}"
  else
    group_files["$leading_num"]="${trailing}|${file}"
  fi

done < <(find "$TARGET_DIR" -maxdepth 1 -type f \( \
  -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
  -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" \
  \) -print0)

# Pass 2: create folders and rename files
for leading_num in "${!group_files[@]}"; do
  title="${group_title[$leading_num]}"
  folder="$TARGET_DIR/$title"

  mkdir -p "$folder"

  # Sort entries by trailing number
  mapfile -t sorted_entries < <(echo "${group_files[$leading_num]}" | sort -t'|' -k1 -n)

  index=1
  for entry in "${sorted_entries[@]}"; do
    filepath="${entry#*|}"
    orig_filename="$(basename "$filepath")"
    ext="${orig_filename##*.}"

    new_name="$(printf "%s (%03d).%s" "$title" "$index" "$ext")"
    dest="$folder/$new_name"

    echo "  $orig_filename  ->  $title/$new_name"
    mv "$file" "$dest" 2>/dev/null || mv "$filepath" "$dest"

    ((index++))
  done

  echo "[$leading_num] '$title' -> $index-1 files"
done

echo "Done."
