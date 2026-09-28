#!/bin/bash
# test-dsm-mesi3.sh alma
# Targets a specific gap Matt (upstream) flagged directly: MESI (DSM_MODE=2)
# "works fine for 2 nodes but not for 3 and more" -- a new design bug he's
# mid-way through re-architecting around. Every existing DSM test in this
# suite (test-dsm.sh) only ever exercises a 2-node topology, so it cannot
# see this class of bug at all: it can only ever contain "write, then read
# back on the SAME two participants" cases. This test specifically checks
# whether a write made by one non-home worker propagates correctly to a
# THIRD, independent node -- not just back to the two nodes that already
# know about each other -- using Matt's own new debugging tool
# (dsmstresstest-debug, bin/dsmstresstest-debug.c) for precise,
# on-demand read/write triggers instead of a fixed timing loop.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma> (3-node chain support is alma-only)}"
[ "$DISTRO" = "alma" ] || { echo "ERROR: only 'alma' has 3-node (almanode3) support" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

NODE1="almanode1"; NODE2="almanode2"; NODE3="almanode3"

auto_report_wrap "test-dsm-mesi3" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== Test: MESI (DSM_MODE=2) consistency across 3 independent nodes ==="

for n in "$NODE1" "$NODE2" "$NODE3"; do
    run_on "$n" "echo 'dsm_mode 2' | sudo tee /proc/mattx/admin > /dev/null"
    run_on "$n" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
done
echo "  DSM_MODE=2 (MESI) confirmed set, balancer disabled, on all 3 nodes."

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}')
NODE3_ID=$(run_on "$NODE3" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}')

DMESG_CURSOR_1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_2=$(dmesg_cursor "$NODE2")
DMESG_CURSOR_3=$(dmesg_cursor "$NODE3")

LOG="/tmp/dsm3.log"
run_on "$NODE1" "rm -f $LOG /tmp/*.cmd"

echo "  Starting dsmstresstest-debug with 3 workers on $NODE1 (192.168.100.11)..."
run_on "$NODE1" "nohup dsmstresstest-debug 3 &>$LOG & echo \$!" > /dev/null

# Workers are staggered by ~1s each (dsmstresstest-debug.c: sleep(1) between
# forks) -- poll for all 3 "Spawned worker" lines rather than a fixed sleep.
WORKER_PIDS=""
for _ in $(seq 1 15); do
    WORKER_PIDS=$(run_on "$NODE1" "grep -oP 'Spawned worker \d+/3 \(PID \K[0-9]+' $LOG" 2>/dev/null || true)
    [ "$(echo "$WORKER_PIDS" | grep -c .)" -eq 3 ] && break
    sleep 1
done
W1=$(echo "$WORKER_PIDS" | sed -n '1p')
W2=$(echo "$WORKER_PIDS" | sed -n '2p')
W3=$(echo "$WORKER_PIDS" | sed -n '3p')

if [ -z "${W1:-}" ] || [ -z "${W2:-}" ] || [ -z "${W3:-}" ]; then
    fail "mesi3: dsmstresstest-debug did not report 3 worker PIDs within 15s"
    run_on "$NODE1" "cat $LOG" | sed 's/^/    /'
    run_on "$NODE1" "pkill -9 -f dsmstresstest-debug 2>/dev/null; true"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
echo "  Workers: W1(home)=$W1  W2=$W2  W3=$W3"

# --- Baseline sanity check: everyone still on node1, plain write/read works ---
run_on "$NODE1" "echo 'write baseline-check' > /tmp/${W1}.cmd"
sleep 2
BASELINE=$(run_on "$NODE1" "grep -c \"Executed WRITE: 'baseline-check'\" $LOG" || true)
if [ "${BASELINE:-0}" -gt 0 ]; then
    pass "mesi3: baseline write/read via dsmstresstest-debug works pre-migration"
else
    fail "mesi3: baseline write did not register -- tool itself may be broken, aborting"
    run_on "$NODE1" "cat $LOG" | sed 's/^/    /'
    run_on "$NODE1" "pkill -9 -f dsmstresstest-debug 2>/dev/null; true"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Spread the 3 workers across 3 independent nodes ---
echo ""
echo "  Migrating W2 ($W2) -> $NODE2 [$NODE2_ID], W3 ($W3) -> $NODE3 [$NODE3_ID]..."
mattx_migrate "$NODE1" "$W2" "$NODE2_ID"
sleep 6
mattx_migrate "$NODE1" "$W3" "$NODE3_ID"
sleep 6

