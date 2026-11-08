#!/usr/bin/env bash
#
# qbt-extract.sh - extract archives from finished qBittorrent downloads.
#
# Meant for qBittorrent's "Run external program on torrent finished" hook:
#
#   /home/killian/.local/bin/qbt-extract.sh "%D" "%F" "%N" "%L"
#
# The four arguments are the qBittorrent substitution tokens save path,
# content path, torrent name and category. Only torrents in the category
# given by QBT_EXTRACT_CATEGORY (default: Image) whose save path lies under
# QBT_EXTRACT_PATH (default: /mnt/shared/img) are touched.

set -uo pipefail

PROG="$(basename "$0")"

EXTRACTOR="${QBT_EXTRACT_EXTRACTOR:-$HOME/.local/bin/extract_archives.sh}"
LOG="${QBT_EXTRACT_LOG:-${XDG_STATE_HOME:-$HOME/.local/share}/qbt-extract.log}"
LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}"
CATEGORY_FILTER="${QBT_EXTRACT_CATEGORY:-Image}"
PATH_FILTER="${QBT_EXTRACT_PATH:-/mnt/shared/img}"
SETTLE_TIMEOUT="${QBT_EXTRACT_SETTLE_TIMEOUT:-15}"
LOG_MAX_BYTES="${QBT_EXTRACT_LOG_MAX:-1048576}"
LOCK_TIMEOUT="${QBT_EXTRACT_LOCK_TIMEOUT:-1800}"

usage() {
  cat <<EOF
Usage: $PROG [-n|--dry-run] SAVE_PATH CONTENT_PATH [NAME] [CATEGORY]

Extract archives belonging to a finished torrent, then delete them on
success. Intended to be run by qBittorrent's "Run external program on
torrent finished" option:

  $PROG "%D" "%F" "%N" "%L"

Arguments:
  SAVE_PATH      %D  final save path of the torrent
  CONTENT_PATH   %F  content path (archive file or torrent root folder)
  NAME           %N  torrent name (optional, aids logging)
  CATEGORY       %L  category (optional)

Filters:
  Only torrents whose category is '$CATEGORY_FILTER' and whose save path is
  under '$PATH_FILTER' are processed.

Options:
  -n, --dry-run  Report what would be extracted, change nothing.
  -h, --help     Show this help.

Environment:
  QBT_EXTRACT_CATEGORY       category to process          (Image)
  QBT_EXTRACT_PATH           save path prefix filter     (/mnt/shared/img)
  QBT_EXTRACT_EXTRACTOR      extractor to call           (~/.local/bin/extract_archives.sh)
  QBT_EXTRACT_LOG            log file                    (~/.local/share/qbt-extract.log)
  QBT_EXTRACT_SETTLE_TIMEOUT seconds to wait for content (15)
  QBT_EXTRACT_LOCK_TIMEOUT   seconds to wait for lock    (1800)
  QBT_EXTRACT_LOG_MAX        log size before rotation    (1048576)

Exit status: 0 on success or intentional skip, 1 on error.
EOF
}

log() {
  local size=0
  [[ -d "$(dirname "$LOG")" ]] || mkdir -p "$(dirname "$LOG")" 2>/dev/null || :
  if [[ -f "$LOG" ]]; then
    size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
  fi
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || :
  fi
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >>"$LOG" 2>/dev/null || :
}

die() {
  log "ERROR $*"
  echo "$PROG: $*" >&2
  exit 1
}

