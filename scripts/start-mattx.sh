#!/bin/bash
# start-mattx.sh <alma|deb|ubu> <1|2>
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb|ubu> <1|2>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO-$NODE_NUM" in
    alma-1) NODE="almanode1" ;;
    alma-2) NODE="almanode2" ;;
    alma-3) NODE="almanode3" ;;
    deb-1)  NODE="debnode1"  ;;
    deb-2)  NODE="debnode2"  ;;
    ubu-1)  NODE="ubunode1"  ;;
    ubu-2)  NODE="ubunode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu> <1|2|3 (alma only)>" >&2; exit 1 ;;
esac

init_cluster "$DISTRO"

wait_for_ssh "$NODE"

echo "[start] unloading MattX modules on $NODE..."
run_on "$NODE" "sudo systemctl stop mattx 2>/dev/null || true"
run_on "$NODE" "sudo umount /mattxfs 2>/dev/null || true"
run_on "$NODE" "sudo rmmod mattxfs 2>/dev/null || true"
run_on "$NODE" "sudo rmmod mattx    2>/dev/null || true"

# The mattx.service unit (init/mattx, installed by `make install`) now loads
# both kernel modules, starts mattx-discd, and mounts MattXFS itself in one
# unified start() — insmod/mount by hand here would just be redundant with
# (and could race) what the service already does.
echo "[start] starting mattx on $NODE (loads modules, starts discd, mounts MattXFS)..."
run_on "$NODE" "sudo systemctl daemon-reload"
run_on "$NODE" "sudo systemctl restart mattx"

echo "[start] disabling balancer on $NODE..."
run_on "$NODE" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"

echo "[start] $NODE is running MattX"
