#!/bin/bash
# ensure-mattx-running.sh <alma|deb> <1|2>
# Idempotent pre-flight for test targets: if MattX is already loaded, active,
# and sees its peer, do nothing. Otherwise fall back to start-mattx.sh's full
# rmmod/insmod cycle.
#
# Why this exists: running start-mattx.sh's reload on a node that is already
# up AND already connected to its peer is unsafe -- the peer's receiver
# kthread for this node may have already self-exited (socket EOF) from an
# earlier disconnect without being reaped, and reconnecting triggers a
# kthread_stop() NULL-deref crash in mattx.ko (see mt-985.2 / mt-463). A node
# that is freshly booted or genuinely stopped has no such stale peer state, so
# reloading it then is safe -- that path still goes through start-mattx.sh
# unchanged (used as-is by `make start` and `make upgrade-*`).
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb> <1|2>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO-$NODE_NUM" in
    alma-1) NODE="almanode1" ;;
    alma-2) NODE="almanode2" ;;
    deb-1)  NODE="debnode1"  ;;
    deb-2)  NODE="debnode2"  ;;
    *) echo "Usage: $0 <alma|deb> <1|2>" >&2; exit 1 ;;
esac

init_cluster "$DISTRO"
wait_for_ssh "$NODE"

if run_on "$NODE" '
    lsmod | grep -q "^mattx " &&
    lsmod | grep -q "^mattxfs " &&
    sudo systemctl is-active --quiet mattx-discd &&
    mountpoint -q /mattxfs &&
    grep -q "(Local)" /proc/mattx/nodes 2>/dev/null
' 2>/dev/null; then
    echo "[ensure] $NODE already running MattX — skipping reload"
else
    echo "[ensure] $NODE not fully up — running full (re)start"
    "$SCRIPT_DIR/start-mattx.sh" "$DISTRO" "$NODE_NUM"
fi
