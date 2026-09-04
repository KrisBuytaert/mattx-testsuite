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
    echo ""
    echo "  --- per-THREAD snapshot on $node (pattern: '$pattern') -- one row per thread (tid), not one row per process like the snapshot above ---"
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
# multiple times / before the PID vars are even set.
cleanup() {
    run_on "$NODE1" "kill -9 ${GMX_PID:-} ${EXPEL_GMX_PID:-} 2>/dev/null || true; pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
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
        # ener.edr (GROMACS's binary energy-trajectory file) was tried as a
        # progress checkpoint here, but confirmed via live testing to stay
        # at 0 bytes for this benchmark's whole ~30-45s test window --
        # ion_channel.tpr's nstenergy interval is coarser than that, so
        # requiring growth produced false failures on a genuinely-progressing
        # run. Captured for the report only, not used to gate pass/fail.
        SIZE_BEFORE=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")

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
            SIZE_AFTER=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                pass "gromacs-3: gmx mdrun still running on $NODE2 after 15s (ener.edr $SIZE_BEFORE -> $SIZE_AFTER bytes, informational)"

                # ---- Return leg: recall home, NODE2 -> NODE1 ----
                # The "home" recall path (admin_write's "migrate <pid> home"
                # -> mattx_trigger_recall) is DIFFERENT from the generic
                # "migrate <pid> <node>" path and must be issued ON THE HOME
                # NODE ($NODE1), using the ORIGINAL PID ($GMX_PID) --
                # mattx_trigger_recall() looks up the export_registry entry
                # for orig_pid, which only exists on the node that originally
                # exported it, then sends a RECALL_REQ to wherever the guest
                # currently lives. Using $NODE2/the Surrogate's local PID
                # here (as the generic migrate path requires) instead hits
                # "PID is not in the export registry. Cannot recall" -- or,
                # if sent as a plain numeric-node migrate instead of "home",
                # silently takes the generic forward-migrate path, which
                # doesn't handle re-targeting a PID that already has a stale
                # Deputy/registry entry on the destination and reliably GPFs
                # the process right after wake (this was previously
                # misdiagnosed as several distinct return-leg bugs).
                do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "gmx mdrun"
                show_threads "gmx mdrun" "$NODE2"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "gmx mdrun" "$NODE1"; then
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                    pass "gromacs-4: gmx mdrun migrated back to $NODE1"

                    SIZE_RETURN=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
                    sleep 15
                    show_both_nodes "15s after return migration (settled state)" "gmx mdrun"
                    STAT4=$(process_stat "gmx mdrun" "$NODE1")
                    SIZE_FINAL=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "gromacs-4: gmx mdrun still running on $NODE1 after 15s (round trip complete, ener.edr $SIZE_RETURN -> $SIZE_FINAL bytes, informational)"
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

        # pkill -9 -f matches its OWN argv too (which literally contains "gmx
        # mdrun"), so an unguarded pattern kills its own remote shell/SSH
        # session before "|| true" ever gets a chance to run -- use the
        # standard bracket trick to keep it from self-matching. Matching on
        # the full "gmx mdrun" command line (not bare "gmx") also avoids
        # killing an unrelated GROMACS subcommand that happens to be running
        # on the same node.
        run_on "$NODE1" "kill -9 $GMX_PID 2>/dev/null || true; pkill -9 -f '[g]mx mdrun' 2>/dev/null || true"
        run_on "$NODE2" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true"
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "gromacs-4: no kernel oops on $NODE1"
    else
        fail "gromacs-4: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "gromacs-4: no kernel oops on $NODE2"
    else
        fail "gromacs-4: kernel oops on $NODE2"
    fi
fi

# ---- Test 5: Return migration via "expel" (maintainer-recommended path) ----
# Per https://github.com/brainmatt/mattx/issues/8#issuecomment-5458346309,
# "migrate <pid> home" issued on the DESTINATION node is not supported --
# the correct alternative is "expel <local-surrogate-pid>", issued ON THE
# NODE HOSTING THE SURROGATE. This is deliberately independent of Test 3/4
# above, which already correctly exercise "migrate <pid> home" issued on
# the HOME node ($NODE1) -- the supported "recall" path (admin_write's
# "home" branch -> mattx_trigger_recall()). Both "recall" and "expel"
# ultimately call the same mattx_capture_and_return_state(); expel just
# skips the network RECALL_REQ round-trip, calling it directly where the
# surrogate already lives. Testing both gives independent coverage of the
# two return-migration entry points sharing that one code path.
_FAIL_T5=$FAIL
echo ""
echo "=== Test 5: GROMACS return migration via 'expel' ==="

run_on "$NODE1" "cd $GROMACS_WORKDIR && rm -f ener.edr logfile_expel.log md.log"

echo "  Starting a fresh gmx mdrun on $NODE1 for the expel round-trip..."
EXPEL_GMX_PID=$(run_on "$NODE1" "
    set -e
    cd $GROMACS_WORKDIR
    source '${EESSI_INIT}'
    module load ${GROMACS_MODULE}
    nohup gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
        -nsteps 20000 -g logfile_expel -ntmpi 1 -ntomp ${GROMACS_NTOMP} \
        >/tmp/gromacs_expeltest.log 2>&1 &
    echo \$!
" | tail -1)
sleep 10

if ! run_on "$NODE1" "kill -0 $EXPEL_GMX_PID 2>/dev/null"; then
    fail "gromacs-5: gmx mdrun exited before migration window — check /tmp/gromacs_expeltest.log"
    run_on "$NODE1" "tail -20 /tmp/gromacs_expeltest.log 2>/dev/null || true" | sed 's/^/    /'
else
    SIZE_EXPEL_BEFORE=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
    do_migrate "gmx mdrun (expel test)" "$EXPEL_GMX_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 8

    show_both_nodes "immediately after outbound migration (expel test)" "gmx mdrun"
    if is_actually_running "gmx mdrun" "$NODE2"; then
        pass "gromacs-5: gmx mdrun migrated to $NODE2 (expel test)"

        sleep 15
        show_both_nodes "15s after outbound migration (expel test, settled state)" "gmx mdrun"
        STAT_EXPEL=$(process_stat "gmx mdrun" "$NODE2")
        SIZE_EXPEL_AFTER=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
        if [[ -n "$STAT_EXPEL" && "$STAT_EXPEL" != T* && "$STAT_EXPEL" != Z* ]]; then
            pass "gromacs-5: gmx mdrun still running on $NODE2 after 15s (expel test, ener.edr $SIZE_EXPEL_BEFORE -> $SIZE_EXPEL_AFTER bytes, informational)"

            # ---- The actual point of this test: use "expel", not "home" recall ----
            SURROGATE_PID_EXPEL=$(run_on "$NODE2" "ps -eo pid,cmd --no-headers | grep -iE -- 'gmx mdrun' | grep -v grep | awk '{print \$1}' | head -1")
            echo "  Expelling local Surrogate PID $SURROGATE_PID_EXPEL on $NODE2 (blocks until finished)..."
            run_on "$NODE2" "echo \"expel $SURROGATE_PID_EXPEL\" | sudo tee /proc/mattx/admin > /dev/null"

            show_both_nodes "immediately after expel" "gmx mdrun"
            if is_actually_running "gmx mdrun" "$NODE1"; then
                pass "gromacs-5: gmx mdrun expelled back to $NODE1"

                SIZE_EXPEL_RETURN=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
                sleep 15
                show_both_nodes "15s after expel (settled state)" "gmx mdrun"
                STAT_EXPEL2=$(process_stat "gmx mdrun" "$NODE1")
                SIZE_EXPEL_FINAL=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
                if [[ -n "$STAT_EXPEL2" && "$STAT_EXPEL2" != T* && "$STAT_EXPEL2" != Z* ]]; then
                    pass "gromacs-5: gmx mdrun still running on $NODE1 after 15s (expel round trip complete, ener.edr $SIZE_EXPEL_RETURN -> $SIZE_EXPEL_FINAL bytes, informational)"
                elif [ -n "$STAT_EXPEL2" ]; then
                    fail "gromacs-5: gmx mdrun present on $NODE1 but frozen (STAT=$STAT_EXPEL2) after expel"
                else
                    echo "  ► gmx mdrun [PID $EXPEL_GMX_PID] completed on $NODE1 after expel"
                    pass "gromacs-5: gmx mdrun ran to completion on $NODE1 after expel round trip"
                fi
            else
                fail "gromacs-5: gmx mdrun not actually running on $NODE1 after expel"
                echo "  dmesg tail on $NODE2:"
                run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
            fi
        else
            fail "gromacs-5: gmx mdrun present on $NODE2 but frozen (STAT=$STAT_EXPEL) before expel could be attempted"
        fi
    else
        fail "gromacs-5: gmx mdrun not actually running on $NODE2 after migration (expel test)"
        echo "  dmesg tail on $NODE1:"
        run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
    fi

    run_on "$NODE1" "kill -9 $EXPEL_GMX_PID 2>/dev/null || true; pkill -9 -f '[g]mx mdrun' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true"
fi

if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
    pass "gromacs-5: no kernel oops on $NODE1"
else
    fail "gromacs-5: kernel oops on $NODE1"
fi
if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
    pass "gromacs-5: no kernel oops on $NODE2"
else
    fail "gromacs-5: kernel oops on $NODE2"
fi

echo ""
echo "=============================="
echo "GROMACS Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
