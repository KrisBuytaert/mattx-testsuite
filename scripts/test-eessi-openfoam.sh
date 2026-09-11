#!/bin/bash
# test-eessi-openfoam.sh <alma|deb|ubu>
# Run OpenFOAM tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + OpenFOAM module loads + tutorial case found
# Test 2: run pitzDaily (simpleFoam, serial) functional smoke test
# Test 3: migrate a running (single-process, serial) simpleFoam job via MattX
#
# NOTE: this deliberately does NOT use the eessi-demo/OpenFOAM motorBike
# example -- that demo is MPI-parallel (mpirun -np $NP simpleFoam -parallel,
# plus a snappyHexMesh preprocessing pipeline that itself requires MPI).
# MattX has no MPI support (see "MPI Support: NO" in /proc/mattx/nodes), so
# every migration target in this test suite is deliberately single-process
# (same reasoning as GROMACS's -ntmpi 1 and ESPResSo's hand-rolled
# single-process script). pitzDaily is OpenFOAM's standard small tutorial
# case for simpleFoam and runs perfectly well serially with no
# decomposePar/mpirun at all.
# STATUS: not yet confirmed passing on the current MattX build -- only
# run-tests.sh and test-eessi-gromacs.sh are. Treat a [FAIL] here as "not
# yet verified," not necessarily a new regression. See CHANGELOG.md.
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

auto_report_wrap "eessi-openfoam" "$@"

init_cluster "$DISTRO"

# eessi-demo/OpenFOAM only pins a known-good module for EESSI 2023.06 (see
# eessi-demo/OpenFOAM/run.sh) -- don't guess a newer version's module name.
EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
OPENFOAM_MODULE="OpenFOAM/11-foss-2023a"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Print ps evidence for a process pattern on one node. We search by pattern
# rather than by the home-node PID: mattx-stub is a distinct process spawned
# locally on the remote node via call_usermodehelper, so it gets its own
# kernel-assigned PID there -- the original home PID has no reason to exist
# as a process on the remote node at all, so `ps -p <home-pid>` on the
# Surrogate's node reliably (and misleadingly) finds nothing.
# The exact remote command is echoed first so the evidence is self-proving:
# a reviewer can see which host it ran on and what was asked, not just the
# result.
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

# Print ps evidence for the same pattern on BOTH nodes, side by side, so a
# frozen Deputy (STAT contains 'T') and a running Surrogate are both
# visible in one place -- the actual proof that a migration moved
# execution rather than just restarting a fresh process.
show_both_nodes() {
    local label="$1" pattern="$2"
    echo ""
    echo "  --- ps snapshot: $label (pattern: '$pattern') ---"
    show_location "$pattern" "$NODE1"
    show_location "$pattern" "$NODE2"
}

# dmesg evidence for the actual MattX freeze/capture/import/recall pipeline
# (config_debug_mode defaults to true, so mattx_dbg() lines are always being
# logged) -- lets the report show directly whether mattx_freeze_task_safely
# ([DRAIN]/[EXTRACT]) and the remote awakening ([IMPORT]/[RECALL]) actually
# ran for this PID, rather than only inferring it from ps snapshots.
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

# STAT field of the first process matching pattern on this node, or empty
# if no matching process exists at all. Distinguishes "gone" from "present
# but frozen" -- ps aux | grep can't, which silently produced false-positive
# PASSes before this check existed (see mattx#8 for a case that hid behind
# exactly this gap).
process_stat() {
    local pattern="$1" node="$2"
    run_on "$node" "ps -eo stat,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep | awk '{print \$1}' | head -1" 2>/dev/null
}

# Is a process matching pattern actually EXECUTING on this node (STAT other
# than T=stopped or Z=zombie), as opposed to merely PRESENT?
is_actually_running() {
    local pattern="$1" node="$2"
    local stat; stat="$(process_stat "$pattern" "$node")"
    [ -n "$stat" ] && [[ "$stat" != T* && "$stat" != Z* ]]
}

