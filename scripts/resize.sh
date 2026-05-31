#!/bin/bash
BASE_ROOT="/home/kilian/Pictures/img"
if [[ "$1" =~ ^[0-9]+$ ]]; then
  BASE="$BASE_ROOT"
  shift 1 2>/dev/null
else
  BASE="${BASE_ROOT}${1:+/$1}"
fi
TARGET_W=1440
TARGET_H=2560
THREADS=12
PURPLE='\033[0;35m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'
echo "Scanning for images larger than ${TARGET_W}x${TARGET_H} in: $BASE"
TEMP_LIST="/tmp/resize_filelist.$$"
COUNT_FILE="/tmp/resize_count.$$"
LOCK_FILE="/tmp/resize_lock.$$"
find "$BASE" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) >"$TEMP_LIST"
TOTAL=$(wc -l <"$TEMP_LIST")
echo "Found $TOTAL files to check"
echo "Using ImageMagick with fit-within ${TARGET_W}x${TARGET_H} (no upscaling, no format change)"
echo ""
if [ "$TOTAL" -eq 0 ]; then
  rm -f "$TEMP_LIST"
  echo "Nothing to do."
  exit 0
fi
echo "0" >"$COUNT_FILE"
touch "$LOCK_FILE"
export TOTAL TARGET_W TARGET_H COUNT_FILE LOCK_FILE PURPLE GREEN RED CYAN RESET
process_file() {
  local f="$1"
  local dir file name in_size out_size img_w img_h n
  dir="$(dirname "$f")"
  file="$(basename "$f")"
  name="${file%.*}"

  # Read actual image dimensions
  read -r img_w img_h < <(identify -format "%w %h" "$f" 2>/dev/null)

  # Skip if dimensions could not be read or image already fits
  if [ -z "$img_w" ] || [ -z "$img_h" ]; then
    echo -e "${RED}✗ Could not read dimensions: $file${RESET}" >&2
    return
  fi
  if [ "$img_w" -le "$TARGET_W" ] && [ "$img_h" -le "$TARGET_H" ]; then
    return
  fi

  in_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  in_kb=$((in_size / 1024))

  # Resize in-place, preserving format, no quality reduction
  # The '>' flag means only shrink, never enlarge
  if convert "$f" -resize "${TARGET_W}x${TARGET_H}>" -define webp:lossless=true +profile "*" "$f" 2>/dev/null; then
    out_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    out_kb=$((out_size / 1024))
    n=$(flock "$LOCK_FILE" bash -c '
      count=$(< "$COUNT_FILE"); count=$((count + 1)); echo "$count" > "$COUNT_FILE"
      echo "$count"
    ')
    echo -e "${PURPLE}[$n/$TOTAL]${RESET} ${GREEN}✔ $file${RESET} ${CYAN}(${img_w}x${img_h} → fit ${TARGET_W}x${TARGET_H} | ${in_kb}KB → ${out_kb}KB)${RESET}"
  else
    echo -e "${RED}✗ Failed: $file${RESET}" >&2
  fi
}
export -f process_file
cat "$TEMP_LIST" | xargs -d '\n' -P "$THREADS" -I {} bash -c 'process_file "$@"' _ {}
FINAL_COUNT=$(<"$COUNT_FILE")
rm -f "$COUNT_FILE" "$LOCK_FILE" "$TEMP_LIST"
echo ""
echo -e "${GREEN}Done! Resized $FINAL_COUNT files.${RESET}"