if is_actually_running "dsmstresstest-debug" "$NODE2"; then
    pass "mesi3: W2 actually running as Surrogate on $NODE2"
else
    fail "mesi3: W2 not actually running on $NODE2 after migration"
fi
if is_actually_running "dsmstresstest-debug" "$NODE3"; then
    pass "mesi3: W3 actually running as Surrogate on $NODE3"
else
    fail "mesi3: W3 not actually running on $NODE3 after migration"
fi

# Fetch a fresh view of the log (line count) so each round only inspects
# NEW lines -- with 3 chatty pollers this avoids re-matching a stale line
# from an earlier round.
log_since() {
    local from_line="$1"
    run_on "$NODE1" "tail -n +$((from_line + 1)) $LOG"
}
log_linecount() { run_on "$NODE1" "wc -l < $LOG"; }

# Trigger a command on a worker by writing its home-node-relative .cmd file
# (DFSA/wormhole redirects the migrated Surrogate's repeated fopen() of
# this path back to $NODE1 regardless of which node it's actually
# executing on -- same mechanism every other migrated-process test in this
# suite relies on for file I/O across a migration).
trigger() { # trigger <pid> <cmd...>
    local pid="$1"; shift
    run_on "$NODE1" "echo '$*' > /tmp/${pid}.cmd"
}

# round <label> <writer_pid> <writer_node_label> <msg> <reader_pid_1> <reader_node_label_1> <reader_pid_2> <reader_node_label_2>
round() {
    local label="$1" writer="$2" writer_node="$3" msg="$4"
    local r1="$5" r1_node="$6" r2="$7" r2_node="$8"
    local start; start=$(log_linecount)
    trigger "$writer" "write $msg"
    sleep 2
    trigger "$r1" "read"
    trigger "$r2" "read"
    sleep 2
    local new; new=$(log_since "$start")
    if echo "$new" | grep -q "Executed WRITE: '$msg'"; then
        pass "mesi3: $label -- write on $writer_node registered"
    else
        fail "mesi3: $label -- write on $writer_node ($writer) never registered in log"
    fi
    if echo "$new" | grep -q "Executed READ: '$msg'" && \
       echo "$new" | grep "Executed READ:" | grep -q "PID $r1 |"; then
        pass "mesi3: $label -- $r1_node saw the updated value ('$msg')"
    else
        fail "mesi3: $label -- $r1_node did NOT see '$msg' (stale/incoherent read -- matches Matt's 3+-node MESI gap)"
    fi
    if echo "$new" | grep -q "Executed READ: '$msg'" && \
       echo "$new" | grep "Executed READ:" | grep -q "PID $r2 |"; then
        pass "mesi3: $label -- $r2_node saw the updated value ('$msg')"
    else
        fail "mesi3: $label -- $r2_node did NOT see '$msg' (stale/incoherent read -- matches Matt's 3+-node MESI gap)"
    fi
}

echo ""
echo "  Round 1: write from HOME ($NODE1), read from both remotes..."
round "round1 (home writes)" "$W1" "$NODE1" "r1-from-home" "$W2" "$NODE2" "$W3" "$NODE3"

echo ""
echo "  Round 2: write from $NODE2, read from home AND the OTHER remote ($NODE3) --"
echo "  this is the specific case Matt flagged as newly-broken for 3+ nodes."
round "round2 (node2 writes, node3 must see it)" "$W2" "$NODE2" "r2-from-node2" "$W1" "$NODE1" "$W3" "$NODE3"

echo ""
echo "  Round 3: write from $NODE3, read from home AND the OTHER remote ($NODE2)..."
round "round3 (node3 writes, node2 must see it)" "$W3" "$NODE3" "r3-from-node3" "$W1" "$NODE1" "$W2" "$NODE2"

echo ""
run_on "$NODE1" "echo exit > /tmp/${W1}.cmd; true" || true
trigger "$W2" "exit" || true
trigger "$W3" "exit" || true
sleep 2
run_on "$NODE1" "pkill -9 -f dsmstresstest-debug 2>/dev/null; true" || true
run_on "$NODE2" "pkill -9 -f dsmstresstest-debug 2>/dev/null; true" || true
run_on "$NODE3" "pkill -9 -f dsmstresstest-debug 2>/dev/null; true" || true

check_no_oops "$NODE1" "$DMESG_CURSOR_1" && pass "mesi3: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_2" && pass "mesi3: no oops on $NODE2"
check_no_oops "$NODE3" "$DMESG_CURSOR_3" && pass "mesi3: no oops on $NODE3"

echo ""
echo "=============================="
echo "MESI-3Node Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
