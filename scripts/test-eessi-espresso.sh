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
show_threads() {
    local pattern="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    local cmd="ps -eLo pid,tid,ppid,user,stat,%cpu,wchan:24,comm --no-headers | grep -iE -- '$pattern' | grep -v grep"
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
do_migrate() {
    local name="$1" pid="$2" from="$3" to="$4" to_id="$5"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo "  Starting migration of $name [PID $pid]"
    echo "    from : $from ($(node_ip "$from"))"
    echo "    to   : $to   ($(node_ip "$to"))  [node ID $to_id]"
    echo "  ─────────────────────────────────────────────────────"
    run_on "$from" "echo 'migrate ${pid} ${to_id}' | sudo tee /proc/mattx/admin > /dev/null"
}

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

            # ---- Return leg: migrate back NODE2 -> NODE1 ----
            # Must use the Surrogate's own LOCAL PID on $NODE2, not
            # $TARGET_PID (the home node's PID) -- mattx-stub is a distinct
            # process with its own PID on the remote kernel, and
            # admin_write's "migrate <pid> <node>" path looks up <pid> via
            # pid_task() on whichever node it's sent to. Sending a PID that
            # doesn't exist there triggers a real kernel bug (NULL-deref in
            # admin_write, see mattx#8) rather than the intended "PID not
            # found" error.
            SURROGATE_PID=$(run_on "$NODE2" "ps -eo pid,cmd --no-headers | grep -iE -- 'pypresso|espresso_migtest' | grep -v grep | awk '{print \$1}' | head -1")
            do_migrate "pypresso (ESPResSo)" "$SURROGATE_PID" "$NODE2" "$NODE1" "$NODE1_ID"
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

    run_on "$NODE1" "kill $JOB_PID 2>/dev/null || true; pkill -f espresso_migtest 2>/dev/null || true"
    run_on "$NODE2" "pkill -f espresso_migtest 2>/dev/null || true"

    if run_on "$NODE1" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "espresso-3: kernel oops on $NODE1"
    else
        pass "espresso-3: no kernel oops on $NODE1"
    fi
    if run_on "$NODE2" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "espresso-3: kernel oops on $NODE2"
    else
        pass "espresso-3: no kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "ESPResSo Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
