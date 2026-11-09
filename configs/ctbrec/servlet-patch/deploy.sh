#!/usr/bin/env bash
# Rebuild and deploy the ctbrec ImageServlet patch to the Proxmox container.
#
# The patch makes the portrait fetch endpoint prefer a model's dedicated
# portrait/live-snapshot URL (Stripchat's previewUrlThumbBig) over the profile
# avatar returned by the search fallback.
set -euo pipefail

SERVER="${CTBREC_SERVER:-proxmox}"
VMID="${CTBREC_VMID:-109}"
REMOTE_DIR="${CTBREC_DIR:-/opt/ctbrec}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS=(-o RemoteCommand=none -o RequestTTY=no -o BatchMode=yes)
RESTART=1

for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctbrec-servlet.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "== locating installed jar"
jar="$(ssh "${SSH_OPTS[@]}" "$SERVER" \
  "pct exec ${VMID} -- bash -lc 'ls -1 ${REMOTE_DIR}/ctbrec-server-*.jar | head -1'")"
jar="${jar//$'\r'/}"
[[ -n "$jar" ]] || { echo "no ctbrec jar found under $REMOTE_DIR" >&2; exit 1; }
echo "   $jar"

echo "== copying jar for compilation"
ssh "${SSH_OPTS[@]}" "$SERVER" "pct exec ${VMID} -- cat $(printf '%q' "$jar")" > "$tmp/ctbrec.jar"

echo "== compiling ImageServlet"
mkdir -p "$tmp/out"
javac -nowarn -cp "$tmp/ctbrec.jar" -d "$tmp/out" "$HERE/ImageServlet.java"

echo "== deploying classes"
for class in "ImageServlet.class" "ImageServlet\$1.class"; do
  ssh "${SSH_OPTS[@]}" "$SERVER" "cat > /tmp/$class" < "$tmp/out/ctbrec/recorder/server/$class"
  ssh "${SSH_OPTS[@]}" "$SERVER" \
    "pct exec ${VMID} -- mkdir -p ${REMOTE_DIR}/patch/ctbrec/recorder/server && \
     pct push ${VMID} /tmp/$class ${REMOTE_DIR}/patch/ctbrec/recorder/server/$class && \
     rm -f /tmp/$class"
done
ssh "${SSH_OPTS[@]}" "$SERVER" \
  "pct exec ${VMID} -- chown ctbrec:ctbrec ${REMOTE_DIR}/patch/ctbrec/recorder/server/ImageServlet.class ${REMOTE_DIR}/patch/ctbrec/recorder/server/ImageServlet\$1.class"

if (( RESTART )); then
  echo "== restarting ctbrec (graceful shutdown)"
  ssh "${SSH_OPTS[@]}" "$SERVER" \
    "pct exec ${VMID} -- systemctl restart ctbrec && sleep 10 && pct exec ${VMID} -- systemctl is-active ctbrec"
else
  echo "== deployed; restart ctbrec to load the class"
fi

echo "done"
