#!/bin/bash
# webp2hevc.sh — Combine all animated WebP files into one HEVC MKV (NVENC)
# Usage:
#   ./webp2hevc.sh                     # current dir → combined.mkv
#   ./webp2hevc.sh /path/to/webps      # specific folder
#   ./webp2hevc.sh -o frieren.mkv      # custom output name
#   ./webp2hevc.sh -q 20               # quality (0-51, lower=better, default 23)
#   ./webp2hevc.sh -f 30               # force FPS (default: auto-detect)

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
DIR="."
OUTPUT="combined.mkv"
CRF=23
FPS=""

# ── Resolve output to absolute path before we cd ────────────────────────────
resolve_abs() {
  case "$1" in
  /*) echo "$1" ;;
  *) echo "$PWD/$1" ;;
  esac
}

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o)
    OUTPUT="$2"
    shift 2
    ;;
  -q)
    CRF="$2"
    shift 2
    ;;
  -f)
    FPS="$2"
    shift 2
    ;;
  -h | --help)
    echo "Usage: $0 [dir] [-o output.mkv] [-q quality] [-f fps]"
    exit 0
    ;;
  *)
    DIR="$1"
    shift
    ;;
  esac
done

OUTPUT=$(resolve_abs "$OUTPUT")
cd "$DIR" || {
  echo "❌ Cannot cd to $DIR"
  exit 1
}

# ── Dependency checks ───────────────────────────────────────────────────────
for cmd in magick ffmpeg exiftool; do
  command -v "$cmd" &>/dev/null || {
    echo "❌ Missing: $cmd"
    exit 1
  }
done

ENCODER="hevc_nvenc"
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q hevc_nvenc; then
  echo "⚠️  hevc_nvenc not found — falling back to libx265 (CPU)"
  ENCODER="libx265"
fi

# ── Gather files (natural sort, safe for spaces) ────────────────────────────
mapfile -t FILES < <(printf '%s\n' *.webp 2>/dev/null | sort -V)

COUNT=${#FILES[@]}
if [[ $COUNT -eq 0 ]]; then
  echo "❌ No .webp files found in $(pwd)"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Directory: $(pwd)"
echo "  WebP files: $COUNT"
echo "  First:      ${FILES[0]}"
echo "  Last:       ${FILES[-1]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Auto-detect FPS from first file ─────────────────────────────────────────
if [[ -z "$FPS" ]]; then
  DELAY=$(exiftool -FrameDelay -b "${FILES[0]}" 2>/dev/null | head -1)
  if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then
    FPS=$(awk "BEGIN { printf \"%.2f\", 1000 / $DELAY }")
    echo "  FPS: $FPS (${DELAY}ms frame delay from ${FILES[0]})"
  else
    FPS=25
    echo "  FPS: 25 (default — no frame delay found)"
  fi
fi

# ── Temp folder for frames ──────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
trap 'rm -rf "$TMPDIR"; echo "🧹 Cleaned up (aborted)"' ERR INT

echo ""
echo "━━━ Extracting frames from all WebPs ━━━"

idx=0
for f in "${FILES[@]}"; do
  printf "\r  [%3d/%3d] %s" $((idx + 1)) "$COUNT" "$f"
  # Coalesce handles animated WebP disposal modes correctly
  magick "$f" -coalesce "${TMPDIR}/frame_$(printf '%04d' "$idx")_%03d.png"
  idx=$((idx + 1))
done
echo ""

TOTAL_FRAMES=$(ls -1 "$TMPDIR" | wc -l)
echo "  Total frames extracted: $TOTAL_FRAMES"

# ── Encode with NVENC H.265 ─────────────────────────────────────────────────
echo ""
echo "━━━ Encoding with ${ENCODER} ━━━"
echo "  FPS: $FPS | CRF: $CRF | Output: $OUTPUT"

ffmpeg -y \
  -framerate "$FPS" \
  -pattern_type glob -i "${TMPDIR}/frame_*.png" \
  -c:v "$ENCODER" \
  -preset p7 \
  -cq "$CRF" \
  -rc vbr \
  -b:v 0 \
  -pix_fmt yuv420p \
  -profile:v main \
  -tag:v hvc1 \
  "$OUTPUT"

echo ""
echo "✅ Done!"
echo "  Output: $OUTPUT"
echo "  Size:   $(du -h "$OUTPUT" | cut -f1)"
