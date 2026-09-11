#!/bin/bash
# test-dsm.sh <alma|deb|ubu>
# Raw (non-EESSI) cluster test for bin/dsmtest.c (1.9-dev): a single process
# that shmget/shmat's a SysV shared-memory segment, then does 100 write+read
# loops against it 1s apart, each loop stamping "MattX DSM Magic! Loop N".
#
# Test 1: baseline -- dsmtest completes cleanly with NO migration, to prove
#         the loop-sequence/shmid checks below are sound before we involve
#         migration at all.
# Test 2: migrate the worker mid-loop (after the shm segment already exists
#         and has been touched a few times) and require POSITIVE proof of
#         correctness across the move, not mere liveness (a stale/corrupted
#         mapping can still look "alive" in ps):
#           - the read-back loop numbers stay CONTINUOUS across the move
#             (no restart to Loop 0, no gap, no repeats) -- the actual
#             evidence that the shared-memory segment's contents survived
#           - the process reaches its own "finished cleanly" line, not just
#             "still running" at some snapshot
#           - shmctl(IPC_RMID) succeeds at the end. This is the sharpest
#             check: a SysV shmid is only valid within the ORIGINATING
#             kernel's IPC namespace -- if MattX's migration recreates the
#             VMA by copying raw page contents into a plain mapping on the
#             target node's kernel (rather than actually preserving/
#             recreating the IPC object identity), the id the worker still
#             holds refers to nothing on the new kernel, and shmdt/shmctl
#             after migration should fail with EINVAL. A failure here would
#             mean the data happened to look right by byte-copy luck while
#             the shared-memory IDENTITY did not actually survive the move.
#
# STATUS: expected to fail on the current 1.9-dev build. Filed upstream as
# brainmatt/mattx#15 and #16 after investigation; tracked there rather than
# re-diagnosed here. See CHANGELOG.md.
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

auto_report_wrap "dsm" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

show_location() {
    local pattern="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    local cmd="ps -eo pid,ppid,user,stat,%cpu,etime,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep"
    echo "  mattx@${node} (${ip})\$ $cmd"
    local out
    out="$(run_on "$node" "$cmd" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        echo "$out" | sed 's/^/      /'
    else
        echo "      (no process matching '$pattern' on $node)"
    fi
}

show_both_nodes() {
    local label="$1" pattern="$2"
    echo ""
    echo "  --- ps snapshot: $label (pattern: '$pattern') ---"
    show_location "$pattern" "$NODE1"
    show_location "$pattern" "$NODE2"
}

show_migration_dmesg() {
    local label="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    echo "  mattx@${node} (${ip}) dmesg — $label:"
    local out
    out="$(run_on "$node" "sudo dmesg | grep -E '\[DRAIN\]|\[EXTRACT\]|\[MIGR\]|\[MIGRATE\]|\[EXPORT\]|\[IMPORT\]|\[RECALL\]|\[REGISTRY\]|\[FUNERAL\]|\[ASSASSIN\]|\[COMM\]' | tail -20" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        echo "$out" | sed 's/^/      /'
    else
        echo "      (no matching dmesg lines on $node)"
    fi
}

do_migrate() {
    local name="$1" pid="$2" from="$3" to="$4" to_id="$5"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo "  Starting migration of $name [PID $pid]"
    echo "    from : $from ($(node_ip "$from"))"
    echo "    to   : $to   ($(node_ip "$to"))  [node ID $to_id]"
    echo "    tool : $(mattx_tool_label)   (run on $from)"
    echo "  ─────────────────────────────────────────────────────"
    mattx_migrate "$from" "$pid" "$to_id"
}

# Extract the sequence of loop numbers from a dsmtest log:
# "[PID N] Loop K - Read from SHM: 'MattX DSM Magic! Loop K'" -> prints K,
# but ONLY when both K's (the loop counter and the one embedded in the
# string) agree -- a mismatch means the read-back data doesn't match what
# this iteration just wrote, i.e. the shared-memory contents are corrupt.
loop_sequence() {
    local log="$1"
    run_on "$NODE1" "grep -oP \"Loop \\K([0-9]+)(?= - Read from SHM: 'MattX DSM Magic! Loop \\1')\" '$log' 2>/dev/null" || true
}

# True if a numeric sequence (one number per line, via stdin) is strictly
# increasing by exactly 1 with no gaps, restarts, or duplicates.
is_continuous() {
    awk 'NR==1{prev=$1; next} { if ($1 != prev+1) { exit 1 } prev=$1 } END{exit (NR<2)}'
}

