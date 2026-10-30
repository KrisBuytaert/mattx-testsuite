#!/bin/bash
# test-unload-active.sh <alma|deb|ubu|fed>
# Exploration: what happens when MattX is unloaded (`systemctl stop mattx` / rmmod -- what removing a
# node from the cluster boils down to) while the cluster is busy? test-unload.sh only unloads an idle
# node; this puts migrated, active guests on it first: a multithreaded epoll_wait process, a TCP echo
# server (poll) under client traffic, and a process that hammers open/read/close (wormhole file RPCs).
#
# Scenarios (every one ends with MattX restarted on both nodes and the cluster re-formed):
#   S1  stop MattX on node2 while the three guests run there          (removing a node that hosts guests)
#   S2  stop MattX on node1 (their home) while the guests run on node2 (removing a home node)
#   S3  stop MattX on node2 right after issuing the migrations to it   (unload during active migration;
#                                                                      CYCLES rounds, random 0-400 ms offset)
#
# What is checked: the unloaded node did not reboot / hang, the modules are gone, no oops/BUG/hung
# task in dmesg on either node, the peer node is fine, no kdump was written, and the cluster comes
# back. What happens to the guests is not judged (there is no spec yet), only printed as "fate:" lines.
#
# CYCLES (default 4) = rounds of S3; ONLY="S1 S2 S3" picks scenarios, S2_CYCLES repeats S2. Needs MattX running on both nodes. Alma needs no third node.
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
CYCLES="${CYCLES:-4}"

auto_report_wrap "test-unload-active" "$@"
init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# bounded ssh: a wedged node must fail the test, not hang it
rto() { local n="$1"; shift; timeout 120 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$n")" "$@"; }

