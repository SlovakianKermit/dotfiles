#!/bin/bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────
BASE_ROOT="$HOME/Pictures/img"
QUALITY=85
EFFORT=3
THREADS=12
LOG_MODE=0
COMPARE_MODE=0
TARGET_W=2560
TARGET_H=1440

# ── Usage ─────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: compress-jxl.sh [-q <quality>] [-e <effort>] [-t <threads>] [-c]
                        [directory | quality [effort]]

Recursively convert images to JPEG XL. Replaces originals only when smaller.

  -q, --quality N    Quality 0-100 (default: $QUALITY)
  -e, --effort N     Encoder effort 1-9 (default: $EFFORT)
  -t, --threads N    Parallel jobs (default: $THREADS)
  -c, --compare      Save pre-encode PNGs to /tmp/jxl_compare_src/
  -l, --log          Save a log file in the images directory
  -h, --help         Show this help

Examples:
  compress-jxl.sh                        # defaults on ~/Pictures/img
  compress-jxl.sh 80                     # quality 80, default dir
  compress-jxl.sh 90 7                   # quality 90, effort 7
  compress-jxl.sh ~/Pics 80 5            # custom dir, q80, e5
  compress-jxl.sh -q 75 -e 3 -c          # named flags + compare mode
  compress-jxl.sh -l -e 1                 # log timing + results
EOF
}

# ── Parse arguments ───────────────────────────────────────
BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -q | --quality)
    QUALITY="$2"
    shift 2
    ;;
  -e | --effort)
    EFFORT="$2"
    shift 2
    ;;
  -t | --threads)
    THREADS="$2"
    shift 2
    ;;
  -c | --compare)
    COMPARE_MODE=1
    shift
    ;;
  -l | --log)
    LOG_MODE=1
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "Unknown flag: $1" >&2
    usage
    exit 1
    ;;
  *)
    # Positional: first number → quality, second number → effort, else → base dir
    if [[ "$1" =~ ^[0-9]+$ ]]; then
      QUALITY="$1"
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && {
        EFFORT="$1"
        shift
      }
    elif [ -z "$BASE" ]; then
      BASE="$1"
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && {
        QUALITY="$1"
        shift
      }
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && {
        EFFORT="$1"
        shift
      }
    else
      echo "Unexpected argument: $1" >&2
      usage
      exit 1
    fi
    ;;
  esac
done