# Announce and execute a migration.
# $6 (actual_from) is optional and only needed for the "home" recall path,
# where the admin command must be issued on the home node ($from) but the
# job is actually currently running somewhere else -- without it, the log
# misleadingly shows "from: home_node to: home_node" for a migration that's
# really coming from wherever the job currently lives. Defaults to $from
# (the ordinary forward-migration case, where they're the same node).
do_migrate() {
    local name="$1" pid="$2" from="$3" to="$4" to_id="$5" actual_from="${6:-$3}"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo "  Starting migration of $name [PID $pid]"
    echo "    from : $actual_from ($(node_ip "$actual_from"))"
    echo "    to   : $to   ($(node_ip "$to"))  [node ID $to_id]"
    if [ "$from" != "$actual_from" ]; then
        echo "    (admin command issued on $from, the home node -- not on $actual_from, where the job actually is)"
    fi
    echo "    tool : $(mattx_tool_label)   (run on $from)"
    echo "  ─────────────────────────────────────────────────────"
    mattx_migrate "$from" "$pid" "$to_id"
}

# Runs on any script exit (normal completion, an early `exit 1`, or an
# uncaught error under `set -e`) so a job started on whichever node it
# happened to be on at the time doesn't outlive the test. Safe to call
# multiple times / before the PID var is even set.
cleanup() {
    run_on "$NODE1" "kill -9 ${SFOAM_PID:-} 2>/dev/null || true; pkill -9 -f '[s]impleFoam' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[s]impleFoam' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== OpenFOAM / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + module load + tutorial case discovery ----
echo "=== Test 1: EESSI OpenFOAM module load + pitzDaily tutorial lookup ==="

# OpenFOAM 11 (ESI/OpenCFD layout) groups classic solver-named tutorials
# under physics-based directory names -- the eessi-demo motorBike example
# lives under tutorials/incompressibleFluid/motorBike, so pitzDaily most
# likely lives alongside it. Don't hard-fail on a layout guess though --
# fall back to a live `find` so this test survives an OpenFOAM version
# bump that reshuffles the tutorial tree.
if PITZDAILY_DIR=$(run_on "$NODE1" "
    set -e
    source '${EESSI_INIT}'
    module load ${OPENFOAM_MODULE}
    # OpenFOAM's own etc/bashrc hits a benign internal 'pop_var_context:
    # head of shell_variables not a function context' condition -- since
    # `source` runs in this SAME shell (not a subshell), that one failing
    # command trips `set -e` and aborts the whole block immediately, even
    # though WM_PROJECT_DIR etc. get set correctly before it happens.
    # `2>/dev/null` alone only hides the warning text; it does NOT stop
    # set -e from firing on a command that fails deep inside a sourced
    # script, so `|| true` is required too (confirmed live: without it,
    # `set -ex` tracing shows the script dies mid-`source`, before even
    # reaching the next line).
    source \$FOAM_BASH 2>/dev/null || true
    test -n \"\$WM_PROJECT_DIR\" || { echo 'WM_PROJECT_DIR not set after module load' >&2; exit 1; }
    if [ -d \"\$WM_PROJECT_DIR/tutorials/incompressibleFluid/pitzDaily\" ]; then
        echo \"\$WM_PROJECT_DIR/tutorials/incompressibleFluid/pitzDaily\"
    else
        find \"\$WM_PROJECT_DIR/tutorials\" -maxdepth 4 -type d -iname pitzDaily 2>/dev/null | head -1
    fi
" 2>&1 | tail -1) && [ -n "$PITZDAILY_DIR" ]; then
    pass "openfoam-1: OpenFOAM module (${OPENFOAM_MODULE}) loads on $NODE1, pitzDaily found at $PITZDAILY_DIR"
else
    fail "openfoam-1: OpenFOAM module (${OPENFOAM_MODULE}) failed to load on $NODE1, or pitzDaily tutorial not found"
    PITZDAILY_DIR=""
fi

OPENFOAM_WORKDIR="/tmp/eessi-openfoam"

# ---- Test 2: pitzDaily functional smoke test (serial simpleFoam) ----
echo ""
echo "=== Test 2: pitzDaily functional run (serial simpleFoam, short) ==="

if [ -z "$PITZDAILY_DIR" ]; then
    fail "openfoam-2: skipped -- pitzDaily tutorial not found in Test 1"
    fail "openfoam-3: cannot run migration test without a working tutorial case"
    echo ""
    echo "=============================="
    echo "OpenFOAM Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

run_on "$NODE1" "rm -rf $OPENFOAM_WORKDIR && mkdir -p $OPENFOAM_WORKDIR"

echo "  Running short pitzDaily smoke test on $NODE1 ($(node_ip "$NODE1"))..."
if run_on "$NODE1" "
    set -e
    source '${EESSI_INIT}'
    module load ${OPENFOAM_MODULE}
    source \$FOAM_BASH 2>/dev/null || true
    cp -r '${PITZDAILY_DIR}' $OPENFOAM_WORKDIR/pitzDaily_smoke
    cd $OPENFOAM_WORKDIR/pitzDaily_smoke
    chmod -R u+w .
    foamDictionary -entry endTime -set 20 system/controlDict
    foamDictionary -entry writeInterval -set 1000 system/controlDict
    blockMesh 2>&1 | tee log.blockMesh
    timeout 120 simpleFoam 2>&1 | tee log.simpleFoam
    grep -q '^Time = ' log.simpleFoam
" 2>&1; then
    ITERS=$(run_on "$NODE1" "grep -c '^Time = ' $OPENFOAM_WORKDIR/pitzDaily_smoke/log.simpleFoam 2>/dev/null || echo 0")
    pass "openfoam-2: pitzDaily smoke test completed on $NODE1 ($ITERS time steps)"
else
    fail "openfoam-2: pitzDaily smoke test failed or timed out on $NODE1"
fi

# ---- Test 3: simpleFoam round-trip migration via MattX (NODE1 -> NODE2 -> NODE1) ----
echo ""
echo "=== Test 3: OpenFOAM round-trip migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "openfoam-3: MattX not running on $NODE1/$NODE2 -- run 'make ${DISTRO}cluster' first"
else
    # A much longer run (big endTime, residual control tightened so it
    # can't converge-and-exit early) so simpleFoam's per-iteration solver
    # loop runs long enough (a minute or more) to be migrated mid-flight,
    # instead of finishing before the migration window opens. Serial
    # (no mpirun/decomposePar) -- same single-process constraint as
    # everywhere else in this suite (MattX has no MPI support).
    echo "  Preparing long-running pitzDaily case on $NODE1 ($(node_ip "$NODE1"))..."
    run_on "$NODE1" "
        set -e
        source '${EESSI_INIT}'
        module load ${OPENFOAM_MODULE}
        source \$FOAM_BASH 2>/dev/null || true
        rm -rf $OPENFOAM_WORKDIR/pitzDaily_mig
        cp -r '${PITZDAILY_DIR}' $OPENFOAM_WORKDIR/pitzDaily_mig
        cd $OPENFOAM_WORKDIR/pitzDaily_mig
        chmod -R u+w .
        foamDictionary -entry endTime -set 5000 system/controlDict
        foamDictionary -entry writeInterval -set 100000 system/controlDict
        foamDictionary -entry runTimeModifiable -set false system/controlDict
        blockMesh > log.blockMesh 2>&1
    "

    echo "  Starting simpleFoam on $NODE1 -- slow/long migration target..."
    SFOAM_PID=$(run_on "$NODE1" "
        set -e
        source '${EESSI_INIT}'
        module load ${OPENFOAM_MODULE}
        source \$FOAM_BASH 2>/dev/null || true
        cd $OPENFOAM_WORKDIR/pitzDaily_mig
        nohup simpleFoam > log.simpleFoam_mig 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    if ! run_on "$NODE1" "kill -0 $SFOAM_PID 2>/dev/null"; then
        fail "openfoam-3: simpleFoam exited before migration window -- check $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig"
        run_on "$NODE1" "tail -20 $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || true" | sed 's/^/    /'
    else
        show_both_nodes "baseline, before outbound migration" "simpleFoam"
        ITERS_BEFORE=$(run_on "$NODE1" "grep -c '^Time = ' $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || echo 0")
        echo "  Log tail from $NODE1 (time steps so far: $ITERS_BEFORE):"
        run_on "$NODE1" "tail -5 $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || true" | sed 's/^/    /'

        do_migrate "simpleFoam" "$SFOAM_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "simpleFoam"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "simpleFoam" "$NODE2"; then
            pass "openfoam-3: simpleFoam migrated to $NODE2"

            sleep 20
            show_both_nodes "20s after outbound migration (settled state)" "simpleFoam"
            STAT2=$(process_stat "simpleFoam" "$NODE2")
            ITERS_AFTER=$(run_on "$NODE1" "grep -c '^Time = ' $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$ITERS_AFTER" -gt "$ITERS_BEFORE" ]; then
                pass "openfoam-3: simpleFoam still running on $NODE2 after 20s (time steps $ITERS_BEFORE -> $ITERS_AFTER)"

                # ---- Return leg: recall home, NODE2 -> NODE1 ----
                # The "home" recall path (admin_write's "migrate <pid> home"
                # -> mattx_trigger_recall) is DIFFERENT from the generic
                # "migrate <pid> <node>" path and must be issued ON THE HOME
                # NODE ($NODE1), using the ORIGINAL PID ($SFOAM_PID) --
                # mattx_trigger_recall() looks up the export_registry entry
                # for orig_pid, which only exists on the node that originally
                # exported it, then sends a RECALL_REQ to wherever the guest
                # currently lives. Using $NODE2/the Surrogate's local PID
                # here (as the generic migrate path requires) instead hits
                # "PID is not in the export registry. Cannot recall" -- or,
                # if sent as a plain numeric-node migrate instead of "home",
                # silently takes the generic forward-migrate path, which
                # doesn't handle re-targeting a PID that already has a stale
                # Deputy/registry entry on the destination and can crash the
                # process right after wake.
                do_migrate "simpleFoam" "$SFOAM_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "simpleFoam"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "simpleFoam" "$NODE1"; then
                    pass "openfoam-4: simpleFoam migrated back to $NODE1"

                    ITERS_RETURN=$(run_on "$NODE1" "grep -c '^Time = ' $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || echo 0")
                    sleep 20
                    show_both_nodes "20s after return migration (settled state)" "simpleFoam"
                    STAT4=$(process_stat "simpleFoam" "$NODE1")
                    ITERS_FINAL=$(run_on "$NODE1" "grep -c '^Time = ' $OPENFOAM_WORKDIR/pitzDaily_mig/log.simpleFoam_mig 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$ITERS_FINAL" -gt "$ITERS_RETURN" ]; then
                        pass "openfoam-4: simpleFoam still running on $NODE1 after 20s (round trip complete, time steps $ITERS_RETURN -> $ITERS_FINAL)"
                    elif [ -n "$STAT4" ]; then
                        fail "openfoam-4: simpleFoam present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► simpleFoam [PID $SFOAM_PID] completed on $NODE1 after returning"
                        pass "openfoam-4: simpleFoam ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "openfoam-4: simpleFoam not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                fail "openfoam-3: simpleFoam present and running on $NODE2, but time-step count did not advance ($ITERS_BEFORE -> $ITERS_AFTER) -- looks alive but not making progress"
            elif [ -n "$STAT2" ]; then
                fail "openfoam-3: simpleFoam present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► simpleFoam [PID $SFOAM_PID] completed on $NODE2 before the return leg could start"
                pass "openfoam-3: simpleFoam ran to completion on $NODE2"
                fail "openfoam-4: cannot perform return-leg migration -- job completed on $NODE2 before it could be migrated back (increase endTime if this recurs)"
            fi
        else
            fail "openfoam-3: simpleFoam not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi

        run_on "$NODE1" "kill -9 $SFOAM_PID 2>/dev/null || true; pkill -9 -f '[s]impleFoam' 2>/dev/null || true"
        run_on "$NODE2" "pkill -9 -f '[s]impleFoam' 2>/dev/null || true"
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "openfoam-4: no kernel oops on $NODE1"
    else
        fail "openfoam-4: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "openfoam-4: no kernel oops on $NODE2"
    else
        fail "openfoam-4: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "OpenFOAM Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