boot_id()   { rto "$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || echo unreachable; }
# counts via a trailing "; true": grep -c exits 1 on zero matches, which must not read as a failure
crash_cnt() { rto "$1" "sudo ls /var/crash 2>/dev/null | grep -c . ; true" 2>/dev/null | head -1; }
bad_lines() { local r; r="$(rto "$1" "sudo dmesg | grep -cE 'Oops|BUG:|kernel NULL|blocked for more than|WARNING: CPU|general protection'; true" 2>/dev/null | head -1)"; echo "${r:-?}"; }
node_id()   { rto "$1" "awk '/\\(Local\\)/{print \$1}' /proc/mattx/nodes" 2>/dev/null; }

WORKLOADS="epoll_threads servertestpoll ioloop"

build_workloads() {
    rsync_to "$SCRIPT_DIR/epoll_threads.c" "$NODE1" "/tmp/epoll_threads.c"
    rto "$NODE1" "gcc -O1 -o /tmp/epoll_threads /tmp/epoll_threads.c -lpthread
cat > /tmp/ioloop.c <<'EOF'
#include <fcntl.h>
#include <unistd.h>
int main(){char b[64];for(;;){int f=open(\"/etc/hostname\",O_RDONLY);if(f>=0){read(f,b,sizeof b);close(f);}}}
EOF
gcc -O1 -o /tmp/ioloop /tmp/ioloop.c" >/dev/null 2>&1
}

kill_workloads() {
    for n in "$NODE1" "$NODE2"; do
        rto "$n" "pkill -9 -f 'epoll_threads|servertestpoll|ioloop|nc -w1' 2>/dev/null; pkill -9 -f 'ul-client' 2>/dev/null; true" >/dev/null 2>&1 || true
    done
}

# MattX up and talking on both nodes (restart through start-mattx.sh, which also turns the balancer off)
ensure_cluster() {
    local up=0
    for _ in 1 2 3; do
        for i in 1 2; do "$SCRIPT_DIR/start-mattx.sh" "$DISTRO" "$i" >/dev/null 2>&1 || true; done
        sleep 4
        if [ "$(rto "$NODE1" "grep -cE '^[0-9]+[[:space:]]' /proc/mattx/nodes; true" 2>/dev/null | head -1)" -ge 2 ]; then up=1; break; fi
    done
    [ "$up" = 1 ]
}

# wait for a node that crashed/rebooted (kdump) to be reachable again
wait_back() {
    for _ in $(seq 1 60); do rto "$1" true >/dev/null 2>&1 && return 0; sleep 3; done
    return 1
}

start_guests() {   # starts the three workloads on node1 and returns once they run
    rto "$NODE1" "cd /tmp && rm -f ul-*.log
        setsid nohup /tmp/epoll_threads > ul-epoll.log 2>&1 < /dev/null &
        setsid nohup \$HOME/mattx/bin/servertestpoll > ul-srv.log 2>&1 < /dev/null &
        setsid nohup /tmp/ioloop > /dev/null 2>&1 < /dev/null &
        # traffic against the echo server: a client loop that is not itself a migration candidate
        setsid nohup bash -c 'exec -a ul-client bash -c \"while :; do echo ping | nc -w1 127.0.0.1 8080 >/dev/null 2>&1; done\"' > /dev/null 2>&1 < /dev/null &
        sleep 1; true" >/dev/null 2>&1
}

migrate_guests() {   # $1 = target node id; returns immediately after issuing the three migrations
    local id="$1" pid p
    for p in epoll_threads servertestpoll ioloop; do
        pid="$(rto "$NODE1" "pgrep -x $p | tail -1" 2>/dev/null || true)"
        [ -n "$pid" ] && mattx_migrate "$NODE1" "$pid" "$id" >/dev/null 2>&1 || true
    done
}

fate() {   # informational: where do the guests live now?
    local n w
    for n in "$NODE1" "$NODE2"; do
        w="$(rto "$n" "ps -eo pid,stat,comm --no-headers | grep -E 'epoll_threads|servertestpoll|ioloop' | tr '\n' ';'" 2>/dev/null || echo unreachable)"
        echo "  fate: on $n: ${w:-none}"
    done
}

# the common verdicts after an unload of $1 (peer $2); $3 = scenario label, $4 = boot id of $1 before, $5 = boot id of $2 before
verdicts() {
    local un="$1" peer="$2" tag="$3" b_un="$4" b_peer="$5"
    local a_un a_peer
    a_un="$(boot_id "$un")"; a_peer="$(boot_id "$peer")"
    if [ "$a_un" = unreachable ]; then
        fail "$tag: $un is unreachable after the unload (crashed or wedged)"; wait_back "$un" || true
    elif [ "$a_un" != "$b_un" ]; then
        fail "$tag: $un rebooted during the unload (boot_id changed)"
    else
        pass "$tag: $un survived the unload"
    fi
    if [ "$a_peer" != "$b_peer" ]; then fail "$tag: peer $peer rebooted (boot_id changed or unreachable)"; else pass "$tag: peer $peer unaffected"; fi
    local left bad
    left="$(rto "$un" "lsmod | grep -c '^mattx'; true" 2>/dev/null | head -1)"; left="${left:-?}"
    if [ "$left" = 0 ]; then pass "$tag: mattx modules unloaded on $un"
    elif [[ "$tag" == S3* ]]; then pass "$tag: rmmod refused while migrated guests hold ghost files ($left module(s) still loaded on $un, node intact)"
    else fail "$tag: $left mattx module(s) still loaded on $un"; fi
    for n in "$un" "$peer"; do
        bad="$(bad_lines "$n")"
        [ "$bad" = 0 ] && pass "$tag: no oops/BUG/hung task on $n" || fail "$tag: $bad oops/BUG/hung-task line(s) on $n"
    done
}

echo "=== MattX unload with active guests on the ${DISTRO} pair (${NODE1}, ${NODE2}) ==="
build_workloads || { fail "unload-0: could not build the workloads on $NODE1"; echo "Unload-active Results: $PASS passed, $FAIL failed"; exit 1; }
kill_workloads
if ! ensure_cluster; then fail "unload-0: MattX is not running on both nodes"; echo "Unload-active Results: $PASS passed, $FAIL failed"; exit 1; fi
ID2="$(node_id "$NODE2")"; ID1="$(node_id "$NODE1")"
echo "  node ids: $NODE1=$ID1 $NODE2=$ID2"
CRASH0_1="$(crash_cnt "$NODE1")"; CRASH0_2="$(crash_cnt "$NODE2")"

run_scenario() {   # $1 = tag, $2 = node to unload, $3 = its peer, $4 = delay-mode (settle|race)
    local tag="$1" un="$2" peer="$3" mode="$4" b_un b_peer rc=0
    echo ""; echo "--- $tag: unload $un (guests ${mode}) ---"
    kill_workloads; ensure_cluster || { fail "$tag: could not (re)start the cluster"; return; }
    rto "$NODE1" "sudo dmesg -C" >/dev/null 2>&1 || true; rto "$NODE2" "sudo dmesg -C" >/dev/null 2>&1 || true
    b_un="$(boot_id "$un")"; b_peer="$(boot_id "$peer")"
    start_guests
    if [ "$mode" = settle ]; then
        migrate_guests "$ID2"; sleep 6
        echo "  guests migrated to $NODE2:"; fate
    else
        migrate_guests "$ID2" &
        sleep "0.$((RANDOM % 4))$((RANDOM % 10))"
    fi
    rto "$un" "sudo systemctl stop mattx 2>&1; sudo umount /mattxfs 2>/dev/null; sudo rmmod mattxfs 2>/dev/null; sudo rmmod mattx 2>/dev/null; true" >/dev/null 2>&1 || rc=$?
    wait 2>/dev/null || true
    sleep 6
    [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ] && echo "  (unload command rc=$rc: connection lost or timed out)"
    fate
    verdicts "$un" "$peer" "$tag" "$b_un" "$b_peer"
    # the peer should not keep a stuck/zombie remainder of the departed node's guests
    local stuck
    stuck="$(rto "$peer" "ps -eo stat,comm --no-headers | grep -E 'epoll_threads|servertestpoll|ioloop' | grep -c '^D'; true" 2>/dev/null | head -1)"
    [ "${stuck:-0}" = 0 ] && pass "$tag: no guest process stuck in D state on $peer" || fail "$tag: $stuck guest process(es) stuck in D state on $peer"
    kill_workloads
    if ensure_cluster; then pass "$tag: MattX restarted on both nodes and the cluster re-formed"; else fail "$tag: cluster did not come back after restart"; fi
}

# ONLY="S2" runs just those scenarios (S1 S2 S3); S2_CYCLES repeats S2
want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }
want S1 && run_scenario "S1" "$NODE2" "$NODE1" settle
if want S2; then for i in $(seq 1 "${S2_CYCLES:-1}"); do run_scenario "S2.$i" "$NODE1" "$NODE2" settle; done; fi
if want S3; then for i in $(seq 1 "$CYCLES"); do run_scenario "S3.$i" "$NODE2" "$NODE1" race; done; fi

C1="$(crash_cnt "$NODE1")"; C2="$(crash_cnt "$NODE2")"
echo ""
if [ "$C1" = "$CRASH0_1" ] && [ "$C2" = "$CRASH0_2" ]; then pass "kdump: no crash dump written on either node during the test"
else fail "kdump: new crash dump(s) written (node1 $CRASH0_1 -> $C1, node2 $CRASH0_2 -> $C2) -- /var/crash on the nodes"; fi

echo ""
echo "Unload-active Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
