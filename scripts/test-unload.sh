#!/bin/bash
# test-unload.sh <alma|deb|ubu|fed>
# Regression test for mattx#36: `rmmod mattx` (what `systemctl stop mattx` and every
# redeploy do) used to oops in rethook_free() -> unregister_kretprobe() when one of the
# hooks had failed to register (shmem_page_mkwrite does not exist on 6.12), taking the
# node down and forcing a kdump reboot on every unload.
#
# Per cycle on node1: stop the service, make sure both modules are gone, then check the
# node did not reboot (same boot_id), is still reachable, logged no oops, and that the
# service starts again and loads the modules. Needs MattX running on node1 at the start.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1" ;;
    deb)  NODE1="debnode1"  ;;
    ubu)  NODE1="ubunode1"  ;;
    fed)  NODE1="fednode1"  ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed>" >&2; exit 1 ;;
esac

auto_report_wrap "test-unload" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# bounded ssh: a wedged node must fail the test, not hang it
rto() { timeout 120 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$NODE1")" "$@"; }

CYCLES="${CYCLES:-3}"
echo "=== Unload test (mattx#36): $CYCLES stop/start cycles of mattx on $NODE1 ==="

BOOT_ID="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
if [ -z "$BOOT_ID" ]; then
    fail "unload-0: $NODE1 not reachable, cannot run"
else
    rto "sudo systemctl start mattx; sudo dmesg -C" >/dev/null 2>&1 || true
    for i in $(seq 1 "$CYCLES"); do
        echo ""
        echo "--- cycle $i ---"
        rc=0
        rto "sudo systemctl stop mattx 2>/dev/null; sudo umount /mattxfs 2>/dev/null; sudo rmmod mattxfs 2>/dev/null; sudo rmmod mattx 2>/dev/null; true" || rc=$?
        if [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ]; then
            fail "unload-$i: connection to $NODE1 lost or hung while unloading (rc=$rc) -- the node crashed (mattx#36) or wedged"
            echo "  (waiting for $NODE1 to come back before stopping the test)"
            for _ in $(seq 1 60); do rto true >/dev/null 2>&1 && break; sleep 3; done
            break
        fi
        left="$(rto "lsmod | grep -c '^mattx'" 2>/dev/null || true)"
        [ "$left" = 0 ] && pass "unload-$i: modules unloaded on $NODE1" || fail "unload-$i: $left mattx module(s) still loaded on $NODE1"
        now="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
        [ "$now" = "$BOOT_ID" ] && pass "unload-$i: $NODE1 did not reboot" || fail "unload-$i: $NODE1 rebooted during unload (boot_id changed)"
        bad="$(rto "sudo dmesg | grep -cE 'Oops|BUG:|rethook_free'" 2>/dev/null || true)"
        [ "${bad:-1}" = 0 ] && pass "unload-$i: no oops/BUG in dmesg on $NODE1" || fail "unload-$i: oops/BUG in dmesg on $NODE1 (${bad:-?} lines)"
        rto "sudo systemctl start mattx" >/dev/null 2>&1 || true
        sleep 3
        up="$(rto "lsmod | grep -c '^mattx'; test -r /proc/mattx/nodes && echo readable" 2>/dev/null | tr '\n' ' ' || true)"
        case "$up" in
            "2 readable "*) pass "unload-$i: service restarted, modules loaded on $NODE1" ;;
            *) fail "unload-$i: service did not come back cleanly on $NODE1 ($up)" ;;
        esac
    done
fi

echo ""
echo "Unload Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
