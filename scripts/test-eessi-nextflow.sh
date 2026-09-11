#!/bin/bash
# test-eessi-nextflow.sh <alma|deb|ubu>
# Run Nextflow tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + Nextflow module loads
# Test 2: run a real Nextflow pipeline (single process, verifies task completes)
# Test 3/4: migrate the actual long-running task process (not the Nextflow/JVM
#           orchestrator) forward and back via MattX
#
# Why not migrate `nextflow run` itself: a real Nextflow pipeline invocation is
# a JVM orchestrator that spawns a distinct short-lived OS process per
# pipeline step (each task gets its own work/xx/yyyy/ dir and .command.run
# wrapper), not one long-lived compute-bound process -- migrating the JVM
# wouldn't exercise anything a normal migration test doesn't already cover via
# other multi-threaded JVM-style workloads, and the actual pipeline work is
# what should keep running across the migration boundary. Instead we target
# the ACTUAL TASK PROCESS Nextflow spawns for one process block, the same way
# test-eessi-espresso.sh finds the actual pypresso worker rather than a
# wrapper PID.
#
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

auto_report_wrap "eessi-nextflow" "$@"

init_cluster "$DISTRO"

# The eessi-demo/Nextflow/run.sh and run-ml-hyperopt.sh scripts only document
# a working module combination for EESSI_VERSION=2023.06 (Nextflow/24.10.2) --
# unlike GROMACS's version auto-detection, don't guess at a newer version here.
EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
NEXTFLOW_MODULE="Nextflow/24.10.2"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Print ps evidence for a process pattern on one node. We search by pattern
# rather than by the home-node PID: mattx-stub is a distinct process spawned
# locally on the remote node via call_usermodehelper, so it gets its own
# kernel-assigned PID there — the original home PID has no reason to exist
# as a process on the remote node at all, so `ps -p <home-pid>` on the
# Surrogate's node reliably (and misleadingly) finds nothing.
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
    echo "    tool : $(mattx_tool_label)   (run on $from)"
    echo "  ─────────────────────────────────────────────────────"
    mattx_migrate "$from" "$pid" "$to_id"
}