# Resolve BASE
[ -z "$BASE" ] && BASE="$BASE_ROOT"
[[ "$BASE" != /* ]] && BASE="${BASE_ROOT}/${BASE#/}"

# ── Prerequisites ─────────────────────────────────────────
if ! command -v cjxl &>/dev/null; then
  echo "cjxl not found. Install libjxl-tools first." >&2
  exit 1
fi

if ! command -v exiftool &>/dev/null; then
  echo "exiftool not found. Install perl-image-exiftool first." >&2
  exit 1
fi

# ── Resize engine ─────────────────────────────────────────
# vipsthumbnail (libvips) is 4-10× faster; falls back to ImageMagick
if command -v vipsthumbnail &>/dev/null; then
  RESIZE_ENGINE="vipsthumbnail (libvips)"
  resize_image() {
    vipsthumbnail "$1" --size "${TARGET_W}x${TARGET_H}" -o "$2" 2>/dev/null
  }
else
  RESIZE_ENGINE="convert (ImageMagick)"
  resize_image() {
    convert "$1" -resize "${TARGET_W}x${TARGET_H}>" "$2"
  }
fi
export -f resize_image

cd /tmp || exit 1

# ── Compare-mode setup ────────────────────────────────────
CMP_DIR="/tmp/jxl_compare_src"
if [ "$COMPARE_MODE" = "1" ]; then
  mkdir -p "$CMP_DIR"
  echo -e "\033[0;36mCompare mode on: pre-encode sources → $CMP_DIR\033[0m"
fi

# ── Colours ───────────────────────────────────────────────
PURPLE='\033[0;35m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ── Find files ────────────────────────────────────────────
echo "Scanning for images in: $BASE"
TEMP_LIST="/tmp/jxl_filelist.$$"
COUNT_FILE="/tmp/jxl_count.$$"
SKIPPED_FILE="/tmp/jxl_skipped.$$"
SAVED_FILE="/tmp/jxl_saved.$$"
TOTAL_IN_FILE="/tmp/jxl_totalin.$$"
LOCK_FILE="/tmp/jxl_lock.$$"

find "$BASE" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) >"$TEMP_LIST"
TOTAL=$(wc -l <"$TEMP_LIST")

echo "Found $TOTAL files to convert"
echo "Using cjxl with quality $QUALITY, effort $EFFORT, max ${TARGET_W}x${TARGET_H}, $THREADS parallel jobs, resize: $RESIZE_ENGINE"
echo "Metadata preservation: exiftool writes EXIF/IPTC/XMP + AI tags onto each output after encode"
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
START_TIME=$(date +%s)

export TOTAL QUALITY EFFORT TARGET_W TARGET_H \
  COUNT_FILE SKIPPED_FILE SAVED_FILE TOTAL_IN_FILE LOCK_FILE \
  COMPARE_MODE CMP_DIR \
  PURPLE GREEN RED CYAN YELLOW RESET

# ── Per-file worker ───────────────────────────────────────
process_file() {
  local f="$1"
  local dir file name output n in_size out_size saved
  local img_w img_h src tmp_resized
  local AI_META

  dir="$(dirname "$f")"
  file="$(basename "$f")"
  name="${file%.*}"
  name="${name%.png}"
  name="${name%.PNG}"
  name="${name%.jpg}"
  name="${name%.JPG}"
  name="${name%.jpeg}"
  name="${name%.JPEG}"

  output="$dir/$name.jxl"
  in_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  in_kb=$((in_size / 1024))

  read -r img_w img_h < <(identify -format "%w %h" "$f" 2>/dev/null) || true

  tmp_resized=""
  src="$f"
  if [ -n "$img_w" ] && [ -n "$img_h" ]; then
    if [ "$img_w" -gt "$TARGET_W" ] || [ "$img_h" -gt "$TARGET_H" ]; then
      tmp_resized="/tmp/jxl_resized_$$_${RANDOM}.${f##*.}"
      resize_image "$f" "$tmp_resized"
      src="$tmp_resized"
    fi
  fi

  # --- Compare mode: save pre-encode source as PNG ---
  if [ "$COMPARE_MODE" = "1" ]; then
    convert "$src" "${CMP_DIR}/${name}.png" 2>/dev/null || true
  fi

  # --- Encode ---
  # cjxl's own box-injection flags (-x, --compress_boxes) are not
  # reliable across libjxl versions, they were silently doing nothing
  # on test systems, so metadata is handled entirely by exiftool
  # after a successful encode instead.
  if cjxl "$src" "$output" -q "$QUALITY" -e "$EFFORT" --lossless_jpeg=0 2>/dev/null; then
    [ -n "$tmp_resized" ] && rm -f "$tmp_resized"

    out_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
    out_kb=$((out_size / 1024))

    if [ -f "$output" ] && [ "$out_size" -gt 0 ] && [ "$out_size" -lt "$in_size" ]; then
      # --- Preserve metadata on the surviving output ---
      # PNG tEXt/iTXt AI-generation keys (Parameters from
      # Automatic1111/Forge, Prompt/Workflow from ComfyUI, Comment/
      # Description from other tools) are read-only inside exiftool's
      # own tag table, so a plain "-all:all" copy silently drops them.
      # Query all five tags in one exiftool call (-s for short
      # "TagName: Value" output) to avoid per-file stutter from
      # spawning five separate Perl interpreters.
      AI_META=""
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        AI_META="${AI_META}${line}"$'\n\n'
      done < <(exiftool -s -s -Parameters -Prompt -Workflow -Comment -Description "$f" 2>/dev/null || true)

      META_ARGS=(-tagsfromfile "$f" -exif:all -iptc:all -xmp:all)
      [ -n "$AI_META" ] && META_ARGS+=(-EXIF:UserComment="$AI_META" -XMP-dc:Description="$AI_META")
      exiftool -q -m -overwrite_original "${META_ARGS[@]}" "$output" >/dev/null 2>&1 || true

      saved=$((in_size - out_size))
      rm -f "$f"
      n=$(flock "$LOCK_FILE" bash -c '
        count=$(< "$COUNT_FILE"); count=$((count + 1)); echo "$count" > "$COUNT_FILE"
        total_saved=$(< "$SAVED_FILE"); total_saved=$(( total_saved + '"$saved"' )); echo "$total_saved" > "$SAVED_FILE"
        total_in=$(< "$TOTAL_IN_FILE"); total_in=$(( total_in + '"$in_size"' )); echo "$total_in" > "$TOTAL_IN_FILE"
        echo "$count"
      ')
      echo -e "${PURPLE}[$n/$TOTAL]${RESET} ${GREEN}✔ $name.jxl${RESET} ${CYAN}(${in_kb}KB → ${out_kb}KB)${RESET}"
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

# ── Run ───────────────────────────────────────────────────
cat "$TEMP_LIST" | xargs -d '\n' -P "$THREADS" -I {} bash -c 'process_file "$@"' _ {}

# ── Summary ───────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_FMT="$((ELAPSED / 60))m $((ELAPSED % 60))s"
FINAL_COUNT=$(<"$COUNT_FILE")
FINAL_SKIPPED=$(<"$SKIPPED_FILE")
TOTAL_SAVED=$(<"$SAVED_FILE")
TOTAL_IN=$(<"$TOTAL_IN_FILE")

SAVED_MB_INT=$((TOTAL_SAVED / 1048576))
SAVED_MB_DEC=$(((TOTAL_SAVED % 1048576) * 10 / 1048576))
SAVED_MB="${SAVED_MB_INT}.${SAVED_MB_DEC}"
PERCENT=$((TOTAL_IN > 0 ? TOTAL_SAVED * 100 / TOTAL_IN : 0))

# Log
if [ "$LOG_MODE" = "1" ]; then
  LOG_FILE="$BASE/.compress-jxl.log"
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  # blank separator between runs in the same log
  [ -s "$LOG_FILE" ] && echo "" >>"$LOG_FILE"
  echo "[$NOW]  q=$QUALITY  e=$EFFORT  jobs=$THREADS  dir=$BASE  total=$TOTAL  converted=$FINAL_COUNT  skipped=$FINAL_SKIPPED  saved=${SAVED_MB}MB  pct=${PERCENT}%  elapsed=${ELAPSED_FMT}" >>"$LOG_FILE"
fi

# Cleanup
rm -f "$COUNT_FILE" "$SKIPPED_FILE" "$SAVED_FILE" "$TOTAL_IN_FILE" "$LOCK_FILE" "$TEMP_LIST"

echo ""
echo -e "${GREEN}Done! Converted $FINAL_COUNT/$TOTAL files. Skipped $FINAL_SKIPPED. Saved ${SAVED_MB}MB (${PERCENT}%) total.${RESET}"
if [ "$LOG_MODE" = "1" ]; then
  echo -e "${CYAN}Logged to $LOG_FILE${RESET}"
fi

if [ "$COMPARE_MODE" = "1" ]; then
  echo -e "${CYAN}Pre-encode sources saved to $CMP_DIR/${RESET}"
  echo -e "${CYAN}  → compare with: ssimulacra2 $CMP_DIR/name.png output/name.jxl${RESET}"
fi
