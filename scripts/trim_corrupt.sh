#!/usr/bin/env bash

INPUT="${1:-.}"
OUTPUT_DIR="${2:-./trimmed}"
PARALLEL="${3:-$(nproc)}"
mkdir -p "$OUTPUT_DIR"

process() {
  local f="$1"
  local fname=$(basename "$f")
  echo "Processing: $fname"

  local vid_idx aud_idx vid_end aud_end diff needs_trim

  vid_idx=$(ffprobe -v error -show_entries stream=index,codec_type -of csv=p=0 "$f" 2>/dev/null | awk -F, '$2=="video"{print $1; exit}')
  aud_idx=$(ffprobe -v error -show_entries stream=index,codec_type -of csv=p=0 "$f" 2>/dev/null | awk -F, '$2=="audio"{print $1; exit}')

  if [[ -z "$vid_idx" || -z "$aud_idx" ]]; then
    echo "  SKIP: No video/audio stream found for $fname"
    return
  fi

  read vid_end aud_end < <(
    ffprobe -v error -show_entries packet=stream_index,pts_time -of csv=p=0 "$f" 2>/dev/null \
    | awk -F, -v vi="$vid_idx" -v ai="$aud_idx" \
        '{if($1==vi && $2>mv)mv=$2; else if($1==ai && $2>ma)ma=$2} END{print mv, ma}'
  )

  if [[ -z "$vid_end" || -z "$aud_end" ]]; then
    echo "  SKIP: Could not read stream timestamps for $fname"
    return
  fi

  read needs_trim diff < <(awk "BEGIN {d=$aud_end - $vid_end; print (d > 5) ? 1 : 0, d}")

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
}

if [[ -f "$INPUT" ]]; then
  process "$INPUT"
elif [[ -d "$INPUT" ]]; then
  for f in "$INPUT"/*.ts; do
    [[ -f "$f" ]] || continue
    process "$f" &
    while (( $(jobs -pr | wc -l) >= PARALLEL )); do wait -n; done
  done
  wait
else
  echo "Error: $INPUT is not a valid file or directory"
  exit 1
fi
