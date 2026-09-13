#!/bin/bash
# test-eessi-osu-shm.sh <alma|deb|ubu>
# Run OSU Micro-Benchmarks via EESSI to test shared-memory migration.
# Test 1: verify EESSI mounted + OSU-Micro-Benchmarks module loads
# Test 2: baseline osu_bw run, 2 ranks pinned to the SAME node (functional
#         check that the shared-memory transport itself works before we
#         touch migration at all)
# Test 3: migrate ONE of two co-located, actively-communicating MPI ranks
#         to the other node mid-run. Unlike the other EESSI suites, this is
#         NOT expected to produce a clean round trip: the two ranks talk to
#         each other over Open MPI's vader/sm BTL, which is a MAP_SHARED
#         mmap of a /dev/shm segment local to the host kernel -- once the
#         migrated rank's VMA layout is captured and recreated on the other
#         node, that segment cannot mean the same thing there.
#
#         Liveness (ps STAT not T/Z) is NOT used as the pass signal here.
#         The vader/sm BTL busy-polls its shared ring buffer instead of
#         blocking, so a rank cut off from its peer by migration is
#         expected to spin at ~100% CPU *forever* rather than crash or
#         freeze -- "still running" would be true of both a healthy rank
#         and a permanently hung one, so it proves nothing on its own.
#         Instead, the job runs as a wrapper loop of short, independently
#         timed rounds, each stamping a ROUND_START/ROUND_END heartbeat
#         (with exit code) into the log. We migrate a rank mid-round and
#         then require that SPECIFIC round to post a ROUND_END with rc=0
#         within a bounded window -- i.e. both ranks must actually reach
#         MPI_Finalize for that round, not merely still exist in `ps`. No
#         heartbeat (or a nonzero rc) within the window is reported as a
#         suspected shared-memory hang, which is the failure this test
#         exists to catch.
#
# STATUS: not yet confirmed passing end-to-end on the current MattX build
# (beyond Test 3's own by-design "no clean round trip" expectation above)
# -- only run-tests.sh and test-eessi-gromacs.sh are. Treat a [FAIL] here
# as "not yet verified," not necessarily a new regression. See CHANGELOG.md.
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

auto_report_wrap "eessi-osu-shm" "$@"

init_cluster "$DISTRO"

EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
OSU_MODULE="${OSU_MODULE:-OSU-Micro-Benchmarks/7.1-1-gompi-2023a}"

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

