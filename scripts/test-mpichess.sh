#!/bin/bash
# test-mpichess.sh <alma|deb|ubu|fed>
# Matt's mpichess (tools/mpichess in the mattx repo): an xboard chess master that, on "go", spawns one
# MPI client per legal move (MPI_Comm_spawn, 20 at the start position) and takes the best score.
# Matt (2026-11): migrating the clients by hand works like mpitest, but when the load balancer migrates
# the master by itself, it breaks. This test checks both.
#
# Test 1: build mpichess + mpichess-client with MPICH on both nodes.
# Test 2: baseline -- one game move, nothing migrated (proves the harness and how long a move takes).
# Test 3: manual -- the master computes one move; half of the clients are migrated to node2 by hand while
#         they work. Pass: "move ..." printed, every spawned client's score arrives, no oops. (Hard check.)
# Test 4: balancer -- the same game move with the balancer on and nothing migrated by hand; the
#         balancer decides what moves. We record where the master ended up. Opt-in (MPICHESS_BALANCER=1)
#         because Matt says it is a known failure; it reports pass or fail like any test.
# Tunables: MPICHESS_TIMEOUT (default 400 s per move), MPICHESS_BALANCER, MPICH_PREFIX (see test-mpi.sh).
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    fed)  NODE1="fednode1";  NODE2="fednode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed>" >&2; exit 1 ;;
esac

auto_report_wrap "mpichess" "$@"

init_cluster "$DISTRO"

SRC_DIR="~/mattx/tools/mpichess"
WORK=/tmp/mpichess
TIMEOUT="${MPICHESS_TIMEOUT:-400}"
DEPTH="${MPICHESS_DEPTH:-6}"   # search depth (upstream 5: a move takes ~5 s, too short to migrate a computing client)

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

mpich_env() {
    if [ -n "${MPICH_PREFIX:-}" ]; then
        echo "export PATH=$MPICH_PREFIX/bin:\$PATH LD_LIBRARY_PATH=$MPICH_PREFIX/lib:\${LD_LIBRARY_PATH:-}"; return
    fi
    cat <<'EOS'
if [ -f /usr/share/Modules/init/bash ]; then
    source /usr/share/Modules/init/bash
    module use /usr/share/modulefiles 2>/dev/null || true
    module load mpi/mpich-x86_64 2>/dev/null || true
fi
EOS
}

ensure_mpich() {
    local node="$1"
    run_on "$node" "$(mpich_env); command -v mpicc >/dev/null && command -v mpirun >/dev/null" && return 0
    echo "  [mpi] installing mpich on $node..."
    case "$DISTRO" in
        alma|fed) run_on "$node" "sudo dnf install -y mpich mpich-devel" ;;
        deb|ubu) run_on "$node" "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mpich libmpich-dev" ;;
    esac
    run_on "$node" "$(mpich_env); command -v mpicc >/dev/null && command -v mpirun >/dev/null"
}

