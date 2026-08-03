#!/usr/bin/env bash
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
INPUT_DIR="/mnt/shared/Compressing"
OUTPUT_DIR="/mnt/shared/Handbraked"
PRESET_SPEED="balanced" # speed | balanced | quality
QUALITY="28"            # QP value (lower = better quality, bigger file)
EXTENSIONS=("mkv" "mp4" "avi" "mov" "webm" "ts" "mts")
DRY_RUN=false
DELETE_ORIGINAL=true
SINGLE_INPUT=""
SINGLE_OUTPUT=""
START_TIME=$(date +%s)

# Size tracking (bytes)
TOTAL_IN_BYTES=0
TOTAL_OUT_BYTES=0

# ─── VAAPI defaults (tuned for RX 9070 / RDNA4) ───────────────────────────────
HWACCEL="vaapi"
HWACCEL_OUTPUT="vaapi"
ENCODER="hevc_vaapi"

# ─── Colours (only when stdout is a TTY) ───────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_MAGENTA=$'\033[35m'
else
  C_RESET= C_BOLD= C_DIM= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_MAGENTA=
fi

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

VAAPI HEVC batch encoder. Encodes all videos in a directory tree.

Options:
  -i DIR         Input directory (batch mode)
  -o DIR         Output directory (batch mode)
  --input FILE   Single input file
  --output FILE  Single output file
  -p PRESET      speed | balanced | quality (default: balanced)
  -q QP          QP value (default: 28, lower = better)
  -n             Dry run (show what would be done)
  -D             Delete original after successful encode (on by default)
  -h             Show this help

Examples:
  $(basename "$0")                                    # compress everything in default dirs
  $(basename "$0") -i ~/Videos/raw -o ~/Videos/encoded -p quality
  $(basename "$0") --input video.mkv --output video-hevc.mkv -p speed
EOF
  exit 0
}

# ─── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
  -i)
    INPUT_DIR="$2"
    shift 2
    ;;
  -o)
    OUTPUT_DIR="$2"
    shift 2
    ;;
  --input)
    SINGLE_INPUT="$2"
    shift 2
    ;;
  --output)
    SINGLE_OUTPUT="$2"
    shift 2
    ;;
  -p)
    PRESET_SPEED="$2"
    shift 2
    ;;
  -q)
    QUALITY="$2"
    shift 2
    ;;
  -n)
    DRY_RUN=true
    shift
    ;;
  -D)
    DELETE_ORIGINAL=true
    shift
    ;;
  -h) usage ;;
  *)
    echo "Error: Unknown flag: $1"
    usage
    ;;
  esac
done

# ─── Validate preset ──────────────────────────────────────────────────────────
case "$PRESET_SPEED" in
speed) PRESET_FLAG="-preset fast" ;;
balanced) PRESET_FLAG="" ;;
quality) PRESET_FLAG="-preset slow" ;;
*)
  echo "Error: --preset must be speed, balanced, or quality"
  exit 1
  ;;
esac

