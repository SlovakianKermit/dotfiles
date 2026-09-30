#!/usr/bin/env bash
set -euo pipefail

SRC="$HOME/.config/opencode"
STAGE="$HOME/.config/opencode.v2"
BAK="$HOME/.config/opencode.v1.bak"

echo "OpenCode V1 -> V2 cutover"
echo

if [ -e "$BAK" ]; then
  echo "ERROR: backup already exists at $BAK" >&2
  echo "Refusing to overwrite. Move it aside if you want to re-run." >&2
  exit 1
fi

if [ ! -d "$STAGE" ]; then
  echo "ERROR: staged V2 tree not found at $STAGE" >&2
  exit 1
fi

if pgrep -x opencode >/dev/null 2>&1 || pgrep -f '/usr/bin/opencode' >/dev/null 2>&1; then
  echo "ERROR: an opencode process appears to be running." >&2
  echo "Close every opencode session (including any running agent) before cutover." >&2
  exit 1
fi

echo "This will:"
echo "  1. Install OpenCode V2 (replaces /usr/bin/opencode)"
echo "  2. Move $SRC -> $BAK"
echo "  3. Move $STAGE -> $SRC"
echo
read -r -p "Proceed? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

activated=0
restore() {
  [ "$activated" = "1" ] && return 0
  if [ -d "$BAK" ] && [ ! -e "$SRC" ]; then
    echo "Restoring previous config..." >&2
    mv "$BAK" "$SRC"
  fi
}
trap restore ERR

echo
echo "==> Installing OpenCode V2"
curl -fsSL https://opencode.ai/v2/install | bash

echo
echo "==> Archiving V1 config"
mv "$SRC" "$BAK"

echo "==> Activating V2 config"
mv "$STAGE" "$SRC"
activated=1

echo
echo "Done. V2 config is live."
echo "V1 backup: $BAK"
echo
echo "Start opencode and validate:"
echo "  opencode plugin list"
echo "  check the searxng tool, one-shot reminders, alerts, ~/.opencode-supermemory.log"
echo
echo "To roll back config (binary rollback needs a V1 reinstall):"
echo "  mv $SRC $SRC.failed && mv $BAK $SRC"
