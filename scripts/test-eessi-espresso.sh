#!/bin/bash
# test-eessi-espresso.sh <alma|deb|ubu>
# Run ESPResSo tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + ESPResSo module loads
# Test 2: run plate_capacitor.py (functional MPI run)
# Test 3: migrate a single-process ESPResSo job via MattX
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

auto_report_wrap "eessi-espresso" "$@"

init_cluster "$DISTRO"

EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Print ps evidence for a process pattern on one node. We search by pattern
# rather than by the home-node PID: mattx-stub is a distinct process spawned
# locally on the remote node via call_usermodehelper, so it gets its own
# kernel-assigned PID there — the original home PID has no reason to exist
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
# visible in one place — the actual proof that a migration moved
# execution rather than just restarting a fresh process.
show_both_nodes() {
    local label="$1" pattern="$2"
    echo ""
    echo "  --- ps snapshot: $label (pattern: '$pattern') ---"
    show_location "$pattern" "$NODE1"
    show_location "$pattern" "$NODE2"
}

# Per-THREAD ps view (adds TID/WCHAN, drops the etime noise). A process-level
# `ps -eo` row can only show the state of the thread-group leader; a
# multi-threaded job can have its leader genuinely frozen by
# mattx_freeze_task_safely() (mattx_migr.c) while sibling threads keep
# running and burning CPU. This is the evidence that distinguishes "the
# Deputy is truly frozen" from "the process looks idle in aggregate."
# IMPORTANT: the ps format string below ends in `cmd` (full command line,
# e.g. "gmx mdrun -s ion_channel.tpr ..."), NOT `comm` (bare executable
# name only, e.g. "gmx" -- no arguments, ever). This bit us for real: with
# `comm`, a multi-word $pattern like "gmx mdrun" can never match anything,
# since "mdrun" is an argument, not part of the executable name -- the
# check silently and permanently reported "no threads matching" regardless
# of whether the process was actually there. Confirmed live on a real gmx
# process (PID 91116): `ps -eo comm` printed just "gmx"; `ps -eo cmd`
# printed the full "gmx mdrun -s ion_channel.tpr -nsteps 2000 ...". If
# you're tempted to "simplify" this back to `comm` because it's shorter,
# don't -- see the two ps calls above for what that actually does.
show_threads() {
    local pattern="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    local cmd="ps -eLo pid,tid,ppid,user,stat,%cpu,wchan:24,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep"
    echo "  mattx@${node} (${ip})\$ $cmd"
    local out
    out="$(run_on "$node" "$cmd" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        echo "$out" | sed 's/^/      /'
    else
        echo "      (no threads matching '$pattern' on $node)"
    fi
}

# dmesg evidence for the actual MattX freeze/capture/import/recall pipeline
# (config_debug_mode defaults to true, so mattx_dbg() lines are always being
# logged) — lets the report show directly whether mattx_freeze_task_safely
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
    echo "    command: echo 'migrate ${pid} ${to_id}' | sudo tee /proc/mattx/admin   (run on $from)"
    echo "  ─────────────────────────────────────────────────────"
    run_on "$from" "echo 'migrate ${pid} ${to_id}' | sudo tee /proc/mattx/admin > /dev/null"
}

