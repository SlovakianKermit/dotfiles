#!/usr/bin/env bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────
BASE_ROOT="$HOME/Pictures/img/Downloads"
EXCLUDE_DIRS=("Cooking")
QUALITY=85
EFFORT=3
THREADS=$(nproc)
LOG_MODE=0
COMPARE_MODE=0
TARGET_W=0
TARGET_H=0

# ── Usage ─────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: compress-jxl.sh [-q <quality>] [-e <effort>] [-s <WxH|none>] [-t <threads>] [-c] [-l]
                        [directory | quality [effort]]

Recursively convert images to JPEG XL. Replaces originals only when smaller.

  -q, --quality N    Quality 0-100 (default: $QUALITY)
  -e, --effort N     Encoder effort 1-10 (default: $EFFORT)
  -s, --size WxH     Max dimensions, fits within box keeping aspect, or 'none'
                     (default: none — images keep their original size)
  -t, --threads N    Parallel jobs (default: $(nproc))
  -c, --compare      Save pre-encode PNGs to /tmp/jxl_compare_src/
  -l, --log          Save a log file in the images directory
  -h, --help         Show this help

Examples:
  compress-jxl.sh                        # defaults on ~/Pictures/img/Downloads
  compress-jxl.sh 80                     # quality 80, default dir
  compress-jxl.sh 90 5                   # quality 90, effort 5
  compress-jxl.sh ~/Pics 80 5            # custom dir, q80, e5
  compress-jxl.sh -q 75 -e 3 -c          # named flags + compare mode
  compress-jxl.sh -l -e 1                # log timing + results
  compress-jxl.sh -s none ~/Pics         # never downscale (default)
  compress-jxl.sh -s 1920x1080 ~/Pics    # cap at 1080p
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
  -s | --size)
    if [[ "$2" == "none" || "$2" == "0" ]]; then
      TARGET_W=0
      TARGET_H=0
      shift 2
    elif [[ "$2" =~ ^[0-9]+x[0-9]+$ ]]; then
      TARGET_W="${2%%x*}"
      TARGET_H="${2##*x}"
      shift 2
    else
      echo "Invalid size: $2 (expected WxH or 'none', e.g. 1920x1080)" >&2
      exit 1
    fi
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

if ! command -v python3 &>/dev/null; then
  echo "python3 not found." >&2
  exit 1
fi

# ── Resize engine ─────────────────────────────────────────
# vipsthumbnail (libvips) is 4-10× faster; falls back to ImageMagick
if command -v vipsthumbnail &>/dev/null; then
  RESIZE_ENGINE="vipsthumbnail (libvips)"
else
  RESIZE_ENGINE="convert (ImageMagick)"
fi

# One cjxl thread per parallel job avoids CPU oversubscription; when running
# a single job, let cjxl use every core.
if [ "$THREADS" -ge 4 ]; then
  CJXL_THREADS=1
else
  CJXL_THREADS=-1
fi

# ── Metadata scanner ──────────────────────────────────────
# Reads PNG text chunks (Parameters/Prompt/Workflow/... used by AI tools),
# native EXIF and native XMP straight from the file, then writes:
#   <prefix>.exif  raw TIFF block, when present
#   <prefix>.xmp   native XMP merged with the PNG text chunks, when present
# and prints:  W H BITDEPTH COLORTYPE HAS_ICC EXIF_PATH XMP_PATH
SCAN_PY=$(mktemp /tmp/jxl_scan.XXXXXX.py)

cat >"$SCAN_PY" <<'PY'
import sys, struct, zlib
import xml.etree.ElementTree as ET

NS = "https://ns.muqiu.dev/png-text/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
XMNS = "adobe:ns:meta/"


def esc_name(k):
    """Reversible XML-name escape: _xHHHH_ for characters XML forbids."""
    out = []
    for c in k:
        if c.isalnum() or c in "._-":
            out.append(c)
        else:
            out.append("_x%04X_" % ord(c))
    name = "".join(out)
    if not name or not (name[0].isalpha() or name[0] == "_"):
        name = "t_" + name
    return name


