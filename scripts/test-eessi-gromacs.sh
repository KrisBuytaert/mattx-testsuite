#!/bin/bash
# test-eessi-gromacs.sh <alma|deb|ubu>
# Run GROMACS tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + GROMACS module loads
# Test 2: run ion_channel PRACE benchmark (1000 steps)
# Test 3: migrate a running gmx mdrun via MattX
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

# Number of OpenMP threads gmx mdrun runs with. Override with
# GROMACS_NTOMP=1 to test single-threaded migration (e.g. to isolate whether
# a failure is specific to multi-threaded "Gang" migration).
GROMACS_NTOMP="${GROMACS_NTOMP:-2}"

auto_report_wrap "eessi-gromacs-ntomp${GROMACS_NTOMP}" "$@"

init_cluster "$DISTRO"

# Prefer the newer EESSI version if available, fall back to 2023.06
EESSI_VERSION="${EESSI_VERSION:-}"
if [ -z "$EESSI_VERSION" ]; then
    if run_on "$NODE1" "test -d /cvmfs/software.eessi.io/versions/2025.06" 2>/dev/null; then
        EESSI_VERSION="2025.06"
    else
        EESSI_VERSION="2023.06"
    fi
fi
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
# multi-threaded job (e.g. gmx mdrun -ntomp N spawns N OpenMP worker threads
# under the same PID) can have its leader genuinely frozen by
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

echo "=== GROMACS / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + GROMACS module load ----
echo "=== Test 1: EESSI GROMACS module load ==="
case "$EESSI_VERSION" in
    2025.06) GROMACS_MODULE="GROMACS/2025.2-foss-2025a" ;;
    *)       GROMACS_MODULE="GROMACS/2024.1-foss-2023b" ;;
esac

if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${GROMACS_MODULE}
    gmx --version | head -3
"; then
    pass "gromacs-1: GROMACS module (${GROMACS_MODULE}) loads on $NODE1"
else
    fail "gromacs-1: GROMACS module (${GROMACS_MODULE}) failed to load on $NODE1"
fi

# ---- Test 2: ion_channel PRACE benchmark ----
echo ""
echo "=== Test 2: GROMACS ion_channel benchmark (1000 steps) ==="

GROMACS_WORKDIR="/tmp/eessi-gromacs"
run_on "$NODE1" "mkdir -p $GROMACS_WORKDIR"

echo "  Fetching PRACE test case on $NODE1 (may take a minute)..."
if ! run_on "$NODE1" "
    set -e
    cd $GROMACS_WORKDIR
    if [ ! -f ion_channel.tpr ]; then
        if [ ! -f GROMACS_TestCaseA.tar.gz ]; then
            curl -fsSL -o GROMACS_TestCaseA.tar.gz \
                https://repository.prace-ri.eu/ueabs/GROMACS/1.2/GROMACS_TestCaseA.tar.gz
        fi
        tar xfz GROMACS_TestCaseA.tar.gz
    fi
    test -f ion_channel.tpr
" 2>&1; then
    fail "gromacs-2: failed to download/extract PRACE test case (check network access)"
    fail "gromacs-3: cannot run migration test without benchmark input"
    echo ""
    echo "=============================="
    echo "GROMACS Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

echo "  Running ion_channel benchmark on $NODE1 ($(node_ip "$NODE1")) — 1000 steps..."
if run_on "$NODE1" "
    set -e
    cd $GROMACS_WORKDIR
    rm -f ener.edr logfile.log md.log
    source '${EESSI_INIT}'
    module load ${GROMACS_MODULE}
    timeout 600 gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
        -nsteps 1000 -g logfile -ntmpi 1 -ntomp ${GROMACS_NTOMP}
    test -f logfile.log
" 2>&1; then
    PERF=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile.log || echo 'N/A'" || echo "N/A")
    pass "gromacs-2: ion_channel benchmark completed on $NODE1 ($PERF)"
else
    fail "gromacs-2: GROMACS benchmark failed or timed out on $NODE1"
fi

