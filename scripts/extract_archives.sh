#!/usr/bin/env bash

set -uo pipefail

ROOT="${1:-.}"
declare -a FAILED=()

extract_archive() {
  local archive="$1"
  local dir ext target

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
    unzip -qt "$archive" &>/dev/null && check_ok=1
    ;;
  tar | tar.gz | tar.bz2 | tar.xz)
    tar --test-label -f "$archive" &>/dev/null || true
    tar -tf "$archive" &>/dev/null && check_ok=1
    ;;
  7z)
    7z t "$archive" &>/dev/null && check_ok=1
    ;;
  esac

  if [[ $check_ok -eq 0 ]]; then
    echo "  [FAIL] Integrity check failed, keeping archive: $archive"
    FAILED+=("$archive")
    return 0
  fi

  echo "  [OK] Integrity verified"

  # --- Extract ---
  mkdir -p "$target"
  local extract_ok=0

  case "$fmt" in
  zip)
    unzip -q "$archive" -d "$target" && extract_ok=1
    ;;
  tar | tar.gz | tar.bz2 | tar.xz)
    tar -xf "$archive" -C "$target" && extract_ok=1
    ;;
  7z)
    7z x "$archive" -o"$target" &>/dev/null && extract_ok=1
    ;;
  esac

  if [[ $extract_ok -eq 0 ]]; then
    echo "  [FAIL] Extraction failed, cleaning up and keeping archive: $archive"
    rm -rf "$target"
    FAILED+=("$archive")
    return 0
  fi

  rm -f "$archive"
  echo "  [DONE] Extracted and removed: $archive"
}

# Find all supported archives and process them
while IFS= read -r -d '' archive; do
  extract_archive "$archive"
done < <(find "$ROOT" -type f \( \
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
