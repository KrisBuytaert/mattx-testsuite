#!/bin/bash
# deploy-mattx.sh <alma|deb>
# Relays built artifacts from node1 to node2 via host, runs make install.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
esac

init_cluster "$DISTRO"

RELAY="$(mktemp -d /tmp/mattx-deploy-XXXXXX)"
trap 'rm -rf "$RELAY"' EXIT

echo "[deploy] downloading built tree from $NODE1..."
rsync_from "$NODE1" "~/mattx/" "$RELAY/mattx/"

echo "[deploy] uploading to $NODE2..."
run_on "$NODE2" "mkdir -p ~/mattx"
rsync_to "$RELAY/mattx/" "$NODE2" "~/mattx/"

echo "[deploy] installing on $NODE2..."
run_on "$NODE2" "cd ~/mattx && sudo make install"

IFACE=$(run_on "$NODE2" \
    "ip -o addr show | awk '/192\\.168\\.100\\./ {print \$2}' | head -1")
echo "[deploy] cluster interface on $NODE2: $IFACE"
run_on "$NODE2" "sudo sed -i 's|^INTERFACE=.*|INTERFACE=${IFACE}|' /etc/mattx.conf"

echo "[deploy] done"