cleanup() {
    run_on "$NODE1" "pkill -9 -f '[d]smtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[d]smtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== dsmtest (SysV shared memory) tests on ${DISTRO} cluster ==="
echo ""

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "dsm: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
    echo ""
    echo "=============================="
    echo "DSM Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

# ---- Test 1: baseline, no migration ----
echo "=== Test 1: dsmtest completes cleanly with no migration ==="
run_on "$NODE1" "pkill -9 -f '[d]smtest' 2>/dev/null || true"
run_on "$NODE1" "rm -f /tmp/dsmtest_baseline.log"
BASE_MGR=$(run_on "$NODE1" "dsmtest &>/tmp/dsmtest_baseline.log & echo \$!")
echo "  Waiting up to 130s for baseline completion (10s countdown + 100 x 1s loops)..."
BASE_DONE=0
for i in $(seq 1 65); do
    run_on "$NODE1" "grep -q 'dsmtest finished cleanly' /tmp/dsmtest_baseline.log 2>/dev/null" && { BASE_DONE=1; break; }
    sleep 2
done
if [ "$BASE_DONE" -eq 1 ]; then
    SEQ=$(loop_sequence "/tmp/dsmtest_baseline.log")
    COUNT=$(echo "$SEQ" | grep -c . || true)
    if [ "$COUNT" -eq 100 ] && echo "$SEQ" | is_continuous; then
        pass "dsm-1: baseline produced 100 continuous, self-consistent loops with no migration"
    else
        fail "dsm-1: baseline loop sequence not clean (got $COUNT entries) -- test's own assumptions are broken, treat Test 2 results with suspicion"
        echo "  Log tail:"; run_on "$NODE1" "tail -10 /tmp/dsmtest_baseline.log" | sed 's/^/    /'
    fi
    run_on "$NODE1" "grep -q 'shmctl IPC_RMID failed' /tmp/dsmtest_baseline.log" \
        && fail "dsm-1: shmctl(IPC_RMID) failed even with no migration involved" \
        || pass "dsm-1: baseline shared-memory segment removed cleanly"
else
    fail "dsm-1: baseline dsmtest did not complete within 130s"
    run_on "$NODE1" "tail -10 /tmp/dsmtest_baseline.log 2>/dev/null" | sed 's/^/    /' || true
fi
run_on "$NODE1" "kill -9 $BASE_MGR 2>/dev/null || true; pkill -9 -f '[d]smtest' 2>/dev/null || true"

# ---- Test 2: migrate the worker mid-loop ----
echo ""
echo "=== Test 2: migrate dsmtest worker mid-loop, verify DSM survives ==="
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
run_on "$NODE1" "rm -f /tmp/dsmtest.log"
MGR=$(run_on "$NODE1" "dsmtest &>/tmp/dsmtest.log & echo \$!")
# 10s countdown + a handful of read/write loops so the shm segment exists
# and has real history before we move it.
sleep 15
PID=$(run_on "$NODE1" "pgrep -P $MGR" || true)

if [[ "$PID" =~ ^[0-9]+$ ]]; then
    PRE_SEQ=$(loop_sequence "/tmp/dsmtest.log")
    LAST_PRE=$(echo "$PRE_SEQ" | tail -1)
    echo "  Loops completed before migration: $(echo "$PRE_SEQ" | grep -c .) (last: $LAST_PRE)"
    show_both_nodes "baseline, before migration" "dsmtest"

    do_migrate "dsmtest" "$PID" "$NODE1" "$NODE2" "$NODE2_ID"

    echo "  Waiting up to 130s more for completion on whichever node it lands on..."
    DONE=0
    for i in $(seq 1 65); do
        run_on "$NODE1" "grep -q 'dsmtest finished cleanly' /tmp/dsmtest.log 2>/dev/null" && { DONE=1; break; }
        sleep 2
    done

    show_both_nodes "after migration, wait ended" "dsmtest"
    show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE1"
    show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE2"

    if [ "$DONE" -eq 1 ]; then
        FULL_SEQ=$(loop_sequence "/tmp/dsmtest.log")
        FULL_COUNT=$(echo "$FULL_SEQ" | grep -c . || true)
        if [ "$FULL_COUNT" -eq 100 ] && echo "$FULL_SEQ" | is_continuous; then
            pass "dsm-2: all 100 loops continuous and self-consistent across migration"
        else
            fail "dsm-2: loop sequence broken across migration (got $FULL_COUNT entries, expected 100 continuous) -- shared-memory contents did not survive the move intact"
        fi

        if run_on "$NODE1" "grep -q 'shmctl IPC_RMID failed' /tmp/dsmtest.log"; then
            ERRMSG=$(run_on "$NODE1" "grep 'shmctl IPC_RMID failed' /tmp/dsmtest.log")
            fail "dsm-2: shmctl(IPC_RMID) failed after migration ($ERRMSG) -- the SysV shmid no longer resolves, meaning the shared-memory segment's IDENTITY did not survive the move even if byte contents happened to look right"
        else
            pass "dsm-2: shared-memory segment removed cleanly after migration (shmid still valid post-move)"
        fi

        echo "  Full log:"
        run_on "$NODE1" "cat /tmp/dsmtest.log" | sed 's/^/    /'
    else
        fail "dsm-2: dsmtest did not reach completion within the wait budget after migration -- suspected hang (ps liveness alone would not have caught this, see header comment)"
        echo "  Log tail:"
        run_on "$NODE1" "tail -20 /tmp/dsmtest.log 2>/dev/null" | sed 's/^/    /' || true
    fi
else
    fail "dsm-2: dsmtest worker did not start on $NODE1"
fi

run_on "$NODE1" "kill -9 ${MGR:-} 2>/dev/null || true; pkill -9 -f '[d]smtest' 2>/dev/null || true"
run_on "$NODE2" "pkill -9 -f '[d]smtest' 2>/dev/null || true"

if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
    pass "dsm-2: no kernel oops on $NODE1"
else
    fail "dsm-2: kernel oops on $NODE1"
fi
if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
    pass "dsm-2: no kernel oops on $NODE2"
else
    fail "dsm-2: kernel oops on $NODE2"
fi

echo ""
echo "=============================="
echo "DSM Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
