#!/bin/bash
# test-threads.sh <alma|deb|ubu>
# Reproduction of mattx#9 ("futex/wait breaks when threads are created on a different node
# than the futex/wait runs"). threadtest forks a worker that sleeps 15 s, spawns N threads
# (clone3/CLONE_VM, ticking every 5 s), ticks for 60 s, then tears the threads down with
# pthread_cancel()+pthread_join() (futex wait).
#
#   1. start `threadtest 4` on node1
#   2. migrate the worker to node2 while it is still in its initial sleep, so the threads
#      are CREATED on node2
#   3. once the 4 threads exist on node2, migrate the worker back home to node1
#   4. let it reach the teardown (futex/join): it must survive, finish the wave and start
#      the next one ("Threads destroyed")
#
# Each step checks the node did not oops and the worker is still alive.
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

auto_report_wrap "threads" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

LOG=/tmp/threadtest-futex.log
THREADS=4
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
echo "=== threadtest $THREADS: threads created on $NODE2, then recalled home to $NODE1 (mattx#9) ==="
if ! [[ "$NODE2_ID" =~ ^[0-9]+$ ]]; then
    fail "threads-0: could not determine $NODE2's node id from /proc/mattx/nodes"
else
    run_on "$NODE1" "pkill -9 -x threadtest 2>/dev/null; rm -f $LOG; true" >/dev/null 2>&1 || true
    run_on "$NODE2" "pkill -9 -x threadtest 2>/dev/null; true" >/dev/null 2>&1 || true
    CUR1=$(dmesg_cursor "$NODE1"); CUR2=$(dmesg_cursor "$NODE2")

    MGR=$(run_on "$NODE1" "threadtest $THREADS &>$LOG & echo \$!")
    sleep 3
    PID=$(run_on "$NODE1" "pgrep -P $MGR" || true)
    if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
        fail "threads-1: could not find the threadtest worker on $NODE1"
    else
        echo "  worker PID $PID (still in its 15 s startup sleep, no threads yet)"
        do_migrate() { mattx_migrate "$1" "$2" "$3"; }
        do_migrate "$NODE1" "$PID" "$NODE2_ID"
        sleep 5
        T2=$(run_on "$NODE2" "ps -eLo comm | grep -cx threadtest" || true)
        [ "${T2:-0}" -ge 1 ] && pass "threads-1: worker migrated to $NODE2 before it spawned its threads" \
                              || fail "threads-1: worker did not show up on $NODE2 after migration"

        echo "  waiting for the $THREADS threads to be created on $NODE2 ..."
        n=0
        for _ in $(seq 1 20); do
            n=$(run_on "$NODE2" "ps -eLo comm | grep -cx threadtest" || true)
            [ "${n:-0}" -ge $((THREADS + 1)) ] && break
            sleep 2
        done
        if [ "${n:-0}" -ge $((THREADS + 1)) ]; then
            pass "threads-2: $THREADS threads created on $NODE2 ($n tasks of threadtest there)"
        else
            fail "threads-2: only ${n:-0} threadtest tasks on $NODE2, expected $((THREADS + 1))"
        fi

        echo "  recalling the worker home to $NODE1 ..."
        mattx_migrate "$NODE1" "$PID" home
        sleep 8
        run_on "$NODE1" "pgrep -x threadtest >/dev/null" \
            && pass "threads-3: worker is back on $NODE1 after the recall" \
            || fail "threads-3: no threadtest process on $NODE1 after the recall"

        echo "  waiting for the teardown wave (pthread_cancel/pthread_join = futex) ..."
        OK=0
        for _ in $(seq 1 45); do
            run_on "$NODE1" "grep -q 'Threads destroyed' $LOG 2>/dev/null" && { OK=1; break; }
            sleep 3
        done
        [ "$OK" = 1 ] && pass "threads-4: teardown completed (pthread_join returned, 'Threads destroyed')" \
                      || fail "threads-4: the teardown never completed (futex wait broke or the worker died)"
        sleep 3
        ALIVE=$(run_on "$NODE1" "pgrep -x threadtest | wc -l" || true)
        [ "${ALIVE:-0}" -ge 1 ] && pass "threads-5: the worker is still alive after the teardown" \
                                || fail "threads-5: the worker crashed (no threadtest process left on $NODE1)"
        echo "  tail of the worker log:"; run_on "$NODE1" "tail -6 $LOG" 2>/dev/null | sed 's/^/    /' || true
    fi
    no_new_oops "$NODE1" "$CUR1" && pass "threads: no kernel oops on $NODE1" || fail "threads: kernel oops/BUG on $NODE1"
    no_new_oops "$NODE2" "$CUR2" && pass "threads: no kernel oops on $NODE2" || fail "threads: kernel oops/BUG on $NODE2"
    run_on "$NODE1" "pkill -9 -x threadtest 2>/dev/null; true" >/dev/null 2>&1 || true
    run_on "$NODE2" "pkill -9 -x threadtest 2>/dev/null; true" >/dev/null 2>&1 || true
fi

echo ""
echo "Threads Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