def parse_png(path):
    w = h = bd = ct = None
    icc = False
    exif = xmp = None
    texts = {}
    with open(path, "rb") as f:
        if f.read(8) != b"\x89PNG\r\n\x1a\n":
            return None
        while True:
            head = f.read(8)
            if len(head) < 8:
                break
            ln, typ = struct.unpack(">I4s", head)
            if typ == b"IHDR":
                d = f.read(ln)
                w, h, bd, ct = struct.unpack(">IIBB", d[:10])
                f.read(4)
                continue
            if typ == b"IDAT":
                break
            if typ == b"iCCP":
                icc = True
                f.seek(ln + 4, 1)
                continue
            if typ == b"eXIf":
                exif = f.read(ln)
                f.read(4)
                continue
            if typ in (b"tEXt", b"iTXt", b"zTXt"):
                d = f.read(ln)
                f.read(4)
                try:
                    if typ == b"tEXt":
                        k, v = d.split(b"\x00", 1)
                        k = k.decode("latin-1")
                        v = v.decode("latin-1")
                    elif typ == b"zTXt":
                        k, rest = d.split(b"\x00", 1)
                        k = k.decode("latin-1")
                        v = zlib.decompress(rest[1:]).decode("latin-1")
                    else:
                        k, rest = d.split(b"\x00", 1)
                        comp = rest[0]
                        _, rest = rest[1:].split(b"\x00", 1)
                        _, v = rest.split(b"\x00", 1)
                        k = k.decode("latin-1")
                        v = zlib.decompress(v).decode("utf-8") if comp else v.decode("utf-8")
                except Exception:
                    continue
                if k == "XML:com.adobe.xmp":
                    xmp = v
                else:
                    texts[k] = v
                continue
            f.seek(ln + 4, 1)
    return w, h, bd, ct, icc, exif, xmp, texts


def parse_jpeg(path):
    w = h = None
    icc = False
    exif = xmp = None
    with open(path, "rb") as f:
        if f.read(2) != b"\xff\xd8":
            return None
        while True:
            b = f.read(1)
            if not b:
                break
            if b != b"\xff":
                continue
            m = f.read(1)
            while m == b"\xff":
                m = f.read(1)
            if not m or m in (b"\xd8", b"\x01", b"\xd9"):
                continue
            if 0xD0 <= m[0] <= 0xD7:
                continue
            ln = struct.unpack(">H", f.read(2))[0]
            seg = f.read(ln - 2)
            if m == b"\xe1":
                if seg.startswith(b"Exif\x00\x00"):
                    exif = seg[6:]
                elif seg.startswith(b"http://ns.adobe.com/xap/1.0/\x00"):
                    xmp = seg[29:]
            elif m == b"\xe2" and seg.startswith(b"ICC_PROFILE\x00"):
                icc = True
            if 0xC0 <= m[0] <= 0xCF and m not in (b"\xc4", b"\xc8", b"\xcc"):
                h, w = struct.unpack(">HH", seg[1:5])
    return w, h, 8, 2, icc, exif, xmp, {}


def build_xmp(texts, native):
    if native and not texts:
        return native.decode("utf-8", "replace") if isinstance(native, bytes) else native
    root = desc = rdf = None
    if native:
        try:
            root = ET.fromstring(native)
            rdf = root.find(f"{{{RDF}}}RDF")
            desc = rdf.find(f"{{{RDF}}}Description") if rdf is not None else None
        except Exception:
            root = desc = None
    if root is None:
        root = ET.Element(f"{{{XMNS}}}xmpmeta")
        rdf = ET.SubElement(root, f"{{{RDF}}}RDF")
        desc = ET.SubElement(rdf, f"{{{RDF}}}Description", {f"{{{RDF}}}about": ""})
    if desc is None:
        desc = ET.SubElement(rdf, f"{{{RDF}}}Description", {f"{{{RDF}}}about": ""})
    ET.register_namespace("ax", NS)
    ET.register_namespace("rdf", RDF)
    ET.register_namespace("x", XMNS)
    for k, v in texts.items():
        el = ET.SubElement(desc, f"{{{NS}}}{esc_name(k)}")
        el.text = v
    xml = ET.tostring(root, encoding="unicode")
    return (
        '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        + xml
        + '\n<?xpacket end="w"?>'
    )


