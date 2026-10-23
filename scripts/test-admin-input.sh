#!/bin/bash
# test-admin-input.sh <alma|deb|ubu|fed>
# Regression tests for kernel oopses triggered by writing to /proc/mattx/admin
# ('migrate <pid> <node>'), which any local user can do (the file is mode 0666):
#
#   mattx#27  migrate for a PID that does not exist: admin_write() dereferenced the NULL
#             task_struct (task->group_leader) after pid_task() returned NULL.
#   mattx#37  migrate for a PID whose task already exited (a zombie, its kernel stack is
#             gone): mattx_capture_and_send_state() read task_pt_regs() through the NULL
#             task->stack (page fault at 0x3f48 = THREAD_SIZE - sizeof(pt_regs)).
#
# Needs MattX running with a peer on node1/node2. Each case checks that node1 did not
# reboot (same boot_id), logged no oops, and still answers /proc/mattx/nodes.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    fed)  NODE1="fednode1";  NODE2="fednode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed>" >&2; exit 1 ;;
esac

auto_report_wrap "test-admin-input" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# bounded ssh: a wedged or crashed node must fail the test, not hang it
rto() { timeout 90 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$NODE1")" "$@"; }

wait_for_node() {
    for _ in $(seq 1 60); do rto "test -r /proc/mattx/nodes" >/dev/null 2>&1 && return 0; sleep 3; done
    return 1
}

# node ids are cluster-assigned; take the first connected peer (a non-"(Local)" row) of /proc/mattx/nodes
N2_ID="$(rto "grep -E '^[0-9]+[[:space:]]' /proc/mattx/nodes | grep -v Local | awk '{print \$1}' | head -1" 2>/dev/null || true)"
echo "=== /proc/mattx/admin input handling on $NODE1 (peer node id: ${N2_ID:-unknown}) ==="
if [ -z "$N2_ID" ]; then
    fail "admin-0: no connected peer found in /proc/mattx/nodes on $NODE1, cannot run"
else
    BOOT_ID="$(rto "cat /proc/sys/kernel/random/boot_id")"
    rto "sudo dmesg -C" >/dev/null 2>&1 || true

    check_alive() {   # $1 = case label
        local rc=0 now bad
        now="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "$1: $NODE1 stopped answering ssh (crashed?), waiting for it to come back"
            wait_for_node || echo "  (still down)"
            BOOT_ID="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
            return 1
        fi
        if [ "$now" != "$BOOT_ID" ]; then
            fail "$1: $NODE1 rebooted (boot_id changed) -- kernel crash"
            BOOT_ID="$now"
            return 1
        fi
        bad="$(rto "sudo dmesg | grep -cE 'Oops|BUG:' || true" 2>/dev/null)"
        if [ "$bad" != 0 ]; then
            fail "$1: oops/BUG in dmesg on $NODE1 ($bad lines)"
            rto "sudo dmesg | grep -E -m3 'Oops|BUG:|RIP:'" 2>/dev/null | sed 's/^/    /' || true
            rto "sudo dmesg -C" >/dev/null 2>&1 || true
            return 1
        fi
        pass "$1: $NODE1 survived"
    }

    echo ""
    echo "--- #27: migrate to a PID that does not exist ---"
    rto "echo 'migrate 4194000 $N2_ID' | sudo tee /proc/mattx/admin >/dev/null" || true
    sleep 2
    check_alive "admin-27 (nonexistent pid)" || true

    echo ""
    echo "--- #37: migrate a zombie (exited task, kernel stack already freed) ---"
    ZPID="$(rto "bash -c 'sleep 0 & exec sleep 120' >/dev/null 2>&1 & sleep 1; ps -eo pid,stat,comm | awk '\$2 ~ /^Z/ {print \$1; exit}'" 2>/dev/null || true)"
    if [ -z "$ZPID" ]; then
        fail "admin-37: could not create a zombie process on $NODE1"
    else
        echo "  zombie PID $ZPID"
        rto "echo 'migrate $ZPID $N2_ID' | sudo tee /proc/mattx/admin >/dev/null" || true
        sleep 3
        check_alive "admin-37 (zombie pid $ZPID)" || true
    fi
    rto "pkill -x sleep 2>/dev/null; true" >/dev/null 2>&1 || true
fi

echo ""
echo "Admin-Input Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
