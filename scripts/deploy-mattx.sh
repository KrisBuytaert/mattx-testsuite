#!/bin/bash
# deploy-mattx.sh <alma|deb|ubu> [extra_node ...]
# Relays built artifacts from node1 to node2 (and any extra_node args) via
# host, runs make install on each.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu> [extra_node ...]}"
shift
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
esac

init_cluster "$DISTRO"

RELAY="$(mktemp -d /tmp/mattx-deploy-XXXXXX)"
trap 'rm -rf "$RELAY"' EXIT

echo "[deploy] downloading built tree from $NODE1..."
rsync_from "$NODE1" "~/mattx/" "$RELAY/mattx/"

for NODE in "$NODE2" "$@"; do
    echo "[deploy] uploading to $NODE..."
    run_on "$NODE" "mkdir -p ~/mattx"
    rsync_to "$RELAY/mattx/" "$NODE" "~/mattx/"

    echo "[deploy] installing on $NODE..."
    run_on "$NODE" "cd ~/mattx && sudo make install"

    IFACE=$(run_on "$NODE" \
        "ip -o addr show | awk '/192\\.168\\.100\\./ {print \$2}' | head -1")
    echo "[deploy] cluster interface on $NODE: $IFACE"
    run_on "$NODE" "sudo sed -i 's|^INTERFACE=.*|INTERFACE=${IFACE}|' /etc/mattx.conf"
    run_on "$NODE" "sudo sed -i 's|^MATTXFS_ENABLED=.*|MATTXFS_ENABLED=true|' /etc/mattx.conf"
done

echo "[deploy] done"
