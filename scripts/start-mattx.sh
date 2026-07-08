#!/bin/bash
# start-mattx.sh <alma|deb> <1|2>
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

echo "[start] unloading MattX modules on $NODE..."
run_on "$NODE" "sudo systemctl stop mattx-discd 2>/dev/null || true"
run_on "$NODE" "sudo umount /mattxfs 2>/dev/null || true"
run_on "$NODE" "sudo rmmod mattxfs 2>/dev/null || true"
run_on "$NODE" "sudo rmmod mattx    2>/dev/null || true"

echo "[start] loading MattX modules on $NODE..."
run_on "$NODE" "sudo insmod ~/mattx/mattx.ko"
run_on "$NODE" "sudo insmod ~/mattx/mattxfs/mattxfs.ko"

echo "[start] starting mattx-discd on $NODE..."
run_on "$NODE" "sudo systemctl daemon-reload"
run_on "$NODE" "sudo systemctl restart mattx-discd"

echo "[start] disabling balancer on $NODE..."
run_on "$NODE" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"

echo "[start] mounting MattXFS on $NODE..."
run_on "$NODE" "sudo mount -t mattxfs none /mattxfs"

echo "[start] $NODE is running MattX"
