#!/usr/bin/env bash

INPUT="${1:-.}"
OUTPUT_DIR="${2:-./trimmed}"
mkdir -p "$OUTPUT_DIR"

# Build file list depending on whether input is a file or directory
if [[ -f "$INPUT" ]]; then
  files=("$INPUT")
elif [[ -d "$INPUT" ]]; then
  files=("$INPUT"/*.ts)
else
  echo "Error: $INPUT is not a valid file or directory"
  exit 1
fi

for f in "${files[@]}"; do
  fname=$(basename "$f")
  echo "Processing: $fname"

  vid_end=$(ffprobe -v error -select_streams v:0 \
    -show_entries packet=pts_time \
    -of csv=p=0 "$f" 2>/dev/null | tail -1 | tr -d ',\n')

  aud_end=$(ffprobe -v error -select_streams a:0 \
    -show_entries packet=pts_time \
    -of csv=p=0 "$f" 2>/dev/null | tail -1 | tr -d ',\n')

  if [[ -z "$vid_end" || -z "$aud_end" ]]; then
    echo "  SKIP: Could not read stream timestamps for $fname"
    continue
  fi

  diff=$(awk "BEGIN {print $aud_end - $vid_end}")
  needs_trim=$(awk "BEGIN {print ($aud_end - $vid_end > 5) ? 1 : 0}")

  if [[ "$needs_trim" -eq 1 ]]; then
    echo "  Trimming at ${vid_end}s (audio ends at ${aud_end}s, diff=${diff}s)"
    ffmpeg -v error -i "$f" -t "$vid_end" -c copy "$OUTPUT_DIR/$fname"
    if [[ -f "$OUTPUT_DIR/$fname" && -s "$OUTPUT_DIR/$fname" ]]; then
      rm "$f"
      echo "  Deleted original: $fname"
    else
      echo "  WARNING: Output file missing or empty, keeping original: $fname"
    fi
  else
    echo "  OK: streams roughly aligned (diff=${diff}s), skipping"
  fi
done
