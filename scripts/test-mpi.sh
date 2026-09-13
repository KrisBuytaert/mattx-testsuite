#!/bin/bash
# test-mpi.sh <alma|deb|ubu>
# Dedicated MPI migration test using upstream's own MPICH-debugging pair,
# bin/mpich/mpitest/{mpitest.c,mpitest-client.c} (in the main mattx repo,
# already rsynced onto both nodes by build-mattx.sh/deploy-mattx.sh under
# ~/mattx/bin/mpich/mpitest). This is deliberately separate from
# test-eessi-osu-shm.sh: that suite exercises Open MPI's shared-memory
# (vader/sm BTL) transport between two co-located ranks, which is NOT
# expected to survive migration by design (see its header comment). This
# one exercises MPI_Comm_spawn (a master spawning a single worker) with no
# shared-memory transport between them at all -- the worker just counts
# up from 1 to 1000, sleeping 1s and logging each step, so migrating it
# mid-count is a clean test of "does an MPI-launched process's SEQUENTIAL
# STATE survive migration", independent of any shared-memory question.
#
# Per upstream (brainmatt, mattx#15 comment 2026-09-12): MPI support is off
# by default and toggled via `echo 'mpi 1' > /proc/mattx/admin` on all
# nodes before running MPI-related tests -- this script does that and
# reverts it to 'mpi 0' in cleanup(), regardless of outcome.
#
# NOTE: this uses real MPICH (dnf/apt package, NOT EESSI's Open MPI module
# used by test-eessi-osu-shm.sh), matching upstream's own run-mpitest
# (MPICH_NO_LOCAL is an MPICH-specific knob, meaningless under Open MPI).
# This isn't just cosmetic: EESSI's Open MPI 4.1.5 build hits its own
# MPI_Comm_spawn bug in this environment completely independent of MattX
# ("UNPACK-OPAL-VALUE: UNSUPPORTED TYPE 33 FOR KEY", reproduced even with
# MattX out of the picture entirely and various --mca/--bind-to combos
# tried) -- real MPICH's MPI_Comm_spawn works cleanly here, so that's what
# this test builds against.
#
# Test 1: install MPICH if needed, then build mpitest + mpitest-client on
#         both nodes.
# Test 2: baseline sanity, no migration -- master spawns client, client
#         receives the starting value and begins counting. Proves the
#         harness/build itself works before involving MattX at all. Killed
#         early on purpose (counting to 1000 takes ~17 minutes).
# Test 3: migrate the live mpitest-client mid-count to the other node.
#         Pass signal is the FULL count sequence (before + after migration)
#         being strictly continuous (no restart, no gap, no duplicate) --
#         analogous to test-dsm.sh's loop_sequence()/is_continuous() check.
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

auto_report_wrap "mpi" "$@"

init_cluster "$DISTRO"

MPITEST_DIR="~/mattx/bin/mpich/mpitest"

# Loads MPICH's mpicc/mpirun into PATH for one run_on command. AlmaLinux's
# mpich package ships an environment-modules modulefile (mpi/mpich-x86_64)
# under /usr/share/modulefiles rather than putting mpicc/mpirun on PATH
# directly; Debian/Ubuntu's mpich package does put them straight on PATH
# via update-alternatives, so the module load is skipped there if there's
# nothing to load.
mpich_env() {
    cat <<'EOF'
if [ -f /usr/share/Modules/init/bash ]; then
    source /usr/share/Modules/init/bash
    module use /usr/share/modulefiles 2>/dev/null || true
    module load mpi/mpich-x86_64 2>/dev/null || true
fi
EOF
}

ensure_mpich() {
    local node="$1"
    if run_on "$node" "$(mpich_env); command -v mpicc >/dev/null && command -v mpirun >/dev/null"; then
        return 0
    fi
    echo "  [mpi] installing mpich on $node..."
    case "$DISTRO" in
        alma) run_on "$node" "sudo dnf install -y mpich mpich-devel" ;;
        deb|ubu) run_on "$node" "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mpich libmpich-dev" ;;
    esac
    run_on "$node" "$(mpich_env); command -v mpicc >/dev/null && command -v mpirun >/dev/null"
}

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
    out="$(run_on "$node" "sudo dmesg | grep -E '\[DRAIN\]|\[EXTRACT\]|\[MIGR\]|\[MIGRATE\]|\[EXPORT\]|\[IMPORT\]|\[RECALL\]|\[REGISTRY\]|\[FUNERAL\]|\[ASSASSIN\]' | tail -20" 2>/dev/null || true)"
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

