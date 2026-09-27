#!/bin/bash
# test-stale-link.sh <alma|deb|ubu>
# Isolated, MPI/EESSI-free reproduction of a bug found via the OSU
# shared-memory suite: /proc/mattx/nodes can keep reporting a peer as
# connected long after its actual TCP socket is gone (cluster_map holds a
# stale link with no liveness check). A migration attempted against that
# stale link fails to send its blueprint, and the source process — a
# single, un-threaded process here, ruling out any gang/MPI angle — is left
# frozen (STAT=T) with NO recovery path: mattx_migr.c discards
# mattx_comm_send()'s return value outright, so nothing ever un-freezes it.
#
# Bouncing node2's mattx service (killing its socket to node1) is our best
# working hypothesis for recreating that "reported connected, actually
# dead" state on demand, rather than waiting for it to occur naturally.
#
# Split out of run-tests.sh (formerly Test 5 there) because this test's own
# mechanism — restarting a node's mattx service — is the exact trigger for
# mattx#16/#17 (kernel crash on module reload, sometimes followed by a
# permanent hang instead of a clean auto-reboot). Bundling it into the
# default suite meant a single upstream kernel bug could take down Tests
# 1-4's results along with it, even though those tests have nothing to do
# with the stale-link scenario. Run this separately, and expect it to
# sometimes cost you the whole cluster (see mattx#16/#17) — that's a
# property of the trigger, not of this test.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu>" >&2; exit 1 ;;
esac

auto_report_wrap "test-stale-link" "$@"

init_cluster "$DISTRO"

repro_test5() {
    cat <<'REPRO'

  ── Test 5 repro: migration against a stale cluster link ────────────────
    # 1. Bounce node2's mattx service (kills its socket to node1 outright)
    $SSH${N2} "sudo systemctl restart mattx"
    sleep 3
    $SSH${N2} 'cat /proc/mattx/nodes'   # wait for it to come back up

    # 2. Immediately try a migration FROM node1 TO node2 -- node1 may still
    #    be holding the old, now-dead socket in cluster_map
    $SSH${N1} 'migtest &>/tmp/migtest5.log & sleep 2; pgrep migtest | tail -1'
    export PID=<child-pid-from-above>
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 5

    # 3. Check dmesg on node1 for the failure signature
    $SSH${N1} 'sudo dmesg | grep "Network send failed"'

    # 4. THE ACTUAL BUG: if that line is present, PID never resumes on its
    #    own -- no further dmesg output, ps shows it permanently STAT=T.
    #    Confirmed only killable with SIGKILL, never self-recovers:
    $SSH${N1} 'ps -eo pid,stat,cmd | grep migtest'   # expect (currently): stuck at STAT=T forever

    # Cleanup + oops check
    $SSH${N1} "pkill -9 migtest 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

_FAIL_T5=$FAIL
echo "=== Test 5: migration against a stale cluster link (peer service bounce) ==="

# This restart is the exact trigger for mattx#16/#17: the node can crash and
# either self-recover via reboot (SSH session dies mid-command, ssh exits
# non-zero) or hang indefinitely. Under `set -e`, an unguarded failure here
# would kill this whole script before the recovery-wait loop below ever got
# a chance to run -- exactly what happened in practice (script aborted on a
# raw "Connection reset by peer" with no [FAIL]/Results line at all). Guard
# it, and let the wait loop below do its job either way.
RESTART_RC=0
run_on "$NODE2" "sudo systemctl restart mattx" || RESTART_RC=$?
if [ "$RESTART_RC" -ne 0 ]; then
    echo "  ⚠ restart command on $NODE2 did not return cleanly (rc=$RESTART_RC) -- possible crash mid-restart (mattx#16/#17)"
fi

# A crashed node needs a full VM reboot to recover, not just a service
# bounce -- give this a realistic ~2 minute ceiling (was 30s, which only
# ever covered "service is just slow," never "node is rebooting"). Still
# bounded: a genuinely-hung node (mattx#17's non-recovering case) gives up
# cleanly here instead of hanging the script forever.
i=0
until run_on "$NODE2" "cat /proc/mattx/nodes" >/dev/null 2>&1; do
    sleep 3; i=$((i+1))
    [ "$i" -lt 40 ] || break
done
if run_on "$NODE2" "cat /proc/mattx/nodes" >/dev/null 2>&1; then
    NODE2_UP=1
else
    NODE2_UP=0
    fail "test5: $NODE2 did not come back within ~2 minutes after restart (possible mattx#16/#17 crash/hang)"
fi

if [ "$NODE2_UP" -eq 0 ]; then
    # Nothing past this point can assume $NODE2 is reachable -- skip
    # straight to whatever checks are still safe (node1's own oops check)
    # and report, rather than risk the same unguarded-abort problem on a
    # later command.
    check_no_oops "$NODE1" "$(dmesg_cursor "$NODE1")" && pass "test5: no oops on $NODE1"
    echo ""
    echo "=============================="
    echo "Stale-Link Results: $PASS passed, $FAIL failed"
    echo "=============================="
    [ "$FAIL" -eq 0 ]
    exit
fi

run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}')

DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")

MGR5=$(run_on "$NODE1" "migtest &>/tmp/migtest5.log & echo \$!")
sleep 2
PID5=$(run_on "$NODE1" "pgrep -P $MGR5 migtest 2>/dev/null | tail -1" || true)
PID5="${PID5:-$MGR5}"

show_location "migtest" "$NODE1"
do_migrate "migtest" "$PID5" "$NODE1" "$NODE2" "$NODE2_ID"
sleep 5

# See the comment on no_new_oops() in lib.sh for why this can't use a plain
# `$1`-based awk split: dmesg right-pads the timestamp for column alignment,
# which silently breaks that approach for any uptime under ~2.7 hours.
SEND_FAILED=$(run_on "$NODE1" "sudo dmesg | awk -v c=$DMESG_CURSOR_NODE1 '
    match(\$0, /^\[[ 0-9.]+\]/) {
        ts = substr(\$0, RSTART + 1, RLENGTH - 2); gsub(/ /, \"\", ts)
        if ((ts + 0) > (c + 0)) print
    }' | grep -c 'Network send failed'" || echo 0)

if [ "$SEND_FAILED" -gt 0 ]; then
    echo "  ► reproduced: blueprint send failed against the stale link (see dmesg below)"
    run_on "$NODE1" "sudo dmesg | tail -10" | sed 's/^/    /'

    # The actual regression contract: a failed send must not leave the
    # source process frozen forever. Poll a while before declaring it
    # stuck -- currently expected to fail, since nothing in mattx_migr.c
    # ever un-freezes it on a failed send.
    RECOVERED=0
    for _ in $(seq 1 6); do
        sleep 5
        STAT5=$(process_stat "migtest" "$NODE1")
        if [ -n "$STAT5" ] && [[ "$STAT5" != T* ]]; then RECOVERED=1; break; fi
    done
    if [ "$RECOVERED" -eq 1 ]; then
        pass "test5: source process recovered/resumed on $NODE1 after a failed migration send"
    else
        fail "test5: source process left permanently frozen (STAT=T) on $NODE1 after a failed migration send -- no recovery path in mattx_migr.c"
    fi
else
    echo "  ► stale-link condition did not reproduce this run (send succeeded) -- falling back to a normal migration assertion"
    if is_actually_running "migtest" "$NODE2"; then
        show_location "migtest" "$NODE2"
        pass "test5: migtest migrated normally to $NODE2 (stale-link condition not present this run)"
    else
        fail "test5: migtest not actually running on $NODE2 after migration"
    fi
fi

run_on "$NODE1" "kill -9 $PID5 2>/dev/null || true; pkill -9 migtest 2>/dev/null || true"
run_on "$NODE2" "pkill -9 migtest 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test5: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test5: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T5" ] && { repro_setup; repro_test5; }

echo ""
echo "=============================="
echo "Stale-Link Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
