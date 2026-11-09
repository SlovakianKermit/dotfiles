#!/usr/bin/env bash
# Rebuild and deploy the ctbrec ImageServlet patch to the Proxmox container.
#
# The patch makes the portrait fetch endpoint prefer a model's dedicated
# portrait/live-snapshot URL (Stripchat's previewUrlThumbBig) over the profile
# avatar returned by the search fallback, and converts webp previews to JPEG
# so the desktop client can decode them.
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
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctbrec-servlet.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ssh_run() { ssh "${SSH_OPTS[@]}" "$SERVER" "$@"; }
q() { printf '%q' "$1"; }

echo "== locating installed jar"
jar="$(ssh_run "pct exec ${VMID} -- bash -lc $(q "ls -1 ${REMOTE_DIR}/ctbrec-server-*.jar | head -1")")"
jar="${jar//$'\r'/}"
[[ -n "$jar" ]] || { echo "no ctbrec jar found under $REMOTE_DIR" >&2; exit 1; }
echo "   $jar"

echo "== copying jar for compilation"
ssh_run "pct exec ${VMID} -- cat $(q "$jar")" > "$tmp/ctbrec.jar"

echo "== compiling ImageServlet"
mkdir -p "$tmp/out"
javac -nowarn -cp "$tmp/ctbrec.jar" -d "$tmp/out" "$HERE/ImageServlet.java"

echo "== deploying classes"
remote_classes="${REMOTE_DIR}/patch/ctbrec/recorder/server"
ssh_run "pct exec ${VMID} -- mkdir -p $(q "$remote_classes")"
for class in "ImageServlet.class" "ImageServlet\$1.class"; do
  remote_tmp="/tmp/${class}"
  ssh_run "cat > $(q "$remote_tmp")" < "$tmp/out/ctbrec/recorder/server/$class"
  ssh_run "pct push ${VMID} $(q "$remote_tmp") $(q "${remote_classes}/${class}")"
  ssh_run "pct exec ${VMID} -- chown ctbrec:ctbrec $(q "${remote_classes}/${class}")"
  ssh_run "rm -f $(q "$remote_tmp")"
done

if (( RESTART )); then
  echo "== restarting ctbrec (graceful shutdown)"
  ssh_run "pct exec ${VMID} -- systemctl restart ctbrec"
  # Wait for the web interface to bind; a failed start leaves the JVM running
  # with its recorder threads but no HTTP connector.
  for _ in $(seq 1 30); do
    sleep 2
    if ssh_run "pct exec ${VMID} -- bash -lc 'ss -ltn | grep -q \":8443\"'"; then
      echo "   web interface is listening"
      exit 0
    fi
  done
  echo "   ERROR: web interface did not bind to :8443" >&2
  ssh_run "pct exec ${VMID} -- tail -n 5 ${REMOTE_DIR}/server.log" >&2 || true
  exit 1
else
  echo "== deployed; restart ctbrec to load the class"
fi

echo "done"