# ---- Test 3: gmx mdrun round-trip migration via MattX (NODE1 -> NODE2 -> NODE1) ----
echo ""
echo "=== Test 3: GROMACS round-trip migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "gromacs-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    run_on "$NODE1" "cd $GROMACS_WORKDIR && rm -f ener.edr logfile_mig.log md.log"

    echo "  Starting gmx mdrun on $NODE1 ($(node_ip "$NODE1")) — 20000 steps (round-trip migration target)..."
    # EESSI/Lmod init prints banner lines to stdout, so `echo $!` is not
    # necessarily the only line captured — take the last line to isolate it.
    GMX_PID=$(run_on "$NODE1" "
        set -e
        cd $GROMACS_WORKDIR
        source '${EESSI_INIT}'
        module load ${GROMACS_MODULE}
        nohup gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
            -nsteps 20000 -g logfile_mig -ntmpi 1 -ntomp ${GROMACS_NTOMP} \
            >/tmp/gromacs_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    if ! run_on "$NODE1" "kill -0 $GMX_PID 2>/dev/null"; then
        fail "gromacs-3: gmx mdrun exited before migration window — check /tmp/gromacs_migtest.log"
        run_on "$NODE1" "tail -20 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    else
        show_both_nodes "baseline, before outbound migration" "gmx mdrun"
        show_threads "gmx mdrun" "$NODE1"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'

        do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "gmx mdrun"
        show_threads "gmx mdrun" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "gmx mdrun" "$NODE2"; then
            echo "  Log tail (stdout forwarded via MattX wormhole):"
            run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
            pass "gromacs-3: gmx mdrun migrated to $NODE2"

            sleep 15
            show_both_nodes "15s after outbound migration (settled state)" "gmx mdrun"
            STAT2=$(process_stat "gmx mdrun" "$NODE2")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                pass "gromacs-3: gmx mdrun still running on $NODE2 after 15s"

                # ---- Return leg: migrate back NODE2 -> NODE1 ----
                # Must use the Surrogate's own LOCAL PID on $NODE2, not
                # $GMX_PID (the home node's PID) -- mattx-stub is a distinct
                # process with its own PID on the remote kernel, and
                # admin_write's "migrate <pid> <node>" path looks up <pid>
                # via pid_task() on whichever node it's sent to. Sending a
                # PID that doesn't exist there triggers a real kernel bug
                # (NULL-deref in admin_write, see mattx#8) rather than the
                # intended "PID not found" error.
                SURROGATE_PID=$(run_on "$NODE2" "ps -eo pid,cmd --no-headers | grep -iE -- 'gmx mdrun' | grep -v grep | awk '{print \$1}' | head -1")
                do_migrate "gmx mdrun" "$SURROGATE_PID" "$NODE2" "$NODE1" "$NODE1_ID"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "gmx mdrun"
                show_threads "gmx mdrun" "$NODE2"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "gmx mdrun" "$NODE1"; then
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                    pass "gromacs-4: gmx mdrun migrated back to $NODE1"

                    sleep 15
                    show_both_nodes "15s after return migration (settled state)" "gmx mdrun"
                    STAT4=$(process_stat "gmx mdrun" "$NODE1")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "gromacs-4: gmx mdrun still running on $NODE1 after 15s (round trip complete)"
                    elif [ -n "$STAT4" ]; then
                        fail "gromacs-4: gmx mdrun present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE1 after returning"
                        PERF3=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_mig.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                        echo "  Performance: $PERF3"
                        pass "gromacs-4: gmx mdrun ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "gromacs-4: gmx mdrun not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [ -n "$STAT2" ]; then
                fail "gromacs-3: gmx mdrun present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE2 before the return leg could start"
                PERF2=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_mig.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                echo "  Performance: $PERF2"
                pass "gromacs-3: gmx mdrun ran to completion on $NODE2"
                fail "gromacs-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase -nsteps if this recurs)"
            fi
        else
            fail "gromacs-3: gmx mdrun not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi

        run_on "$NODE1" "kill $GMX_PID 2>/dev/null || true; pkill gmx 2>/dev/null || true"
        run_on "$NODE2" "pkill gmx 2>/dev/null || true"
    fi

    if run_on "$NODE1" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "gromacs-4: kernel oops on $NODE1"
    else
        pass "gromacs-4: no kernel oops on $NODE1"
    fi
    if run_on "$NODE2" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "gromacs-4: kernel oops on $NODE2"
    else
        pass "gromacs-4: no kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "GROMACS Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