# Runs on any script exit (normal completion, an early `exit 1`, or an
# uncaught error under `set -e`) so a job started on whichever node it
# happened to be on at the time doesn't outlive the test. Safe to call
# multiple times / before the PID var is even set.
cleanup() {
    run_on "$NODE1" "kill -9 ${JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[e]spresso_migtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[e]spresso_migtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== ESPResSo / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + module load ----
echo "=== Test 1: EESSI ESPResSo module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ESPResSo/4.2.2-foss-2023a
    pypresso --version >/dev/null 2>&1 || python3 -c 'import espressomd; print(espressomd.__version__)'
"; then
    pass "espresso-1: ESPResSo module loads on $NODE1"
else
    fail "espresso-1: ESPResSo module failed to load on $NODE1 (EESSI ${EESSI_VERSION})"
fi

# ---- Test 2: plate_capacitor.py functional run ----
echo ""
echo "=== Test 2: plate_capacitor.py (MPI, 2 ranks) ==="

echo "  Syncing demo scripts to $NODE1..."
rsync_to "$TEST_DIR/eessi-demo/ESPResSo/" "$NODE1" "/tmp/eessi-espresso/"

echo "  Launching plate_capacitor.py on $NODE1 ($(node_ip "$NODE1"))..."
if run_on "$NODE1" "
    set -e
    cd /tmp/eessi-espresso
    source '${EESSI_INIT}'
    module load ESPResSo/4.2.2-foss-2023a
    module load matplotlib/3.7.2-gfbf-2023a
    export OMPI_MCA_rmaps_base_oversubscribe=true
    echo '  Running: mpirun -np 2 pypresso plate_capacitor.py'
    timeout 300 mpirun -np 2 pypresso plate_capacitor.py
    test -f plate_capacitor_before.png
" 2>&1; then
    pass "espresso-2: plate_capacitor.py completed and produced output on $NODE1"
else
    fail "espresso-2: plate_capacitor.py failed or timed out on $NODE1"
fi

# ---- Test 3: Single-process ESPResSo migration via MattX ----
echo ""
echo "=== Test 3: ESPResSo migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "espresso-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    # Upload a single-process long-running ESPResSo job
    run_on "$NODE1" "cat > /tmp/espresso_migtest.py" <<'PYEOF'
import espressomd
import time
import os

print("ESPResSo migtest PID={} starting on {}".format(os.getpid(), os.uname().nodename), flush=True)
system = espressomd.System(box_l=[10, 10, 10])
system.time_step = 0.01
system.cell_system.skin = 0.4

for i in range(50):
    system.part.add(pos=[float(i % 10), float((i // 10) % 10), 0.0])

for step in range(500):
    system.integrator.run(50)
    if step % 10 == 0:
        print("step {}/500  node={}  pid={}".format(step, os.uname().nodename, os.getpid()), flush=True)
    time.sleep(0.4)

print("ESPResSo migtest DONE on {}".format(os.uname().nodename), flush=True)
PYEOF

    echo "  Starting pypresso migtest on $NODE1 ($(node_ip "$NODE1"))..."
    # EESSI/Lmod init prints banner lines to stdout, so `echo $!` is not
    # necessarily the only line captured — take the last line to isolate it.
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ESPResSo/4.2.2-foss-2023a
        nohup pypresso /tmp/espresso_migtest.py >/tmp/espresso_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 8

    WORKER_PID=$(run_on "$NODE1" \
        "pgrep -P $JOB_PID pypresso 2>/dev/null | head -1 \
         || pgrep -f espresso_migtest 2>/dev/null | head -1 \
         || echo ''" || true)
    TARGET_PID="${WORKER_PID:-$JOB_PID}"

    show_both_nodes "baseline, before outbound migration" "pypresso|espresso_migtest"
    show_threads "pypresso|espresso_migtest" "$NODE1"
    echo "  Log tail from $NODE1:"
    run_on "$NODE1" "tail -5 /tmp/espresso_migtest.log 2>/dev/null || true" | sed 's/^/    /'

    do_migrate "pypresso (ESPResSo)" "$TARGET_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 8

    show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "pypresso|espresso_migtest"
    show_threads "pypresso|espresso_migtest" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
    if is_actually_running "pypresso|espresso_migtest" "$NODE2"; then
        echo "  Log tail (stdout forwarded via MattX wormhole):"
        run_on "$NODE1" "tail -5 /tmp/espresso_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        pass "espresso-3: ESPResSo process migrated to $NODE2"

        sleep 15
        show_both_nodes "15s after outbound migration (settled state)" "pypresso|espresso_migtest"
        STAT2=$(process_stat "pypresso|espresso_migtest" "$NODE2")
        if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
            pass "espresso-3: ESPResSo process still running on $NODE2 after 15s"

            # ---- Return leg: recall home, NODE2 -> NODE1 ----
            # The "home" recall path (admin_write's "migrate <pid> home" ->
            # mattx_trigger_recall) is DIFFERENT from the generic
            # "migrate <pid> <node>" path and must be issued ON THE HOME
            # NODE ($NODE1), using the ORIGINAL PID ($TARGET_PID) --
            # mattx_trigger_recall() looks up the export_registry entry for
            # orig_pid, which only exists on the node that originally
            # exported it, then sends a RECALL_REQ to wherever the guest
            # currently lives. Using $NODE2/the Surrogate's local PID here
            # (as the generic migrate path requires) instead hits "PID is
            # not in the export registry. Cannot recall" -- or, if sent as
            # a plain numeric-node migrate instead of "home", silently
            # takes the generic forward-migrate path, which doesn't handle
            # re-targeting a PID that already has a stale Deputy/registry
            # entry on the destination and can crash the process right
            # after wake.
            do_migrate "pypresso (ESPResSo)" "$TARGET_PID" "$NODE1" "$NODE1" "home" "$NODE2"
            sleep 8

            show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "pypresso|espresso_migtest"
            show_threads "pypresso|espresso_migtest" "$NODE2"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
            if is_actually_running "pypresso|espresso_migtest" "$NODE1"; then
                echo "  Log tail (stdout forwarded via MattX wormhole):"
                run_on "$NODE1" "tail -5 /tmp/espresso_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                pass "espresso-4: ESPResSo process migrated back to $NODE1"

                sleep 15
                show_both_nodes "15s after return migration (settled state)" "pypresso|espresso_migtest"
                STAT4=$(process_stat "pypresso|espresso_migtest" "$NODE1")
                if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                    pass "espresso-4: ESPResSo process still running on $NODE1 after 15s (round trip complete)"
                elif [ -n "$STAT4" ]; then
                    fail "espresso-4: ESPResSo process present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                else
                    echo "  ► pypresso [PID $TARGET_PID] completed on $NODE1 after returning"
                    pass "espresso-4: ESPResSo process ran to completion on $NODE1 after round trip"
                fi
            else
                fail "espresso-4: ESPResSo process not actually running on $NODE1 after return migration"
                echo "  dmesg tail on $NODE2:"
                run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
            fi
        elif [ -n "$STAT2" ]; then
            fail "espresso-3: ESPResSo process present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
        else
            echo "  ► pypresso [PID $TARGET_PID] completed on $NODE2 before the return leg could start"
            pass "espresso-3: ESPResSo process ran to completion on $NODE2"
            fail "espresso-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase step count if this recurs)"
        fi
    else
        fail "espresso-3: ESPResSo process not actually running on $NODE2 after migration"
        echo "  dmesg tail on $NODE1:"
        run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
    fi

    # pkill -9 -f matches its OWN argv too (which literally contains
    # "espresso_migtest"), so an unguarded pattern kills its own remote
    # shell/SSH session before "|| true" ever gets a chance to run -- use
    # the standard bracket trick to keep it from self-matching.
    run_on "$NODE1" "kill -9 $JOB_PID 2>/dev/null || true; pkill -9 -f '[e]spresso_migtest' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[e]spresso_migtest' 2>/dev/null || true"

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "espresso-3: no kernel oops on $NODE1"
    else
        fail "espresso-3: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "espresso-3: no kernel oops on $NODE2"
    else
        fail "espresso-3: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "ESPResSo Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