# Extract the sequence of counter values from an mpitest-client log:
# "[CLIENT] Counting... N" -> prints N.
count_sequence() {
    local node="$1" log="$2"
    run_on "$node" "grep -oP '\[CLIENT\] Counting\.\.\. \K[0-9]+' '$log' 2>/dev/null" || true
}

# True if a numeric sequence (one number per line, via stdin) is strictly
# increasing by exactly 1 with no gaps, restarts, or duplicates.
is_continuous() {
    awk 'NR==1{prev=$1; next} { if ($1 != prev+1) { exit 1 } prev=$1 } END{exit (NR<2)}'
}

cleanup() {
    run_on "$NODE1" "pkill -9 -f '[m]pitest' 2>/dev/null || true; pkill -9 -f '[m]pirun' 2>/dev/null || true; pkill -9 -f '[h]ydra_pmi' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[m]pitest' 2>/dev/null || true; pkill -9 -f '[h]ydra_pmi' 2>/dev/null || true" 2>/dev/null || true
    # Per upstream (brainmatt, mattx#15): MPI support is off by default and
    # should be switched back off for any non-MPI test after we're done here.
    run_on "$NODE1" "echo 'mpi 0' | sudo tee /proc/mattx/admin > /dev/null" 2>/dev/null || true
    run_on "$NODE2" "echo 'mpi 0' | sudo tee /proc/mattx/admin > /dev/null" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== MPI (MPI_Comm_spawn) migration tests on ${DISTRO} cluster ==="
echo ""

echo "[mpi] enabling MPI support on $NODE1 and $NODE2 (echo 'mpi 1' > /proc/mattx/admin)..."
run_on "$NODE1" "echo 'mpi 1' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'mpi 1' | sudo tee /proc/mattx/admin > /dev/null"

# ---- Test 1: install MPICH (if needed) + build mpitest/mpitest-client ----
echo ""
echo "=== Test 1: install MPICH (if needed) + build mpitest/mpitest-client ==="
BUILD_OK=1
for NODE in "$NODE1" "$NODE2"; do
    if ! ensure_mpich "$NODE"; then
        echo "  MPICH install/detect FAILED on $NODE"
        BUILD_OK=0
        continue
    fi
    if run_on "$NODE" "
        $(mpich_env)
        cd ${MPITEST_DIR} && make clean >/dev/null 2>&1; make
        test -x ./mpitest && test -x ./mpitest-client
    "; then
        echo "  built OK on $NODE"
    else
        echo "  BUILD FAILED on $NODE"
        BUILD_OK=0
    fi
done
if [ "$BUILD_OK" -eq 1 ]; then
    pass "mpi-1: mpitest + mpitest-client built on both nodes"
else
    fail "mpi-1: build failed on at least one node"
fi

if [ "$BUILD_OK" -eq 0 ]; then
    echo ""
    echo "=============================="
    echo "MPI Results: $PASS passed, $FAIL failed"
    echo "=============================="
    [ "$FAIL" -eq 0 ]
    exit
fi

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)

# ---- Test 2: baseline sanity, no migration ----
echo ""
echo "=== Test 2: baseline sanity -- master spawns client, client starts counting ==="
run_on "$NODE1" "rm -f /tmp/mpitest.log"
run_on "$NODE1" "
    $(mpich_env)
    cd ${MPITEST_DIR}
    setsid nohup mpirun -launcher fork -np 1 ./mpitest </dev/null >/tmp/mpitest_baseline_run.log 2>&1 &
    disown
"
# Hydra's spawn handshake is slow under a detached/no-tty launch (observed
# 20-30s even on a healthy run) -- give it a wide margin before calling it a
# failure.
BASE_OK=0
for _ in $(seq 1 30); do
    sleep 3
    if run_on "$NODE1" "grep -q 'Counting\.\.\. [1-9]' /tmp/mpitest.log 2>/dev/null"; then
        BASE_OK=1
        break
    fi
done
if [ "$BASE_OK" -eq 1 ]; then
    pass "mpi-2: baseline master/client started and counting, no migration involved"
else
    fail "mpi-2: mpitest-client never started counting within 90s"
    run_on "$NODE1" "tail -20 /tmp/mpitest.log 2>/dev/null; echo '--- runner log ---'; tail -20 /tmp/mpitest_baseline_run.log 2>/dev/null" | sed 's/^/    /' || true
