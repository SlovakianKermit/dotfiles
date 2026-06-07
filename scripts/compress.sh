#!/bin/bash
cd /tmp || exit 1
BASE_ROOT="$HOME/Pictures/img"
if [[ "$1" =~ ^[0-9]+$ ]]; then
  BASE="$BASE_ROOT"
  QUALITY="${1:-85}"
  METHOD="${2:-4}"
else
  [[ "$1" == /* ]] && BASE="$1" || BASE="${BASE_ROOT}${1:+/$1}"
  QUALITY="${2:-85}"
  METHOD="${3:-4}"
fi
TARGET_W=2560
TARGET_H=1440
THREADS=12
PURPLE='\033[0;35m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'
echo "Scanning for images in: $BASE"
TEMP_LIST="/tmp/webp_filelist.$$"
COUNT_FILE="/tmp/webp_count.$$"
SKIPPED_FILE="/tmp/webp_skipped.$$"
SAVED_FILE="/tmp/webp_saved.$$"
TOTAL_IN_FILE="/tmp/webp_totalin.$$"
LOCK_FILE="/tmp/webp_lock.$$"
find "$BASE" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) >"$TEMP_LIST"
TOTAL=$(wc -l <"$TEMP_LIST")
echo "Found $TOTAL files to convert"
echo "Using cwebp with quality $QUALITY, method $METHOD, max ${TARGET_W}x${TARGET_H}, and $THREADS threads"
echo ""
if [ "$TOTAL" -eq 0 ]; then
  rm -f "$TEMP_LIST"
  echo "Nothing to do."
  exit 0
fi
echo "0" >"$COUNT_FILE"
echo "0" >"$SKIPPED_FILE"
echo "0" >"$SAVED_FILE"
echo "0" >"$TOTAL_IN_FILE"
touch "$LOCK_FILE"
export TOTAL QUALITY METHOD TARGET_W TARGET_H COUNT_FILE SKIPPED_FILE SAVED_FILE TOTAL_IN_FILE LOCK_FILE PURPLE GREEN RED CYAN YELLOW RESET
process_file() {
  local f="$1"
  local dir file name output n in_size out_size saved
  local img_w img_h src tmp_resized
  dir="$(dirname "$f")"
  file="$(basename "$f")"
  name="${file%.*}"
  name="${name%.png}"
  name="${name%.PNG}"
  name="${name%.jpg}"
  name="${name%.JPG}"
  name="${name%.jpeg}"
  name="${name%.JPEG}"
  output="$dir/$name.webp"
  in_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  in_kb=$((in_size / 1024))

  read -r img_w img_h < <(identify -format "%w %h" "$f" 2>/dev/null)

  tmp_resized=""
  src="$f"
  if [ -n "$img_w" ] && [ -n "$img_h" ]; then
    if [ "$img_w" -gt "$TARGET_W" ] || [ "$img_h" -gt "$TARGET_H" ]; then
      tmp_resized="/tmp/resized_$$.${f##*.}"
      convert "$f" -resize "${TARGET_W}x${TARGET_H}>" "$tmp_resized" 2>/dev/null
      src="$tmp_resized"
    fi
  fi

  if cwebp -q "$QUALITY" -m "$METHOD" "$src" -o "$output" -quiet 2>/dev/null; then
    [ -n "$tmp_resized" ] && rm -f "$tmp_resized"
    out_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
    out_kb=$((out_size / 1024))
    if [ -f "$output" ] && [ "$out_size" -gt 1024 ] && [ "$out_size" -lt "$in_size" ]; then
      saved=$((in_size - out_size))
      rm -f "$f"
      n=$(flock "$LOCK_FILE" bash -c '
        count=$(< "$COUNT_FILE"); count=$((count + 1)); echo "$count" > "$COUNT_FILE"
        total_saved=$(< "$SAVED_FILE"); total_saved=$(( total_saved + '"$saved"' )); echo "$total_saved" > "$SAVED_FILE"
        total_in=$(< "$TOTAL_IN_FILE"); total_in=$(( total_in + '"$in_size"' )); echo "$total_in" > "$TOTAL_IN_FILE"
        echo "$count"
      ')
      echo -e "${PURPLE}[$n/$TOTAL]${RESET} ${GREEN}✔ $name.webp${RESET} ${CYAN}(${in_kb}KB → ${out_kb}KB)${RESET}"
    else
      rm -f "$output"
      [ -n "$tmp_resized" ] && rm -f "$tmp_resized"
      flock "$LOCK_FILE" bash -c '
        skipped=$(< "$SKIPPED_FILE"); skipped=$((skipped + 1)); echo "$skipped" > "$SKIPPED_FILE"
      '
      echo -e "${YELLOW}⊘ Skipped: $file (compressed output was not smaller)${RESET}"
    fi
  else
    [ -n "$tmp_resized" ] && rm -f "$tmp_resized"
    echo -e "${RED}✗ Failed: $file${RESET}" >&2
  fi
}
export -f process_file
cat "$TEMP_LIST" | xargs -d '\n' -P "$THREADS" -I {} bash -c 'process_file "$@"' _ {}
FINAL_COUNT=$(<"$COUNT_FILE")
FINAL_SKIPPED=$(<"$SKIPPED_FILE")
TOTAL_SAVED=$(<"$SAVED_FILE")
TOTAL_IN=$(<"$TOTAL_IN_FILE")
SAVED_MB_INT=$((TOTAL_SAVED / 1048576))
SAVED_MB_DEC=$(((TOTAL_SAVED % 1048576) * 10 / 1048576))
SAVED_MB="${SAVED_MB_INT}.${SAVED_MB_DEC}"
PERCENT=$((TOTAL_IN > 0 ? TOTAL_SAVED * 100 / TOTAL_IN : 0))
rm -f "$COUNT_FILE" "$SKIPPED_FILE" "$SAVED_FILE" "$TOTAL_IN_FILE" "$LOCK_FILE" "$TEMP_LIST"
echo ""
echo -e "${GREEN}Done! Converted $FINAL_COUNT/$TOTAL files. Skipped $FINAL_SKIPPED. Saved ${SAVED_MB}MB (${PERCENT}%) total.${RESET}"
