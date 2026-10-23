#!/bin/bash
# start-mattx.sh <alma|deb|ubu|fed> <1|2>
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb|ubu|fed> <1|2>}"
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
    fed-1)  NODE="fednode1"  ;;
    fed-2)  NODE="fednode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed> <1|2|3 (alma only)>" >&2; exit 1 ;;
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
    echo "[start] $NODE did not finish unloading within ${UNLOAD_TIMEOUT}s (wedged umount/sync, upstream #31)"
    # Evidence first: the hung-task detector only reports blocked tasks, not the one
    # that is spinning, so ask the kernel for the stacks of umount/sync and a dump of
    # all running (l) and blocked (w) tasks before the reset destroys the state.
    HANG_OUT="$SCRIPT_DIR/../crash-dumps/$NODE-hang-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "$(dirname "$HANG_OUT")"
    # shellcheck disable=SC2086
    timeout 90 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$NODE")" 'sudo sh -c "
        echo 1 > /proc/sys/kernel/sysrq
        for p in \$(pgrep -x umount) \$(pgrep -x sync) \$(pgrep -x rmmod); do echo \"== pid \$p \$(cat /proc/\$p/comm) state \$(awk \"/State/{print \\\$2}\" /proc/\$p/status)\"; cat /proc/\$p/stack; done
        echo l > /proc/sysrq-trigger; echo w > /proc/sysrq-trigger
        sleep 1; dmesg | tail -400
    "' > "$HANG_OUT" 2>&1 || true
    echo "[start] hang evidence saved to $HANG_OUT"
    # Prefer a kernel panic via sysrq-c: kdump then saves a vmcore of the wedged state
    # (analysable with crash + kernel-debuginfo) and the node reboots itself. Fall back to
    # a hard reset if the node is too wedged to take the sysrq or does not go down.
    echo "[start] crashing $NODE with sysrq-c for a vmcore (kdump), hard-resetting if it does not go down..."
    # shellcheck disable=SC2086
    timeout 20 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$NODE")" 'echo c | sudo tee /proc/sysrq-trigger >/dev/null' >/dev/null 2>&1 || true
    down=0
    for _ in $(seq 1 30); do
        # shellcheck disable=SC2086
        timeout 8 ssh $SSH_OPTS -o ConnectTimeout=4 "$SSH_USER@$(node_ip "$NODE")" true >/dev/null 2>&1 || { down=1; break; }
        sleep 3
    done
    [ "$down" = 1 ] || { echo "[start] $NODE still up, virsh reset"; virsh reset "$NODE"; }
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