fi
run_on "$NODE1" "pkill -9 -f '[m]pitest' 2>/dev/null || true; pkill -9 -f '[h]ydra_pmi' 2>/dev/null || true"
sleep 1

# ---- Test 3: migrate the live client mid-count ----
echo ""
echo "=== Test 3: migrate mpitest-client mid-count via MattX ==="
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "mpi-3: MattX not running on $NODE1/$NODE2 -- run 'make ${DISTRO}cluster' first"
else
    DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
    DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")

    run_on "$NODE1" "rm -f /tmp/mpitest.log"
    run_on "$NODE1" "
        $(mpich_env)
        cd ${MPITEST_DIR}
        setsid nohup mpirun -launcher fork -np 1 ./mpitest </dev/null >/tmp/mpitest_run.log 2>&1 &
        disown
    "

    # Wait for a few counts to land before migrating (Hydra's spawn
    # handshake is slow under a detached/no-tty launch -- see Test 2).
    for _ in $(seq 1 30); do
        sleep 3
        run_on "$NODE1" "grep -q 'Counting\.\.\. 3' /tmp/mpitest.log 2>/dev/null" && break
    done

    TARGET_PID=$(run_on "$NODE1" "pgrep -f '[m]pitest-client' 2>/dev/null | head -1" || true)
    PRE_SEQ=$(count_sequence "$NODE1" "/tmp/mpitest.log")
    PRE_LAST=$(echo "$PRE_SEQ" | tail -1)
    echo "  Counts completed before migration: $(echo "$PRE_SEQ" | wc -l) (last: ${PRE_LAST:-none})"

    if [ -z "$TARGET_PID" ]; then
        fail "mpi-3: could not find a running mpitest-client PID on $NODE1 to migrate"
    else
        show_both_nodes "baseline, before migration" "mpitest"

        do_migrate "mpitest-client" "$TARGET_PID" "$NODE1" "$NODE2" "$NODE2_ID"

        # Poll rather than a single flat sleep: a client that advances by
        # just one more count then permanently stalls would slip past a
        # "moved at all" check, so require it to keep making REAL forward
        # progress at roughly its pre-migration rate (~1/s), not just move
        # once. PRE_LAST + MIN_ADVANCE within POLL_TIMEOUT is a wide margin
        # for migration/wake overhead while still catching a post-migration
        # hang.
        POLL_TIMEOUT="${MPI_POLL_TIMEOUT:-60}"
        POLL_INTERVAL=5
        MIN_ADVANCE=15
        TARGET_COUNT=$(( ${PRE_LAST:-0} + MIN_ADVANCE ))
        echo "  Polling up to ${POLL_TIMEOUT}s for the count to reach ${TARGET_COUNT} (pre-migration last: ${PRE_LAST:-0})..."
        ELAPSED=0
        FULL_SEQ=""
        LAST_SEEN=""
        while [ "$ELAPSED" -lt "$POLL_TIMEOUT" ]; do
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            FULL_SEQ=$(count_sequence "$NODE1" "/tmp/mpitest.log")
            LAST_SEEN=$(echo "$FULL_SEQ" | tail -1)
            echo "    ...${ELAPSED}s: last count seen = ${LAST_SEEN:-none}"
            [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" -ge "$TARGET_COUNT" ] && break
        done

        show_both_nodes "after migration, poll ended at ${ELAPSED}s" "mpitest"
        show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE2"

        FULL_COUNT=$(echo "$FULL_SEQ" | grep -c . || true)
        echo "  Total counts recorded (before + after migration): $FULL_COUNT (last: ${LAST_SEEN:-none})"

        if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" -ge "$TARGET_COUNT" ] && echo "$FULL_SEQ" | is_continuous; then
            pass "mpi-3: counting continued at a healthy rate, strictly continuous, across migration ($FULL_COUNT counts total, reached $LAST_SEEN)"
        else
            fail "mpi-3: counting stalled or broke after migration -- last count was $LAST_SEEN, wanted >= $TARGET_COUNT within ${POLL_TIMEOUT}s (sequence continuous: $(echo "$FULL_SEQ" | is_continuous && echo yes || echo no)) -- suspected post-migration hang, not just 'no clean round trip'"
            echo "  Log tail:"
            run_on "$NODE1" "tail -20 /tmp/mpitest.log 2>/dev/null" | sed 's/^/    /' || true
        fi
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "mpi-3: no kernel oops on $NODE1"
    else
        fail "mpi-3: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "mpi-3: no kernel oops on $NODE2"
    else
        fail "mpi-3: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "MPI Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
