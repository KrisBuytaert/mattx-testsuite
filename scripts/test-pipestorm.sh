#!/bin/bash
# test-pipestorm.sh <alma|deb|ubu|fed>
# Reproducer shapes for the "migrated process stops receiving pipe input" hang seen with colibri (mattx#74):
# bin/pipestorm. A feeder writes one line every 3 s into a pipe; a two-threaded reader on the other end
# (modes rs rp ss sc pc: read/select/poll on the pipe or stdin, with or without a compute thread) is
# migrated to node2. Per mode:
#   - baseline: lines arrive on node1 before the migration
#   - after the migration: the reader is hosted on node2, not stopped (state T), lines keep arriving
#   - no pipestorm watchdog / "no thread made progress" report, no "(fallback)" and no oops on either node
# A failing mode here is the colibri bug reduced to a pipestorm shape; today all five pass.
# The reader's stderr is appended (2>>): with a plain 2> the migrated reader's writes restart at file offset 0
# and overwrite the log (a separate MattX finding), which would corrupt the line counting.
# Tunables: PIPESTORM_MODES (default "rs rp ss sc pc"), PIPESTORM_SETTLE (s after migrate, default 10),
# PIPESTORM_WAIT (s observed after settle, default 25).
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    fed)  NODE1="fednode1";  NODE2="fednode2"  ;;
esac

auto_report_wrap "test-pipestorm" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

MODES="${PIPESTORM_MODES:-rs rp ss sc pc}"
SETTLE="${PIPESTORM_SETTLE:-10}"; WAIT="${PIPESTORM_WAIT:-25}"

cleanup() {
    for n in "$NODE1" "$NODE2"; do
        run_on "$n" "sudo pkill -9 -x pipestorm 2>/dev/null || true" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

echo "=== pipestorm (colibri hang shapes, mattx#74) on ${DISTRO} cluster ==="

if ! run_on "$NODE1" "command -v pipestorm" >/dev/null 2>&1; then
    echo "SKIP: pipestorm not installed on $NODE1 (MattX commit predates it)"
    echo ""
    echo "=============================="
    echo "Pipestorm Results: 0 passed, 0 failed (skipped)"
    echo "=============================="
    exit 0
fi

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "pipestorm: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "Pipestorm Results: $PASS passed, $FAIL failed"; exit 1
fi

run_on "$NODE1" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"

DMESG_CURSOR_1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_2=$(dmesg_cursor "$NODE2")

# number of "RX via" lines the reader has logged so far
rx_count() { run_on "$NODE1" "grep -c 'RX via' /tmp/ps-$1.err 2>/dev/null || true" 2>/dev/null | tail -1; }

for MODE in $MODES; do
    echo ""
    echo "--- mode $MODE ---"
    ERR="/tmp/ps-$MODE.err"
    run_on "$NODE1" "sudo pkill -9 -x pipestorm 2>/dev/null; rm -f $ERR; nohup bash -c 'pipestorm -f 3 | pipestorm -m $MODE -w 10 2>> $ERR' >/dev/null 2>&1 </dev/null &" || true
    sleep 14
    BASE=$(rx_count "$MODE"); BASE=${BASE:-0}
    # -x with the full command line: a plain -f would match the (migration-excluded) bash -c wrapper
    PID=$(run_on "$NODE1" "pgrep -fx 'pipestorm -m $MODE -w 10' | head -1" 2>/dev/null || true)
    if [ -z "$PID" ]; then fail "pipestorm $MODE: reader did not start on $NODE1"; continue; fi
    if [ "${BASE:-0}" -ge 2 ]; then pass "pipestorm $MODE: baseline on $NODE1, $BASE lines received"
    else fail "pipestorm $MODE: baseline broken, only ${BASE:-0} lines on $NODE1 before the migration"; continue; fi

    do_migrate "pipestorm -m $MODE" "$PID" "$NODE1" "$NODE2" "$NODE2_ID" || true
    sleep "$SETTLE"
    A=$(rx_count "$MODE"); A=${A:-0}
    sleep "$WAIT"
    B=$(rx_count "$MODE"); B=${B:-0}
    GOT=$((B - A)); NEED=$((WAIT / 3 / 2))

    HOSTED=$(run_on "$NODE2" "ps -eLo stat=,comm= | grep -c '^[A-Za-z]* *pipestorm\$' || true" 2>/dev/null | tail -1)
    if [ "${HOSTED:-0}" -gt 0 ]; then pass "pipestorm $MODE: reader hosted on $NODE2 ($HOSTED threads)"
    else fail "pipestorm $MODE: migration did not happen, no pipestorm threads on $NODE2"; fi

    STOPPED=$(run_on "$NODE2" "ps -eLo stat=,comm= | awk '\$2==\"pipestorm\" && \$1 ~ /^T/' | wc -l" 2>/dev/null | tail -1)
    if [ "${STOPPED:-0}" -gt 0 ]; then fail "pipestorm $MODE: $STOPPED thread(s) group-stopped (state T) on $NODE2"
    else pass "pipestorm $MODE: no thread stopped on $NODE2"; fi

    if [ "$GOT" -ge "$NEED" ]; then pass "pipestorm $MODE: $GOT lines received in ${WAIT}s after the migration"
    else
        fail "pipestorm $MODE: only $GOT lines in ${WAIT}s after the migration (need >= $NEED): the reader stopped receiving"
        run_on "$NODE1" "tail -8 $ERR | cut -c1-170" 2>/dev/null | sed 's/^/    /' || true
        run_on "$NODE2" 'P=$(pgrep -x pipestorm | head -1); for t in /proc/$P/task/*; do echo "$(basename $t) state=$(sudo awk "{print \$3}" $t/stat) wchan=$(sudo cat $t/wchan) syscall=$(sudo cat $t/syscall | cut -c1-40)"; done' 2>/dev/null | sed 's/^/    node2 /' || true
    fi

    if run_on "$NODE1" "grep -q -E 'WATCHDOG|no thread made progress' $ERR" 2>/dev/null; then
        fail "pipestorm $MODE: the reader's own watchdog fired"
        run_on "$NODE1" "grep -E 'WATCHDOG|no thread made progress' $ERR | head -5 | cut -c1-170" | sed 's/^/    /' || true
    else pass "pipestorm $MODE: no watchdog report"; fi

    for n in "$NODE1" "$NODE2"; do
        cur=$DMESG_CURSOR_1; [ "$n" = "$NODE2" ] && cur=$DMESG_CURSOR_2
        FB=$(run_on "$n" "sudo dmesg" 2>/dev/null | awk -v c="$cur" 'match($0,/^\[[ 0-9.]+\]/){ts=substr($0,RSTART+1,RLENGTH-2); gsub(/ /,"",ts); if((ts+0)>(c+0)) print}' | grep -c '(fallback)' || true)
        if [ "${FB:-0}" -gt 0 ]; then fail "pipestorm $MODE: $FB '(fallback)' line(s) in dmesg on $n"; fi
    done

    cleanup
    sleep 3
done

check_no_oops "$NODE1" "$DMESG_CURSOR_1" && pass "pipestorm: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_2" && pass "pipestorm: no oops on $NODE2"

echo ""
echo "=============================="
echo "Pipestorm Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
