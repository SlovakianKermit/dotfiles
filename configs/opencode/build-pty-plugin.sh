#!/usr/bin/env bash
# Rebuild the local OpenCode plugin bundle for opencode-pty.
#
# Why this exists: OpenCode V2 does not support npm subpath exports in plugin
# specifiers, so "opencode-pty/v2" is misread as a GitHub repo and the install
# fails (NpmInstallFailedError: An unknown git error occurred). Instead, the
# package's ./v2 entrypoint is pre-bundled into a single self-contained local
# plugin file that OpenCode loads directly.
#
# After rebuilding, restart the service so OpenCode drops its cached module
# graph for the plugin path:
#   opencode service restart
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
ENTRY="$CONFIG/node_modules/opencode-pty/dist/src/v2/index.js"
OUT="$CONFIG/plugins/opencode-pty-v2.js"

if [ ! -f "$ENTRY" ]; then
  echo "error: $ENTRY not found; run 'bun install' in $CONFIG first" >&2
  exit 1
fi

bun build "$ENTRY" \
  --target=bun \
  --format=esm \
  --packages=bundle \
  --external bun-pty \
  --outfile="$OUT"

echo "Wrote $OUT"