# Wait until PATH exists and its size/mtime stop changing.
# Returns 0 as soon as it is stable, 1 if it never shows up.
wait_settled() {
  local path="$1" deadline prev="" cur=""
  deadline=$(( SECONDS + SETTLE_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if [[ -e "$path" ]]; then
      cur="$(stat -c '%s:%Y' "$path" 2>/dev/null || echo unknown)"
      if [[ -n "$prev" && "$cur" == "$prev" && "$cur" != unknown ]]; then
        return 0
      fi
      prev="$cur"
    fi
    sleep 1
  done
  [[ -e "$path" ]]
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n | --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 2 ]] || { usage >&2; exit 2; }

SAVE_PATH="${1%/}"
CONTENT_PATH="${2%/}"
NAME="${3:-}"
CATEGORY="${4:-}"

[[ -x "$EXTRACTOR" ]] || die "extractor not executable: $EXTRACTOR"

# --- Filters -------------------------------------------------------------
if [[ -n "$CATEGORY" && "$CATEGORY" != "$CATEGORY_FILTER" ]]; then
  log "skip category='$CATEGORY' name='$NAME'"
  exit 0
fi

dir_hint="$SAVE_PATH"
if [[ -z "$dir_hint" && -n "$CONTENT_PATH" ]]; then
  dir_hint="$(dirname "$CONTENT_PATH")"
fi

if [[ -n "$PATH_FILTER" && "$dir_hint" != "$PATH_FILTER"/* && "$dir_hint" != "$PATH_FILTER" ]]; then
  log "skip outside='$PATH_FILTER' path='$dir_hint' name='$NAME'"
  exit 0
fi

# --- Serialise concurrent completions ------------------------------------
lock_file="$LOCK_DIR/qbt-extract.lock"
if ! exec 9>"$lock_file" 2>/dev/null; then
  lock_file="/tmp/qbt-extract.lock"
  exec 9>"$lock_file" || die "cannot open lock file: $lock_file"
fi
if ! flock -w "$LOCK_TIMEOUT" 9; then
  die "timed out after ${LOCK_TIMEOUT}s waiting for lock (name='$NAME')"
fi

# --- Resolve content -----------------------------------------------------
# qBittorrent fires this hook only after auto-management has moved the
# finished torrent out of the incomplete directory, so the content path is
# normally final already. The settle wait is a safety net.
content=""
if [[ -n "$CONTENT_PATH" && -e "$CONTENT_PATH" ]]; then
  content="$CONTENT_PATH"
fi

if [[ -z "$content" && -n "$SAVE_PATH" && -n "$NAME" && -e "$SAVE_PATH/$NAME" ]]; then
  content="$SAVE_PATH/$NAME"
fi

if [[ -z "$content" ]]; then
  log "waiting for content name='$NAME' path='$CONTENT_PATH'"
  if wait_settled "$CONTENT_PATH"; then
    content="$CONTENT_PATH"
  elif [[ -n "$SAVE_PATH" && -n "$NAME" ]] && wait_settled "$SAVE_PATH/$NAME"; then
    content="$SAVE_PATH/$NAME"
  fi
fi

if [[ -z "$content" ]]; then
  log "skip missing-content name='$NAME' content='$CONTENT_PATH' save='$SAVE_PATH'"
  exit 0
fi

# --- Collect archives ----------------------------------------------------
declare -a archives=()
if [[ -f "$content" ]]; then
  archives+=("$content")
elif [[ -d "$content" ]]; then
  while IFS= read -r -d '' found; do
    archives+=("$found")
  done < <(find "$content" -maxdepth 1 -type f \( \
    -iname "*.zip" \
    -o -iname "*.7z" \
    -o -iname "*.tar" \
    -o -iname "*.tar.gz" \
    -o -iname "*.tgz" \
    -o -iname "*.tar.bz2" \
    -o -iname "*.tbz2" \
    -o -iname "*.tar.xz" \
    -o -iname "*.txz" \
    \) -print0 2>/dev/null)
fi

if [[ ${#archives[@]} -eq 0 ]]; then
  log "none name='$NAME' content='$content'"
  exit 0
fi

# --- Extract -------------------------------------------------------------
rc=0
for archive in "${archives[@]}"; do
  if (( DRY_RUN )); then
    log "DRY-RUN would-extract '$archive' name='$NAME'"
    echo "$PROG: would extract: $archive"
    continue
  fi

  wait_settled "$archive" || true

  log "start '$archive' name='$NAME' category='${CATEGORY:-none}'"
  if "$EXTRACTOR" "$archive" </dev/null >>"$LOG" 2>&1; then
    if [[ -e "$archive" ]]; then
      log "FAIL kept '$archive' (see log for extractor output) name='$NAME'"
      rc=1
    else
      log "ok extracted '$archive' name='$NAME'"
    fi
  else
    log "FAIL extractor-error '$archive' name='$NAME'"
    rc=1
  fi
done

exit "$rc"