# ─── Helpers ──────────────────────────────────────────────────────────────────
human_bytes() {
  local bytes="${1:-0}"
  # Handle negative (output larger than input)
  local sign=""
  if ((bytes < 0)); then
    sign="-"
    bytes=$((-bytes))
  fi
  if command -v numfmt &>/dev/null; then
    printf '%s%s' "$sign" "$(numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes" 2>/dev/null || numfmt --to=iec-i --suffix=B "$bytes")"
  else
    local units=(B KiB MiB GiB TiB) i=0
    local val="$bytes"
    while ((val >= 1024 && i < ${#units[@]} - 1)); do
      val=$((val / 1024))
      ((i++)) || true
    done
    if ((i == 0)); then
      printf '%s%d %s' "$sign" "$val" "${units[$i]}"
    else
      # one decimal via awk for the remainder case
      awk -v b="$bytes" -v i="$i" -v s="$sign" -v u="${units[$i]}" 'BEGIN {
        v = b / (1024 ^ i)
        printf "%s%.1f %s", s, v, u
      }'
    fi
  fi
}

get_duration() {
  # Seconds as float string, or 0 on failure
  ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo "0"
}

file_size() {
  stat -c%s "$1" 2>/dev/null || echo 0
}

# Force .mkv container for all outputs (keeps directory + basename)
to_mkv() {
  local path="$1"
  echo "${path%.*}.mkv"
}

# Draw a single in-place status line
# Args: video_pct queue_pct fps queue_idx queue_total
draw_progress() {
  local video_pct="$1"
  local queue_pct="$2"
  local fps="$3"
  local queue_idx="$4"
  local queue_total="$5"

  # Clamp display values
  ((video_pct > 100)) && video_pct=100
  ((video_pct < 0)) && video_pct=0
  ((queue_pct > 100)) && queue_pct=100
  ((queue_pct < 0)) && queue_pct=0

  # Clear to end of line so shorter updates don't leave garbage
  printf '\r%s%3d%%%s  %s%3d%%%s %s(%d/%d)%s  %s%s fps%s\033[K' \
    "${C_CYAN}${C_BOLD}" "$video_pct" "${C_RESET}${C_DIM} video${C_RESET}" \
    "${C_GREEN}${C_BOLD}" "$queue_pct" "${C_RESET}${C_DIM} queue${C_RESET}" \
    "${C_DIM}" "$queue_idx" "$queue_total" "${C_RESET}" \
    "${C_YELLOW}${C_BOLD}" "$fps" "${C_RESET}"
}

# ─── Run ffmpeg with live progress ────────────────────────────────────────────
# Args: input output [queue_idx queue_total]
run_ffmpeg() {
  local input="$1"
  local output="$2"
  local queue_idx="${3:-1}"
  local queue_total="${4:-1}"

  local -a cmd=(
    ffmpeg -hide_banner -loglevel error
    -progress pipe:1 -nostats
    -hwaccel "$HWACCEL" -hwaccel_output_format "$HWACCEL_OUTPUT"
    -i "$input"
    -c:v "$ENCODER"
  )
  [[ -n "$PRESET_FLAG" ]] && cmd+=($PRESET_FLAG)
  cmd+=(-b:v 0 -qp "$QUALITY")
  cmd+=(-c:a copy)
  # Map video+audio only, skip subtitles to avoid DVB/teletext failures on .ts sources
  cmd+=(-map 0:v? -map 0:a?)
  cmd+=(-y "$output")

  if $DRY_RUN; then
    printf '[DRY RUN]'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    return 0
  fi

  mkdir -p "$(dirname "$output")"

  local duration
  duration=$(get_duration "$input")

  local in_bytes
  in_bytes=$(file_size "$input")

  local err_file last_fps_file
  err_file=$(mktemp)
  last_fps_file=$(mktemp)
  echo "0.0" >"$last_fps_file"
  local rc=0

  # Stream structured progress on stdout; keep errors for failure reporting
  set +e
  "${cmd[@]}" 2>"$err_file" | {
    local key value
    local out_time_us=0
    local fps="0.0"
    local video_pct=0
    local queue_pct=0
    local fps_disp="0.0"

    while IFS='=' read -r key value; do
      case "$key" in
      out_time_us)
        out_time_us="$value"
        ;;
      fps)
        # ffmpeg sometimes reports "N/A" early on
        if [[ "$value" =~ ^[0-9.]+$ ]]; then
          fps="$value"
          printf '%.1f\n' "$fps" >"$last_fps_file"
        fi
        ;;
      progress)
        if [[ "$value" == "continue" || "$value" == "end" ]]; then
          video_pct=$(awk -v t="$out_time_us" -v d="$duration" 'BEGIN {
            if (d + 0 <= 0) { print 0; exit }
            p = (t / 1000000.0) / d * 100
            if (p > 100) p = 100
            if (p < 0) p = 0
            printf "%d", p + 0.5
          }')
          # Queue % weights completed files + current video progress
          queue_pct=$(awk -v done=$((queue_idx - 1)) -v total="$queue_total" -v vp="$video_pct" 'BEGIN {
            if (total + 0 <= 0) { print 0; exit }
            p = (done + vp / 100.0) / total * 100
            if (p > 100) p = 100
            printf "%d", p + 0.5
          }')
          fps_disp=$(awk -v f="$fps" 'BEGIN { printf "%.1f", f + 0 }')
          draw_progress "$video_pct" "$queue_pct" "$fps_disp" "$queue_idx" "$queue_total"
        fi
        ;;
      esac
    done
  }
  rc=${PIPESTATUS[0]}
  set -e

  local last_fps
  last_fps=$(cat "$last_fps_file" 2>/dev/null || echo "0.0")
  rm -f "$last_fps_file"

  # Finish the progress line at 100% on success
  if [[ $rc -eq 0 ]]; then
    draw_progress 100 \
      "$(awk -v i="$queue_idx" -v t="$queue_total" 'BEGIN { printf "%d", (i / t) * 100 + 0.5 }')" \
      "$last_fps" \
      "$queue_idx" "$queue_total"
    printf '\n'
  else
    printf '\n'
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2
    fi
  fi
  rm -f "$err_file"

  # Guard against zero-byte or truncated output
  if [[ $rc -eq 0 ]] && [[ ! -s "$output" ]]; then
    echo "Error: ffmpeg exited 0 but output is empty/truncated: $output" >&2
    return 1
  fi

  if [[ $rc -eq 0 ]]; then
    local out_bytes
    out_bytes=$(file_size "$output")
    TOTAL_IN_BYTES=$((TOTAL_IN_BYTES + in_bytes))
    TOTAL_OUT_BYTES=$((TOTAL_OUT_BYTES + out_bytes))
  fi

  return $rc
}

