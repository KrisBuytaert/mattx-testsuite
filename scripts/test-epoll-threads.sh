#!/bin/bash
# test-epoll-threads.sh <alma|deb|ubu|fed>
# Regression test for mattx#14 (a migrated multi-threaded process stops forever, state T).
# epoll_threads (scripts/epoll_threads.c) has one thread blocked in epoll_wait(-1) on an eventfd
# and a second thread that writes the eventfd once a second; each event is logged.
#
# The epoll_wait proxy used to freeze the caller with SIGSTOP, which stops every thread of the
# process, so the writer thread could never make the epoll ready: deadlock. The process must keep
# producing events on the remote node, and again after a recall home.
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

auto_report_wrap "epoll-threads" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

LOG=/tmp/epoll_threads.log
events() { run_on "$NODE1" "grep -c '^event' $LOG 2>/dev/null || true" 2>/dev/null | tail -1; }

# What the cluster looks like when a check fails, so a failure in CI explains itself.
diag() {
    echo "  --- diagnostics ($1) ---"
    echo "  threads on $NODE1:"; run_on "$NODE1" "ps -Lo tid,stat,wchan:22,comm -C epoll_threads --no-headers" 2>/dev/null | sed 's/^/    /' || true
    echo "  threads on $NODE2:"; run_on "$NODE2" "ps -Lo tid,stat,wchan:22,comm -C epoll_threads --no-headers" 2>/dev/null | sed 's/^/    /' || true
    echo "  $NODE1 dmesg (RECALL/IMPORT/HIJACK/WORMHOLE/oops), last 12:"
    run_on "$NODE1" "sudo dmesg | grep -E 'RECALL|IMPORT|HIJACK|WORMHOLE|Oops|BUG:|segfault' | tail -12 | cut -c1-170" 2>/dev/null | sed 's/^/    /' || true
    echo "  $NODE2 dmesg (RECALL/EXTRACT/DRAIN/RPC), last 12:"
    run_on "$NODE2" "sudo dmesg | grep -E 'RECALL|RETURN|EXTRACT|DRAIN|RPC|Sending page' | tail -12 | cut -c1-170" 2>/dev/null | sed 's/^/    /' || true
    echo "  $NODE1 mattx_recv threads:"; run_on "$NODE1" 'for p in $(pgrep -f mattx_recv); do echo "$p $(cat /proc/$p/comm) $(cut -d" " -f3 /proc/$p/stat)"; done' 2>/dev/null | sed 's/^/    /' || true
}

# Did the event counter grow by at least $2 within $3 seconds? (echo the final count)
grows() {
    local from="$1" need="$2" secs="$3" now
    for _ in $(seq 1 "$secs"); do
        sleep 1
        now=$(events); now=${now:-0}
        [ "$now" -ge $((from + need)) ] && { echo "$now"; return 0; }
    done
    echo "${now:-$from}"; return 1
}

echo "=== epoll_wait(-1) in one thread, eventfd writer in another, across migration (mattx#14) ==="
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
if ! [[ "$NODE2_ID" =~ ^[0-9]+$ ]]; then
    fail "epoll-0: could not determine $NODE2's node id"
else
    rsync_to "$SCRIPT_DIR/epoll_threads.c" "$NODE1" "/tmp/epoll_threads.c"
    if ! run_on "$NODE1" "gcc -O1 -o /tmp/epoll_threads /tmp/epoll_threads.c -lpthread" 2>&1; then
        fail "epoll-0: could not compile epoll_threads on $NODE1"
    else
        run_on "$NODE1" "pkill -9 -x epoll_threads; rm -f $LOG; true" >/dev/null 2>&1 || true
        run_on "$NODE2" "pkill -9 -x epoll_threads; true" >/dev/null 2>&1 || true
        CUR1=$(dmesg_cursor "$NODE1"); CUR2=$(dmesg_cursor "$NODE2")
        run_on "$NODE1" "nohup /tmp/epoll_threads 1000 >$LOG 2>&1 &" >/dev/null 2>&1
        PID=""
        for _ in $(seq 1 10); do PID=$(run_on "$NODE1" "pgrep -x epoll_threads | head -1" || true); [ -n "$PID" ] && break; sleep 1; done

        N0=$(events); N0=${N0:-0}
        if N=$(grows "$N0" 3 20); then
            pass "epoll-1: $N events on $NODE1 before the migration"
            mattx_migrate "$NODE1" "$PID" "$NODE2_ID"
            sleep 6
            B=$(events); B=${B:-0}
            if N=$(grows "$B" 10 30); then
                pass "epoll-2: the process keeps producing events on $NODE2 ($B -> $N)"
            else
                fail "epoll-2: no progress on $NODE2 after the migration ($B -> $N events in 30 s): process stuck (state: $(run_on "$NODE2" "ps -o stat= -C epoll_threads | tr '\n' ' '" || true))"
                diag "after the migration"
            fi

            mattx_migrate "$NODE1" "$PID" home
            sleep 8
            B=$(events); B=${B:-0}
            if N=$(grows "$B" 10 30); then
                pass "epoll-3: still producing events after the recall home ($B -> $N)"
            else
                fail "epoll-3: no progress after the recall home ($B -> $N events in 30 s)"
                diag "after the recall"
            fi
        else
            fail "epoll-1: epoll_threads produced only $N events on $NODE1 in 20 s, cannot run the test"
        fi
        run_on "$NODE1" "pkill -9 -x epoll_threads; true" >/dev/null 2>&1 || true
        run_on "$NODE2" "pkill -9 -x epoll_threads; true" >/dev/null 2>&1 || true
        no_new_oops "$NODE1" "$CUR1" && pass "epoll: no kernel oops on $NODE1" || fail "epoll: kernel oops/BUG on $NODE1"
        no_new_oops "$NODE2" "$CUR2" && pass "epoll: no kernel oops on $NODE2" || fail "epoll: kernel oops/BUG on $NODE2"
    fi
fi

echo ""
echo "Epoll-Threads Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