def main():
    path, prefix = sys.argv[1], sys.argv[2]
    ext = path.rsplit(".", 1)[-1].lower()
    r = parse_png(path) if ext == "png" else parse_jpeg(path) if ext in ("jpg", "jpeg") else None
    if not r:
        print("- - 0 0 0 - -")
        return
    w, h, bd, ct, icc, exif, native_xmp, texts = r
    exif_out = xmp_out = "-"
    if exif:
        exif_out = prefix + ".exif"
        with open(exif_out, "wb") as f:
            f.write(exif)
    if native_xmp or texts:
        xmp_out = prefix + ".xmp"
        with open(xmp_out, "w", encoding="utf-8") as f:
            f.write(build_xmp(texts, native_xmp))
    print(w, h, bd, ct, 1 if icc else 0, exif_out, xmp_out)


main()
PY

cd /tmp || exit 1

MAIN_PID=$$
WORK_DIR="/tmp/jxl_meta_${MAIN_PID}"
mkdir -p "$WORK_DIR"

cleanup() {
  rm -f "${TEMP_LIST:-}" "${COUNT_FILE:-}" "${SKIPPED_FILE:-}" "${SAVED_FILE:-}" "${TOTAL_IN_FILE:-}" "${LOCK_FILE:-}" "${SCAN_PY:-}" 2>/dev/null
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR" 2>/dev/null || true
  [ -n "${BASE:-}" ] && find "$BASE" -name "*.jxl.tmp.${MAIN_PID:-0}_*" -delete 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM

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
PRUNE_ARGS=()
for d in "${EXCLUDE_DIRS[@]}"; do
  PRUNE_ARGS+=(\( -type d -name "$d" -prune \))
  PRUNE_ARGS+=(-o)
done
echo "Scanning for images in: $BASE (excluding: ${EXCLUDE_DIRS[*]})"
TEMP_LIST="/tmp/jxl_filelist.$$"
COUNT_FILE="/tmp/jxl_count.$$"
SKIPPED_FILE="/tmp/jxl_skipped.$$"
SAVED_FILE="/tmp/jxl_saved.$$"
TOTAL_IN_FILE="/tmp/jxl_totalin.$$"
LOCK_FILE="/tmp/jxl_lock.$$"

find "$BASE" "${PRUNE_ARGS[@]}" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print >"$TEMP_LIST"
TOTAL=$(wc -l <"$TEMP_LIST")

SIZE_DESC="no downscale"
[ "$TARGET_W" -gt 0 ] && SIZE_DESC="max ${TARGET_W}x${TARGET_H}"

echo "Found $TOTAL files to convert"
echo "Using cjxl with quality $QUALITY, effort $EFFORT, $SIZE_DESC, $THREADS parallel jobs, resize: $RESIZE_ENGINE"
echo "Metadata preservation: EXIF/XMP embedded by cjxl; PNG text chunks (AI prompts, ComfyUI workflows) wrapped into XMP"
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
  COMPARE_MODE CMP_DIR MAIN_PID WORK_DIR SCAN_PY CJXL_THREADS \
  PURPLE GREEN RED CYAN YELLOW RESET

# ── Per-file worker ───────────────────────────────────────
process_file() {
  local f="$1"
  local dir file name output n in_size out_size saved
  local img_w img_h img_bd img_ct img_icc exif_path xmp_path
  local src tmp_resized tmp_out fmt_args meta_args

  dir="$(dirname "$f")"
  file="$(basename "$f")"
  name="$file"
  while [[ "${name,,}" =~ \.(png|jpg|jpeg)$ ]]; do
    name="${name%.*}"
  done

  output="$dir/$name.jxl"
  in_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  in_kb=$((in_size / 1024))

  local prefix="${WORK_DIR}/m_${MAIN_PID}_${RANDOM}"
  read -r img_w img_h img_bd img_ct img_icc exif_path xmp_path < <(
    python3 "$SCAN_PY" "$f" "$prefix" 2>/dev/null
  ) || true

  # ── Optional downscale ──────────────────────────────────
  tmp_resized=""
  src="$f"
  if [ "${TARGET_W:-0}" -gt 0 ] && [[ "$img_w" =~ ^[0-9]+$ ]] &&
    { [ "$img_w" -gt "$TARGET_W" ] || [ "$img_h" -gt "$TARGET_H" ]; }; then
    # PPM is ~4x faster to write and encode than PNG; safe only for opaque,
    # 8-bit, profile-free sources (PPM carries neither alpha nor ICC).
    local ext=png
    if [ "$img_bd" = "8" ] && { [ "$img_ct" = "0" ] || [ "$img_ct" = "2" ]; } && [ "$img_icc" = "0" ]; then
      ext=ppm
    fi
    tmp_resized="/tmp/jxl_resized_${MAIN_PID}_${RANDOM}.${ext}"
    if command -v vipsthumbnail &>/dev/null; then
      vipsthumbnail "$f" --size "${TARGET_W}x${TARGET_H}" -o "$tmp_resized" 2>/dev/null || true
    else
      convert "$f" -resize "${TARGET_W}x${TARGET_H}>" "$tmp_resized" 2>/dev/null || true
    fi
    if [ -s "$tmp_resized" ]; then
      src="$tmp_resized"
    else
      rm -f "$tmp_resized"
      tmp_resized=""
    fi
  fi

  fmt_args=()
  [[ "$src" == *.ppm ]] && fmt_args+=(-x color_space=sRGB)
  meta_args=()
  [ -n "$exif_path" ] && [ "$exif_path" != "-" ] && [ -s "$exif_path" ] && meta_args+=(-x "exif=$exif_path")
  [ -n "$xmp_path" ] && [ "$xmp_path" != "-" ] && [ -s "$xmp_path" ] && meta_args+=(-x "xmp=$xmp_path")

  # --- Compare mode: save pre-encode source as PNG ---
  if [ "$COMPARE_MODE" = "1" ]; then
    convert "$src" "${CMP_DIR}/${name}.png" 2>/dev/null || true
  fi

  # --- Encode to a temp file so an interrupted run never leaves a
  # partial .jxl sitting under its final name. ---
  tmp_out="${output}.tmp.${MAIN_PID}_${RANDOM}"
  if cjxl "$src" "$tmp_out" -q "$QUALITY" -e "$EFFORT" \
    --num_threads "$CJXL_THREADS" --lossless_jpeg=0 --quiet \
    "${fmt_args[@]}" "${meta_args[@]}" 2>/dev/null; then
    out_size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
    out_kb=$((out_size / 1024))

    if [ -f "$tmp_out" ] && [ "$out_size" -gt 0 ] && [ "$out_size" -lt "$in_size" ]; then
      mv "$tmp_out" "$output"
      touch -r "$f" "$output"
      [ -n "$tmp_resized" ] && rm -f "$tmp_resized"

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
      rm -f "$tmp_out"
      [ -n "$tmp_resized" ] && rm -f "$tmp_resized"
      flock "$LOCK_FILE" bash -c '
        skipped=$(< "$SKIPPED_FILE"); skipped=$((skipped + 1)); echo "$skipped" > "$SKIPPED_FILE"
      '
      echo -e "${YELLOW}⊘ Skipped: $file (compressed output was not smaller)${RESET}"
    fi
  else
    rm -f "$tmp_out"
    [ -n "$tmp_resized" ] && rm -f "$tmp_resized"
    echo -e "${RED}✗ Failed: $file${RESET}" >&2
  fi

  rm -f "${prefix}.exif" "${prefix}.xmp" 2>/dev/null || true
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
  [ -s "$LOG_FILE" ] && echo "" >>"$LOG_FILE"
  echo "[$NOW]  q=$QUALITY  e=$EFFORT  jobs=$THREADS  size=$SIZE_DESC  dir=$BASE  total=$TOTAL  converted=$FINAL_COUNT  skipped=$FINAL_SKIPPED  saved=${SAVED_MB}MB  pct=${PERCENT}%  elapsed=${ELAPSED_FMT}" >>"$LOG_FILE"
fi

# Cleanup
cleanup

echo ""
echo -e "${GREEN}Done! Converted $FINAL_COUNT/$TOTAL files. Skipped $FINAL_SKIPPED. Saved ${SAVED_MB}MB (${PERCENT}%) total.${RESET}"
if [ "$LOG_MODE" = "1" ]; then
  echo -e "${CYAN}Logged to $LOG_FILE${RESET}"
fi

if [ "$COMPARE_MODE" = "1" ]; then
  echo -e "${CYAN}Pre-encode sources saved to $CMP_DIR/${RESET}"
  echo -e "${CYAN}  → compare with: ssimulacra2 $CMP_DIR/name.png output/name.jxl${RESET}"
fi