# ─── Progress header for each file ────────────────────────────────────────────
show_file_header() {
  local current="$1"
  local total="$2"
  local file="$3"
  local elapsed
  elapsed=$(($(date +%s) - START_TIME))
  printf '\n%s[%d/%d]%s %s%s%s  %s(elapsed %02d:%02d:%02d)%s\n' \
    "${C_BOLD}" "$current" "$total" "${C_RESET}" \
    "${C_MAGENTA}" "$(basename "$file")" "${C_RESET}" \
    "${C_DIM}" \
    $((elapsed / 3600)) $((elapsed % 3600 / 60)) $((elapsed % 60)) \
    "${C_RESET}"
}

# ─── End-of-run size summary ──────────────────────────────────────────────────
print_size_summary() {
  if ((TOTAL_IN_BYTES == 0)); then
    return 0
  fi

  local saved=$((TOTAL_IN_BYTES - TOTAL_OUT_BYTES))
  local pct
  pct=$(awk -v s="$saved" -v t="$TOTAL_IN_BYTES" 'BEGIN {
    printf "%.1f", (s / t) * 100
  }')

  echo ""
  printf '%sSize%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  Original : %s\n' "$(human_bytes "$TOTAL_IN_BYTES")"
  printf '  Encoded  : %s\n' "$(human_bytes "$TOTAL_OUT_BYTES")"
  if ((saved >= 0)); then
    printf '  Saved    : %s%s%s (%s%s%%%s)\n' \
      "${C_GREEN}${C_BOLD}" "$(human_bytes "$saved")" "${C_RESET}" \
      "${C_GREEN}${C_BOLD}" "$pct" "${C_RESET}"
  else
    # Negative savings — output grew
    local grew=$((-saved))
    local grew_pct
    grew_pct=$(awk -v s="$grew" -v t="$TOTAL_IN_BYTES" 'BEGIN { printf "%.1f", (s / t) * 100 }')
    printf '  Grew     : %s%s%s (+%s%s%%%s)\n' \
      "${C_RED}${C_BOLD}" "$(human_bytes "$grew")" "${C_RESET}" \
      "${C_RED}${C_BOLD}" "$grew_pct" "${C_RESET}"
  fi
}

# ─── Check VAAPI availability ─────────────────────────────────────────────────
check_vaapi() {
  if ! vainfo &>/dev/null; then
    echo "Error: vainfo not found. Is VAAPI set up?"
    echo "  sudo pacman -S libva-utils"
    exit 1
  fi
  if ! ffmpeg -hide_banner -hwaccels | grep -q vaapi; then
    echo "Error: VAAPI hwaccel not available in ffmpeg"
    exit 1
  fi
}

