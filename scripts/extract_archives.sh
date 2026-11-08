#!/usr/bin/env bash

set -uo pipefail

DEPTH=1
declare -a PATHS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d | --depth)
      DEPTH="${2:-}"
      shift 2
      ;;
    -h | --help)
      echo "Usage: $(basename "$0") [OPTIONS] [PATH...]"
      echo ""
      echo "Extract archives. PATH may be a directory (archives up to DEPTH levels"
      echo "inside it are processed) or an archive file (processed directly,"
      echo "bypassing the directory scan). Default PATH is the current directory."
      echo ""
      echo "Options:"
      echo "  -d, --depth N   Process archives up to N directories deep (default: 1)"
      echo "  -h, --help      Show this help"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$DEPTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid depth: '$DEPTH'" >&2
  exit 1
fi

declare -a FAILED=()

extract_archive() {
  local archive="$1"
  local dir ext target fmt base

  dir="$(dirname "$archive")"
  ext="${archive,,}" # lowercase copy for matching

  # Determine format
  if [[ "$ext" == *.tar.gz || "$ext" == *.tgz ]]; then
    fmt="tar.gz"
    base="$(basename "$archive" .tar.gz)"
    [[ "$ext" == *.tgz ]] && base="$(basename "$archive" .tgz)"
  elif [[ "$ext" == *.tar.bz2 || "$ext" == *.tbz2 ]]; then
    fmt="tar.bz2"
    base="$(basename "$archive" .tar.bz2)"
    [[ "$ext" == *.tbz2 ]] && base="$(basename "$archive" .tbz2)"
  elif [[ "$ext" == *.tar.xz || "$ext" == *.txz ]]; then
    fmt="tar.xz"
    base="$(basename "$archive" .tar.xz)"
    [[ "$ext" == *.txz ]] && base="$(basename "$archive" .txz)"
  elif [[ "$ext" == *.tar ]]; then
    fmt="tar"
    base="$(basename "$archive" .tar)"
  elif [[ "$ext" == *.zip ]]; then
    fmt="zip"
    base="$(basename "$archive" .zip)"
  elif [[ "$ext" == *.7z ]]; then
    fmt="7z"
    base="$(basename "$archive" .7z)"
  else
    echo "  [SKIP] Unsupported format: $archive"
    return 0
  fi

  target="$dir/$base"

  echo "Processing: $archive"

  # --- Integrity check ---
  local check_ok=0
  case "$fmt" in
  zip)
    unzip -qt "$archive" </dev/null &>/dev/null && check_ok=1
    ;;
  tar | tar.gz | tar.bz2 | tar.xz)
    case "$fmt" in
    tar.gz)
      gzip -t "$archive" &>/dev/null && check_ok=1
      ;;
    tar.bz2)
      bzip2 -t "$archive" &>/dev/null && check_ok=1
      ;;
    tar.xz)
      xz -t "$archive" &>/dev/null && check_ok=1
      ;;
    tar)
      tar -tf "$archive" &>/dev/null && check_ok=1
      ;;
    esac
    ;;
  7z)
    7z t -y "$archive" </dev/null &>/dev/null && check_ok=1
    ;;
  esac

  if [[ $check_ok -eq 0 ]]; then
    echo "  [FAIL] Integrity check failed, keeping archive: $archive"
    FAILED+=("$archive")
    return 0
  fi

  echo "  [OK] Integrity verified"

  # --- Extract ---
  local extract_ok=0 created=0
  if [[ ! -e "$target" ]]; then
    created=1
  fi
  mkdir -p "$target" || {
    echo "  [FAIL] Could not create target dir, keeping archive: $archive"
    FAILED+=("$archive")
    return 0
  }

  case "$fmt" in
  zip)
    unzip -o -q "$archive" -d "$target" </dev/null && extract_ok=1
    ;;
  tar | tar.gz | tar.bz2 | tar.xz)
    tar -xf "$archive" -C "$target" && extract_ok=1
    ;;
  7z)
    7z x -y "$archive" -o"$target" </dev/null &>/dev/null && extract_ok=1
    ;;
  esac

  if [[ $extract_ok -eq 0 ]]; then
    echo "  [FAIL] Extraction failed, keeping archive: $archive"
    if [[ $created -eq 1 ]]; then
      rm -rf "$target"
    fi
    FAILED+=("$archive")
    return 0
  fi

  rm -f "$archive"
  echo "  [DONE] Extracted and removed: $archive"
}

# Build the list of archives to process
if [[ ${#PATHS[@]} -eq 0 ]]; then
  PATHS=(".")
fi

declare -a ARCHIVES=()

collect_from_dir() {
  local dir="$1" found
  while IFS= read -r -d '' found; do
    ARCHIVES+=("$found")
  done < <(find "$dir" -maxdepth "$DEPTH" -type f \( \
    -iname "*.zip" \
    -o -iname "*.tar" \
    -o -iname "*.tar.gz" \
    -o -iname "*.tgz" \
    -o -iname "*.tar.bz2" \
    -o -iname "*.tbz2" \
    -o -iname "*.tar.xz" \
    -o -iname "*.txz" \
    -o -iname "*.7z" \
    \) -print0)
}

for path in "${PATHS[@]}"; do
  if [[ -d "$path" ]]; then
    collect_from_dir "$path"
  elif [[ -f "$path" ]]; then
    # Explicit archive path: no directory scan, processed as given.
    ARCHIVES+=("$path")
  else
    echo "No such file or directory: $path" >&2
    exit 1
  fi
done

if [[ ${#ARCHIVES[@]} -gt 0 ]]; then
  for archive in "${ARCHIVES[@]}"; do
    extract_archive "$archive"
  done
else
  echo "No archives found."
fi

# --- Summary ---
echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "All archives processed successfully."
else
  echo "===== FAILED ARCHIVES (${#FAILED[@]}) ====="
  for f in "${FAILED[@]}"; do
    echo "  - $f"
  done
fi