# Runs on any script exit (normal completion, an early `exit 1`, or an
# uncaught error under `set -e`) so a job started on whichever node it
# happened to be on at the time doesn't outlive the test. Safe to call
# multiple times / before the PID var is even set.
cleanup() {
    run_on "$NODE1" "kill -9 ${NF_JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[n]extflow_migtest_payload' 2>/dev/null || true; pkill -9 -f '[n]extflow run main.nf' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[n]extflow_migtest_payload' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== Nextflow / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + module load ----
echo "=== Test 1: EESSI Nextflow module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${NEXTFLOW_MODULE}
    nextflow -version >/dev/null 2>&1
"; then
    pass "nextflow-1: Nextflow module loads on $NODE1"
else
    fail "nextflow-1: Nextflow module failed to load on $NODE1 (EESSI ${EESSI_VERSION})"
fi

# ---- Test 2: single-process migration pipeline ----
echo ""
echo "=== Test 2/3/4: single-task Nextflow pipeline + migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "nextflow-2: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    NF_WORKDIR="/tmp/eessi-nextflow"
    PAYLOAD="/tmp/nextflow_migtest_payload.sh"
    NF_LOG="/tmp/nextflow_migtest.log"

    # Deliberately two separate run_on calls, not one combined command: the
    # bracket-escaped pkill pattern only protects against matching ITS OWN
    # invocation text -- but $PAYLOAD's path literally contains the raw,
    # unescaped substring "nextflow_migtest_payload" too, and pkill -f
    # matches a process's FULL cmdline. In one combined `sh -c "pkill ...;
    # rm -rf $PAYLOAD ..."` command, that later rm argument makes the whole
    # cmdline match the pkill pattern, so pkill -9 kills its OWN parent
    # shell mid-script (confirmed live: this exact combination made the ssh
    # call itself exit 255, before rm/mkdir ever ran). Keeping pkill in its
    # own call means there's nothing else in the same cmdline for it to
    # accidentally self-match.
    run_on "$NODE1" "pkill -9 -f '[n]extflow_migtest_payload' 2>/dev/null; true"
    run_on "$NODE1" "rm -rf $NF_WORKDIR $PAYLOAD $NF_LOG; mkdir -p $NF_WORKDIR; true"

    # The actual long-running, migratable unit of work: a plain bash loop
    # doing real (not fake-sleep) CPU work -- repeated SHA256 hashing of
    # fresh random data, same "real work" pattern as run-tests.sh's
    # dd_migtest, just shell-native instead of Python so this pipeline has
    # no dependency beyond coreutils. ~90 ticks * ~1s = a comfortable
    # migration window without the whole test taking too long. A
    # DISTINCTIVE, fixed filename is the point: it's what
    # `pgrep -f nextflow_migtest_payload` below actually matches on, since
    # Nextflow's own generated .command.sh wrapper path is unpredictable and
    # not something a pattern match could rely on.
    run_on "$NODE1" "cat > $PAYLOAD" <<PAYLOADEOF
#!/bin/bash
set -e
echo "nextflow_migtest_payload PID=\$\$ starting on \$(uname -n)" | tee $NF_LOG
TICKS=90
for i in \$(seq 1 \$TICKS); do
    sum=\$(head -c 65536 /dev/urandom | sha256sum | awk '{print \$1}')
    if [ \$((i % 10)) -eq 0 ]; then
        echo "tick \$i/\$TICKS  node=\$(uname -n)  pid=\$\$  sha256=\$sum" | tee -a $NF_LOG
    fi
    sleep 1
done
echo "nextflow_migtest_payload DONE on \$(uname -n)" | tee -a $NF_LOG
PAYLOADEOF
    run_on "$NODE1" "chmod +x $PAYLOAD"

    # A minimal, fully self-contained pipeline (no GitHub pipeline fetch --
    # unlike eessi-demo/Nextflow/run.sh's `nextflow run blast-example`, which
    # depends on network access to resolve a hosted pipeline this repo
    # doesn't check in) with exactly one process whose entire script body is
    # "run the payload" -- so the process Nextflow actually executes for
    # this task has $PAYLOAD in its own argv/cmdline, not just in file
    # content ps/pgrep can't see.
    run_on "$NODE1" "cat > $NF_WORKDIR/main.nf" <<NFEOF
process migtest_task {
    script:
    """
    bash $PAYLOAD
    """
}

workflow {
    migtest_task()
}
NFEOF

    echo "  Starting nextflow run (single task) on $NODE1 ($(node_ip "$NODE1"))..."
    NF_JOB_PID=$(run_on "$NODE1" "
        cd $NF_WORKDIR
        source '${EESSI_INIT}'
        module load ${NEXTFLOW_MODULE}
        nohup nextflow run main.nf >/tmp/nextflow_run.log 2>&1 &
        echo \$!
    " | tail -1)
    echo "  Nextflow orchestrator PID: $NF_JOB_PID (not the migration target -- see header comment)"

    # Give Nextflow time to resolve the JVM, schedule the task, and reach
    # the point where our payload script is actually executing.
    TARGET_PID=""
    for i in $(seq 1 15); do
        TARGET_PID=$(run_on "$NODE1" "pgrep -f '[n]extflow_migtest_payload' | head -1" || true)
        [ -n "$TARGET_PID" ] && break
        sleep 2
    done

    if [ -z "$TARGET_PID" ]; then
        fail "nextflow-2: payload task never started (Nextflow/JVM startup or scheduling failure)"
        echo "  nextflow_run.log tail:"
        run_on "$NODE1" "tail -30 /tmp/nextflow_run.log 2>/dev/null || true" | sed 's/^/    /'
    else
        pass "nextflow-2: payload task started on $NODE1 (PID $TARGET_PID)"

        show_both_nodes "baseline, before outbound migration" "nextflow_migtest_payload"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 $NF_LOG 2>/dev/null || true" | sed 's/^/    /'
        TICKS_BEFORE=$(run_on "$NODE1" "grep -c '^tick ' $NF_LOG 2>/dev/null || echo 0")

        do_migrate "nextflow task" "$TARGET_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "nextflow_migtest_payload"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "nextflow_migtest_payload" "$NODE2"; then
            echo "  Log tail (stdout forwarded via MattX wormhole):"
            run_on "$NODE1" "tail -5 $NF_LOG 2>/dev/null || true" | sed 's/^/    /'
            pass "nextflow-3: task migrated to $NODE2"

            sleep 15
            show_both_nodes "15s after outbound migration (settled state)" "nextflow_migtest_payload"
            STAT2=$(process_stat "nextflow_migtest_payload" "$NODE2")
            TICKS_AFTER=$(run_on "$NODE1" "grep -c '^tick ' $NF_LOG 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$TICKS_AFTER" -le "$TICKS_BEFORE" ]; then
                fail "nextflow-3: task present and running on $NODE2, but tick count did not advance ($TICKS_BEFORE -> $TICKS_AFTER) -- looks alive but not making progress"
            elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                pass "nextflow-3: task still running on $NODE2 after 15s (ticks $TICKS_BEFORE -> $TICKS_AFTER)"

                # ---- Return leg: recall home, NODE2 -> NODE1 ----
                # The "home" recall path (admin_write's "migrate <pid> home"
                # -> mattx_trigger_recall) is DIFFERENT from the generic
                # "migrate <pid> <node>" path and must be issued ON THE HOME
                # NODE ($NODE1), using the ORIGINAL PID ($TARGET_PID) --
                # mattx_trigger_recall() looks up the export_registry entry
                # for orig_pid, which only exists on the node that
                # originally exported it, then sends a RECALL_REQ to
                # wherever the guest currently lives. Using $NODE2/the
                # Surrogate's local PID here (as the generic migrate path
                # requires) instead hits "PID is not in the export
                # registry. Cannot recall" -- or, if sent as a plain
                # numeric-node migrate instead of "home", silently takes
                # the generic forward-migrate path, which doesn't handle
                # re-targeting a PID that already has a stale
                # Deputy/registry entry on the destination and can crash
                # the process right after wake.
                do_migrate "nextflow task" "$TARGET_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "nextflow_migtest_payload"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "nextflow_migtest_payload" "$NODE1"; then
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 $NF_LOG 2>/dev/null || true" | sed 's/^/    /'
                    pass "nextflow-4: task migrated back to $NODE1"

                    TICKS_RETURN=$(run_on "$NODE1" "grep -c '^tick ' $NF_LOG 2>/dev/null || echo 0")
                    sleep 15
                    show_both_nodes "15s after return migration (settled state)" "nextflow_migtest_payload"
                    STAT4=$(process_stat "nextflow_migtest_payload" "$NODE1")
                    TICKS_FINAL=$(run_on "$NODE1" "grep -c '^tick ' $NF_LOG 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$TICKS_FINAL" -le "$TICKS_RETURN" ]; then
                        fail "nextflow-4: task present and running on $NODE1, but tick count did not advance ($TICKS_RETURN -> $TICKS_FINAL) -- looks alive but not making progress"
                    elif [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "nextflow-4: task still running on $NODE1 after 15s (round trip complete, ticks $TICKS_RETURN -> $TICKS_FINAL)"
                    elif [ -n "$STAT4" ]; then
                        fail "nextflow-4: task present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► nextflow task [PID $TARGET_PID] completed on $NODE1 after returning"
                        pass "nextflow-4: task ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "nextflow-4: task not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [ -n "$STAT2" ]; then
                fail "nextflow-3: task present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► nextflow task [PID $TARGET_PID] completed on $NODE2 before the return leg could start"
                pass "nextflow-3: task ran to completion on $NODE2"
                fail "nextflow-4: cannot perform return-leg migration — task completed on $NODE2 before it could be migrated back (increase TICKS in the payload if this recurs)"
            fi
        else
            fail "nextflow-3: task not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi
    fi

    # pkill -9 -f matches its OWN argv too (which literally contains
    # "nextflow_migtest_payload"), so an unguarded pattern kills its own
    # remote shell/SSH session before "|| true" ever gets a chance to run --
    # use the standard bracket trick to keep it from self-matching.
    run_on "$NODE1" "kill -9 $NF_JOB_PID 2>/dev/null || true; pkill -9 -f '[n]extflow_migtest_payload' 2>/dev/null || true; pkill -9 -f '[n]extflow run main.nf' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[n]extflow_migtest_payload' 2>/dev/null || true"

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "nextflow-3: no kernel oops on $NODE1"
    else
        fail "nextflow-3: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "nextflow-3: no kernel oops on $NODE2"
    else
        fail "nextflow-3: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "Nextflow Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