# ─── Collect files ────────────────────────────────────────────────────────────
collect_files() {
  local dir="$1"
  local -n ref=$2
  local -a find_args=()

  for ext in "${EXTENSIONS[@]}"; do
    find_args+=(-iname "*.$ext" -o)
  done
  unset 'find_args[-1]' # remove trailing -o

  mapfile -t ref < <(find "$dir" -type f \( "${find_args[@]}" \) | sort)
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

check_vaapi

# ─── Single-file mode ─────────────────────────────────────────────────────────
if [[ -n "$SINGLE_INPUT" ]]; then
  if [[ -z "$SINGLE_OUTPUT" ]]; then
    SINGLE_OUTPUT="${SINGLE_INPUT%.*}-hevc.mkv"
  else
    SINGLE_OUTPUT="$(to_mkv "$SINGLE_OUTPUT")"
  fi
  echo "Encoding: $SINGLE_INPUT -> $SINGLE_OUTPUT"
  echo "Preset: $PRESET_SPEED | QP: $QUALITY"
  echo "----------------------------------------"
  show_file_header 1 1 "$SINGLE_INPUT"
  run_ffmpeg "$SINGLE_INPUT" "$SINGLE_OUTPUT" 1 1
  exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "Done: $SINGLE_OUTPUT"
    if $DELETE_ORIGINAL; then
      rm "$SINGLE_INPUT" && echo "Deleted original: $SINGLE_INPUT"
    fi
    print_size_summary
  else
    echo "Failed (exit code: $exit_code)"
    exit $exit_code
  fi
  exit 0
fi

# ─── Batch mode ───────────────────────────────────────────────────────────────
if [[ -z "$INPUT_DIR" ]] || [[ -z "$OUTPUT_DIR" ]]; then
  echo "Error: batch mode requires -i and -o (or use --input/--output for single file)"
  usage
fi

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: Input directory not found: $INPUT_DIR"
  exit 1
fi

declare -a FILES
collect_files "$INPUT_DIR" FILES

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No video files found in: $INPUT_DIR"
  echo "Searched extensions: ${EXTENSIONS[*]}"
  exit 1
fi

echo "Found ${#FILES[@]} video file(s)"
echo "Preset: $PRESET_SPEED | QP: $QUALITY"
echo "Output: $OUTPUT_DIR"
echo "----------------------------------------"

mkdir -p "$OUTPUT_DIR"

SUCCESS=0
FAILED=0
TOTAL_FILES=${#FILES[@]}

for i in "${!FILES[@]}"; do
  INPUT="${FILES[$i]}"
  REL="${INPUT#$INPUT_DIR/}"
  # Always write Matroska (.mkv), regardless of source extension
  OUTPUT="$(to_mkv "$OUTPUT_DIR/$REL")"
  idx=$((i + 1))

  show_file_header "$idx" "$TOTAL_FILES" "$INPUT"

  if run_ffmpeg "$INPUT" "$OUTPUT" "$idx" "$TOTAL_FILES"; then
    SUCCESS=$((SUCCESS + 1))
    if $DELETE_ORIGINAL; then
      rm "$INPUT" && echo "  Deleted original"
    fi
  else
    FAILED=$((FAILED + 1))
    echo "  FAILED: $INPUT"
  fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(($(date +%s) - START_TIME))
echo ""
echo "═══════════════════════════════════════════"
printf ' %sDone.%s Success: %s%d%s | Failed: %s%d%s\n' \
  "${C_BOLD}" "${C_RESET}" \
  "${C_GREEN}" "$SUCCESS" "${C_RESET}" \
  "$([[ $FAILED -gt 0 ]] && echo "$C_RED" || echo "$C_DIM")" "$FAILED" "${C_RESET}"
printf ' Total time: %02d:%02d:%02d\n' \
  $((TOTAL_ELAPSED / 3600)) $((TOTAL_ELAPSED % 3600 / 60)) $((TOTAL_ELAPSED % 60))
print_size_summary
echo "═══════════════════════════════════════════"

[[ $FAILED -gt 0 ]] && exit 1
exit 0
