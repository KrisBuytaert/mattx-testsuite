#!/bin/bash
# build-mattx.sh <alma|deb|ubu>
# Rsyncs MattX source to node1, builds it, runs make install.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/sources.conf"

case "$DISTRO" in
    alma) NODE1="almanode1" ;;
    deb)  NODE1="debnode1"  ;;
    ubu)  NODE1="ubunode1"  ;;
esac

init_cluster "$DISTRO"

echo "[build] syncing MattX source to $NODE1..."
run_on "$NODE1" "mkdir -p ~/mattx"
rsync_to "$MATTX_SRC" "$NODE1" "~/mattx/"

echo "[build] building on $NODE1..."
run_on "$NODE1" "cd ~/mattx && make"

echo "[build] installing on $NODE1..."
run_on "$NODE1" "cd ~/mattx && sudo make install"

IFACE=$(run_on "$NODE1" \
    "ip -o addr show | awk '/192\\.168\\.100\\./ {print \$2}' | head -1")
echo "[build] cluster interface on $NODE1: $IFACE"
run_on "$NODE1" "sudo sed -i 's|^INTERFACE=.*|INTERFACE=${IFACE}|' /etc/mattx.conf"

echo "[build] done"
