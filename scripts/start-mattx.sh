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
# `rmmod mattx` oopses in mattx_hooks_exit -> rethook_free (upstream mattx
# issue #36), so the node crashes and kdump reboots it, taking the ssh session
# with it (exit 255 thanks to ServerAliveInterval in lib.sh). That is the
# expected outcome of unloading a loaded module for now, not a deploy failure:
# wait for the reboot. mattx.service loads the already-installed (new) modules
# at boot, so nothing further needs unloading afterwards.
# sync first: a crash must not lose config writes (see the comment in build-mattx.sh).
# The whole unload runs in the background under a watchdog: a wedged node
# (umount /mattxfs spinning with busy inodes, upstream #31, which then blocks sync
# and everything else on the superblock lock) never returns from ssh, and ServerAlive
# keepalives do not help because the node still answers. Hard-reset it instead.
UNLOAD_TIMEOUT="${UNLOAD_TIMEOUT:-180}"
run_on "$NODE" "sync; sudo systemctl stop mattx 2>/dev/null; sudo umount /mattxfs 2>/dev/null; sudo rmmod mattxfs 2>/dev/null; sudo rmmod mattx 2>/dev/null; true" &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$UNLOAD_TIMEOUT" ]; do sleep 2; waited=$((waited+2)); done
if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "[start] $NODE did not finish unloading within ${UNLOAD_TIMEOUT}s (wedged umount/sync, upstream #31); hard-resetting the VM..."
    virsh reset "$NODE"
    rc=255
else
    set +e; wait "$pid"; rc=$?; set -e
fi
if [ "$rc" -eq 255 ]; then
    echo "[start] $NODE dropped its ssh session while unloading (kernel crash on rmmod #36, or reset after a hang); waiting for it to reboot..."
    wait_for_ssh_down "$NODE"
    wait_for_ssh "$NODE"
elif [ "$rc" -ne 0 ]; then
    echo "[error] unloading MattX on $NODE failed (ssh exit $rc)" >&2
    exit 1
fi

# A crash can leave /etc/mattx.conf truncated (seen on XFS after an oops);
# that silently disables MattXFS, so fail loudly instead.
run_on "$NODE" "[ -s /etc/mattx.conf ]" || { echo "[error] /etc/mattx.conf is missing or empty on $NODE (crash damage?); re-run make install" >&2; exit 1; }

# `start`, not `restart`: restart would stop (rmmod) a service that the reboot
# above already brought up and crash the node a second time. start is a no-op
# if it is active and loads the modules if it is not.
echo "[start] starting mattx on $NODE (loads modules, starts discd, mounts MattXFS)..."
run_on "$NODE" "sudo systemctl daemon-reload"
run_on "$NODE" "sudo systemctl start mattx"

echo "[start] disabling balancer on $NODE..."
run_on "$NODE" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"

echo "[start] $NODE is running MattX"