cleanup() {
    run_on "$NODE1" "pkill -9 -f '[o]su_shm_wrapper' 2>/dev/null || true; pkill -9 -f '[o]su_' 2>/dev/null || true; pkill -9 -f '[m]pirun.*osu_' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[o]su_' 2>/dev/null || true" 2>/dev/null || true
    # Per upstream (brainmatt, mattx#15): MPI support is off by default and
    # should be switched back off for any non-MPI test after we're done here.
    run_on "$NODE1" "echo 'mpi 0' | sudo tee /proc/mattx/admin > /dev/null" 2>/dev/null || true
    run_on "$NODE2" "echo 'mpi 0' | sudo tee /proc/mattx/admin > /dev/null" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== OSU Micro-Benchmarks shared-memory migration tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# Per upstream (brainmatt, mattx#15 comment 2026-09-12): MPI support is off by
# default via /proc/mattx/admin, and VMA handling for MPI processes is "very
# special especially during migration" -- enable it on all nodes before any
# MPI-shaped test, and cleanup() switches it back off above.
echo "[mpi] enabling MPI support on $NODE1 and $NODE2 (echo 'mpi 1' > /proc/mattx/admin)..."
run_on "$NODE1" "echo 'mpi 1' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'mpi 1' | sudo tee /proc/mattx/admin > /dev/null"

# ---- Test 1: EESSI mount + module load ----
echo "=== Test 1: EESSI OSU-Micro-Benchmarks module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${OSU_MODULE}
    command -v osu_bw && command -v osu_latency
"; then
    pass "osu-shm-1: OSU-Micro-Benchmarks module loads on $NODE1 (${OSU_MODULE})"
else
    fail "osu-shm-1: OSU-Micro-Benchmarks module failed to load on $NODE1 (${OSU_MODULE})"
fi

# ---- Test 2: baseline shared-memory bandwidth, both ranks local ----
echo ""
echo "=== Test 2: osu_bw baseline, 2 ranks co-located on $NODE1 (shared-memory transport) ==="
if run_on "$NODE1" "
    set -e
    source '${EESSI_INIT}'
    module load ${OSU_MODULE}
    echo '  Running: mpirun -np 2 --bind-to none osu_bw'
    timeout 120 mpirun -np 2 --bind-to none osu_bw
" 2>&1; then
    pass "osu-shm-2: osu_bw completed via shared-memory transport on $NODE1"
else
    fail "osu-shm-2: osu_bw failed or timed out on $NODE1"
fi

# ---- Test 3: migrate one rank of a live shared-memory pair mid-run ----
echo ""
echo "=== Test 3: migrate one rank of a live osu_latency pair via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
POLL_TIMEOUT="${OSU_SHM_POLL_TIMEOUT:-60}"   # seconds to wait for the in-flight round's heartbeat after migration
POLL_INTERVAL=5

if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "osu-shm-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    echo "  Starting a round-heartbeat osu_latency wrapper (2 co-located ranks) on $NODE1 ($(node_ip "$NODE1"))..."
    # Each round is short (-m fixes a single 64B message, -i is small) so a
    # HEALTHY round normally finishes in well under a second -- the 60s
    # default POLL_TIMEOUT below is a wide margin, not a tight fit. `timeout
    # 45` bounds a genuinely hung round so the wrapper doesn't wedge this
    # test's own cleanup forever; that's well past our own detection
    # window, so a real hang is caught and reported long before the
    # wrapper's own safety timeout would paper over it with a fresh round.
    run_on "$NODE1" "cat > /tmp/osu_shm_wrapper.sh" <<'WRAPEOF'
#!/bin/bash
n=0
: > /tmp/osu_shm_migtest.log
while true; do
    n=$((n+1))
    echo "ROUND_START $n $(date +%s)" >> /tmp/osu_shm_migtest.log
    timeout 45 mpirun -np 2 --bind-to none osu_latency -x 20 -i 20000 -m 64:64 >> /tmp/osu_shm_migtest.log 2>&1
    rc=$?
    echo "ROUND_END $n rc=$rc $(date +%s)" >> /tmp/osu_shm_migtest.log
done
WRAPEOF
    run_on "$NODE1" "chmod +x /tmp/osu_shm_wrapper.sh"

    run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ${OSU_MODULE}
        nohup /tmp/osu_shm_wrapper.sh >/tmp/osu_shm_wrapper.log 2>&1 &
        echo \$!
    " >/tmp/osu_shm_wrapper_pid.$$ 2>&1 || true
    WRAPPER_PID=$(tail -1 /tmp/osu_shm_wrapper_pid.$$ 2>/dev/null || true)
    rm -f /tmp/osu_shm_wrapper_pid.$$
    sleep 3

    # Two local osu_latency ranks under mpirun; pick the SECOND one so the
    # peer rank (needed for the shared-memory segment to mean anything at
    # all) keeps running natively on $NODE1 throughout.
    TARGET_PID=$(run_on "$NODE1" "pgrep -f osu_latency 2>/dev/null | tail -1" || true)
    # The round in flight right now -- the one whose completion we'll
    # actually require after migration. Last ROUND_START line's number.
    INFLIGHT_ROUND=$(run_on "$NODE1" "awk '/^ROUND_START/{n=\$2} END{print n}' /tmp/osu_shm_migtest.log 2>/dev/null" || true)

    if [ -z "$TARGET_PID" ] || [ -z "$INFLIGHT_ROUND" ]; then
        fail "osu-shm-3: could not find a running osu_latency rank / in-flight round on $NODE1 to migrate"
    else
        echo "  In-flight round at migration time: $INFLIGHT_ROUND"
        show_both_nodes "baseline, before migration" "osu_latency"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 /tmp/osu_shm_migtest.log 2>/dev/null || true" | sed 's/^/    /'

        do_migrate "osu_latency rank (shared-memory peer)" "$TARGET_PID" "$NODE1" "$NODE2" "$NODE2_ID"

        echo "  Polling up to ${POLL_TIMEOUT}s for round $INFLIGHT_ROUND to post ROUND_END..."
        ELAPSED=0
        ROUND_END_LINE=""
        while [ "$ELAPSED" -lt "$POLL_TIMEOUT" ]; do
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ROUND_END_LINE=$(run_on "$NODE1" "grep \"^ROUND_END ${INFLIGHT_ROUND} \" /tmp/osu_shm_migtest.log 2>/dev/null" || true)
            [ -n "$ROUND_END_LINE" ] && break
            echo "    ...${ELAPSED}s: no ROUND_END $INFLIGHT_ROUND yet"
        done

        show_both_nodes "after migration, poll ended at ${ELAPSED}s ($NODE1 -> $NODE2)" "osu_latency"
        show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "migration ($NODE1 -> $NODE2)" "$NODE2"

        if [ -n "$ROUND_END_LINE" ]; then
            RC=$(echo "$ROUND_END_LINE" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
            if [ "$RC" = "0" ]; then
                echo "  ► $ROUND_END_LINE"
                pass "osu-shm-3: in-flight round $INFLIGHT_ROUND completed (rc=0) after migration -- both ranks reached MPI_Finalize"
            else
                echo "  ► $ROUND_END_LINE"
                fail "osu-shm-3: in-flight round $INFLIGHT_ROUND ended with rc=$RC after migration -- consistent with a broken/hung shared-memory transport (see header comment)"
            fi
        else
            echo "  ► no ROUND_END for round $INFLIGHT_ROUND within ${POLL_TIMEOUT}s"
            fail "osu-shm-3: round $INFLIGHT_ROUND produced no completion heartbeat within ${POLL_TIMEOUT}s after migration -- suspected shared-memory spin-hang (ps liveness alone would have falsely reported this as fine, see header comment)"
        fi

        echo ""
        echo "  Full log:"
        run_on "$NODE1" "tail -20 /tmp/osu_shm_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    fi

    run_on "$NODE1" "kill -9 ${WRAPPER_PID:-} 2>/dev/null || true; pkill -9 -f '[o]su_latency' 2>/dev/null || true; pkill -9 -f '[m]pirun.*osu_' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[o]su_latency' 2>/dev/null || true"

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "osu-shm-3: no kernel oops on $NODE1"
    else
        fail "osu-shm-3: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "osu-shm-3: no kernel oops on $NODE2"
    else
        fail "osu-shm-3: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "OSU shared-memory Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