cleanup() {
    for n in "$NODE1" "$NODE2"; do
        run_on "$n" "pkill -9 -f '[m]pichess' 2>/dev/null || true; pkill -9 -f '[h]ydra_pmi' 2>/dev/null || true" 2>/dev/null || true
        run_on "$n" "echo 'mpi 0' | sudo tee /proc/mattx/admin >/dev/null; echo 'balancer 0' | sudo tee /proc/mattx/admin >/dev/null" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

echo "=== mpichess (MPI_Comm_spawn, one client per legal move) on ${DISTRO} cluster ==="

echo ""
echo "=== Test 1: build mpichess + mpichess-client on both nodes ==="
BUILD_OK=1
for NODE in "$NODE1" "$NODE2"; do
    ensure_mpich "$NODE" || { echo "  MPICH missing on $NODE"; BUILD_OK=0; continue; }
    if run_on "$NODE" "$(mpich_env); rm -rf $WORK && cp -r $SRC_DIR $WORK && cd $WORK && sed -i \"s/^#define DEPTH .*/#define DEPTH $DEPTH/\" mpichess.h && make >/dev/null 2>&1 && test -x ./mpichess && test -x ./mpichess-client"; then
        echo "  built OK on $NODE"
    else
        echo "  BUILD FAILED on $NODE"; BUILD_OK=0
    fi
done
if [ "$BUILD_OK" -eq 1 ]; then pass "mpichess-1: built on both nodes"; else
    fail "mpichess-1: build failed on at least one node"
    echo ""; echo "=============================="; echo "MPIchess Results: $PASS passed, $FAIL failed"; echo "=============================="
    exit 1
fi

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "mpichess: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "MPIchess Results: $PASS passed, $FAIL failed"; exit 1
fi
for n in "$NODE1" "$NODE2"; do run_on "$n" "echo 'mpi 1' | sudo tee /proc/mattx/admin >/dev/null"; done

# One game move: master gets xboard, new, go; we hold stdin open until told to quit.
# $1 = label. Leaves $WORK/mpichess.log, mpichess.out and /tmp/mpichess_rc on node1.
start_master() {
    run_on "$NODE1" "
        $(mpich_env)
        cd $WORK && rm -f mpichess.log mpichess.out /tmp/mpichess_rc /tmp/mpichess_quit
        setsid nohup bash -c '( echo xboard; echo new; echo go; while [ ! -f /tmp/mpichess_quit ]; do sleep 1; done; echo quit ) | mpirun -launcher fork -np 1 ./mpichess > mpichess.out 2>&1; echo \$? > /tmp/mpichess_rc' </dev/null >/dev/null 2>&1 &
        disown"
}
spawned() { run_on "$NODE1" "grep -c 'Spawning' $WORK/mpichess.log 2>/dev/null; grep -oP 'Spawning \K[0-9]+' $WORK/mpichess.log 2>/dev/null | head -1" 2>/dev/null | tail -1; }
scores()  { run_on "$NODE1" "grep -c 'Received score' $WORK/mpichess.log 2>/dev/null" 2>/dev/null || echo 0; }
cnt() { run_on "$1" "pgrep -x $2 | wc -l" 2>/dev/null | tail -1; }
where() { # master and clients per node
    for n in "$NODE1" "$NODE2"; do echo "    $n: master=$(cnt "$n" mpichess) clients=$(cnt "$n" mpichess-client)"; done
}
wait_move() { # waits for the move line; prints seconds, returns 1 on timeout
    local t=0
    while [ "$t" -lt "$TIMEOUT" ]; do
        run_on "$NODE1" "grep -q '^move ' $WORK/mpichess.out 2>/dev/null" && { echo "$t"; return 0; }
        sleep 5; t=$((t+5))
    done
    echo "$t"; return 1
}
finish() { run_on "$NODE1" "touch /tmp/mpichess_quit"; for _ in $(seq 1 20); do run_on "$NODE1" "test -f /tmp/mpichess_rc" && break; sleep 1; done; run_on "$NODE1" "cat /tmp/mpichess_rc 2>/dev/null || echo none"; }

echo ""
echo "=== Test 2: baseline -- one game move, nothing migrated (how long does it take on these nodes?) ==="
C1=$(dmesg_cursor "$NODE1"); C2=$(dmesg_cursor "$NODE2")
for n in "$NODE1" "$NODE2"; do run_on "$n" "echo 'balancer 0' | sudo tee /proc/mattx/admin >/dev/null"; done
start_master
for _ in $(seq 1 60); do [ "$(cnt "$NODE1" mpichess-client)" -ge 2 ] && break; sleep 1; done
N=$(spawned); echo "  master spawned ${N:-?} clients"
if SECS=$(wait_move); then MOVE_OK=1; echo "  move after ${SECS}s"; else MOVE_OK=0; echo "  no move after ${SECS}s"; fi
NS=$(scores); echo "  scores received: $NS of ${N:-?}"
RC=$(finish)
if [ "$MOVE_OK" -eq 1 ] && [ "${NS:-0}" -ge "${N:-1}" ]; then
    pass "mpichess-2: baseline move finished in ${SECS}s with all $NS scores (mpirun rc=$RC)"
else
    fail "mpichess-2: baseline did not finish: move=$MOVE_OK, scores $NS of ${N:-?} after ${SECS}s (raise MPICHESS_TIMEOUT if the nodes are just slow)"
fi
BASE_SECS="$SECS"
no_new_oops "$NODE1" "$C1" && pass "mpichess-2: no oops on $NODE1" || fail "mpichess-2: oops on $NODE1"
cleanup; sleep 2

echo ""
echo "=== Test 3: manual -- migrate half of the clients to $NODE2 while the master computes a move ==="
C1=$(dmesg_cursor "$NODE1"); C2=$(dmesg_cursor "$NODE2")
for n in "$NODE1" "$NODE2"; do run_on "$n" "echo 'balancer 0' | sudo tee /proc/mattx/admin >/dev/null"; done
start_master
for _ in $(seq 1 60); do
    [ "$(cnt "$NODE1" mpichess-client)" -ge 2 ] && break; sleep 1
done
N=$(spawned); echo "  master spawned ${N:-?} clients"
# migrate only clients that finished MPI_Init and started evaluating (migrating inside MPI_Init made them
# abort: "OFI fi_open domain failed")
for _ in $(seq 1 60); do
    [ "$(run_on "$NODE1" "grep -c 'beginning recursive' $WORK/mpichess.log 2>/dev/null" 2>/dev/null | tail -1)" -ge "${N:-20}" ] && break; sleep 1
done
echo "  clients evaluating: $(run_on "$NODE1" "grep -c 'beginning recursive' $WORK/mpichess.log" 2>/dev/null | tail -1) of ${N:-?}"
PIDS=$(run_on "$NODE1" "pgrep -x mpichess-client" || true)
i=0; MOVED=0
for P in $PIDS; do
    i=$((i+1)); [ $((i % 2)) -eq 0 ] || continue
    mattx_migrate "$NODE1" "$P" "$NODE2_ID" >/dev/null 2>&1 && MOVED=$((MOVED+1)) || true
done
echo "  asked for $MOVED migrations"; sleep 5; where
if SECS=$(wait_move); then
    echo "  move after ${SECS}s"; MOVE_OK=1
else
    echo "  no move after ${SECS}s"; MOVE_OK=0
fi
NS=$(scores); echo "  scores received: $NS of ${N:-?}"; where
RC=$(finish)
if [ "$MOVE_OK" -eq 1 ] && [ "${NS:-0}" -ge "${N:-1}" ]; then
    pass "mpichess-3: master played a move with $MOVED migrated clients, all $NS scores arrived (mpirun rc=$RC)"
else
    fail "mpichess-3: move=$MOVE_OK, scores $NS of ${N:-?} after ${SECS}s with $MOVED migrated clients (mpirun rc=$RC)"
    run_on "$NODE1" "tail -8 $WORK/mpichess.log 2>/dev/null; tail -5 $WORK/mpichess.out 2>/dev/null" | sed 's/^/    /' || true
fi
no_new_oops "$NODE1" "$C1" && pass "mpichess-3: no oops on $NODE1" || fail "mpichess-3: oops on $NODE1"
no_new_oops "$NODE2" "$C2" && pass "mpichess-3: no oops on $NODE2" || fail "mpichess-3: oops on $NODE2"
cleanup; sleep 2

if [ "${MPICHESS_BALANCER:-0}" = 1 ]; then
    echo ""
    echo "=== Test 4: balancer on, nothing migrated by hand ==="
    C1=$(dmesg_cursor "$NODE1"); C2=$(dmesg_cursor "$NODE2")
    for n in "$NODE1" "$NODE2"; do run_on "$n" "echo 'mpi 1' | sudo tee /proc/mattx/admin >/dev/null; echo 'balancer 1' | sudo tee /proc/mattx/admin >/dev/null"; done
    start_master
    N=""; for _ in $(seq 1 60); do N=$(spawned); [ -n "$N" ] && [ "$N" != 0 ] && break; sleep 1; done
    MASTER_MOVED=0; t=0
    while [ "$t" -lt "$TIMEOUT" ]; do
        run_on "$NODE1" "grep -q '^move ' $WORK/mpichess.out 2>/dev/null" && break
        [ "$(cnt "$NODE2" mpichess)" -ge 1 ] && MASTER_MOVED=1
        sleep 5; t=$((t+5))
    done
    run_on "$NODE1" "grep -q '^move ' $WORK/mpichess.out 2>/dev/null" && MOVE_OK=1 || MOVE_OK=0
    NS=$(scores); echo "  master reached $NODE2 at some point: $MASTER_MOVED; scores $NS of ${N:-?}; move=$MOVE_OK after ${t}s"; where
    RC=$(finish)
    if [ "$MOVE_OK" -eq 1 ] && [ "${NS:-0}" -ge "${N:-1}" ]; then
        pass "mpichess-4: balancer run finished the move, all scores arrived (master migrated: $MASTER_MOVED, mpirun rc=$RC)"
    else
        fail "mpichess-4: balancer run broke: move=$MOVE_OK, scores $NS of ${N:-?} after ${t}s (master migrated: $MASTER_MOVED, mpirun rc=$RC) -- the case Matt describes"
        run_on "$NODE1" "tail -8 $WORK/mpichess.log 2>/dev/null" | sed 's/^/    /' || true
    fi
    no_new_oops "$NODE1" "$C1" && pass "mpichess-4: no oops on $NODE1" || fail "mpichess-4: oops on $NODE1"
    no_new_oops "$NODE2" "$C2" && pass "mpichess-4: no oops on $NODE2" || fail "mpichess-4: oops on $NODE2"
else
    echo ""
    echo "  (Test 4, balancer, not run: set MPICHESS_BALANCER=1)"
fi

echo ""
echo "=============================="
echo "MPIchess Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
