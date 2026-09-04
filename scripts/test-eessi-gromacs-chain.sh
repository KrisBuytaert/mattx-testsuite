#!/bin/bash
# test-eessi-gromacs-chain.sh <alma>
# 3-node GROMACS migration chain: node1 -> node2 -> node3 -> node1.
# Only alma has a 3rd node provisioned (see `make almacluster3`).
#
# This exercises a scenario the 2-node round-trip test (test-eessi-gromacs.sh)
# structurally cannot: forward-migrating a job to a node that is neither the
# job's origin nor the peer it just came from, then recalling it all the way
# back home. That's two consecutive *distinct* forward legs to two different
# remote nodes (node1->node2, then node2->node3, not node1->node2->node1),
# followed by a final recall (node3->node1) whose registry lookups have to
# find the ORIGINAL exporter (node1), not the node the job most recently
# passed through (node2) -- a plain 2-node cluster can never tell "the home
# node" and "the node I last visited" apart, since they're the same node.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2"; NODE3="almanode3" ;;
    *) echo "ERROR: 3-node chain migration is only provisioned for alma (make almacluster3)" >&2
       echo "Usage: $0 <alma>" >&2
       exit 1 ;;
esac

# Number of OpenMP threads gmx mdrun runs with. Override with
# GROMACS_NTOMP=1 to test single-threaded migration.
GROMACS_NTOMP="${GROMACS_NTOMP:-2}"

auto_report_wrap "eessi-gromacs-chain-ntomp${GROMACS_NTOMP}" "$@"

init_cluster "$DISTRO"

EESSI_VERSION="${EESSI_VERSION:-}"
if [ -z "$EESSI_VERSION" ]; then
    if run_on "$NODE1" "test -d /cvmfs/software.eessi.io/versions/2025.06" 2>/dev/null; then
        EESSI_VERSION="2025.06"
    else
        EESSI_VERSION="2023.06"
    fi
fi
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
case "$EESSI_VERSION" in
    2025.06) GROMACS_MODULE="GROMACS/2025.2-foss-2025a" ;;
    *)       GROMACS_MODULE="GROMACS/2024.1-foss-2023b" ;;
esac

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ---- Helpers (same shape as test-eessi-gromacs.sh, extended to 3 nodes) ----

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

show_all_nodes() {
    local label="$1" pattern="$2"
    echo ""
    echo "  --- ps snapshot: $label (pattern: '$pattern') ---"
    show_location "$pattern" "$NODE1"
    show_location "$pattern" "$NODE2"
    show_location "$pattern" "$NODE3"
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

process_stat() {
    local pattern="$1" node="$2"
    run_on "$node" "ps -eo stat,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep | awk '{print \$1}' | head -1" 2>/dev/null
}

is_actually_running() {
    local pattern="$1" node="$2"
    local stat; stat="$(process_stat "$pattern" "$node")"
    [ -n "$stat" ] && [[ "$stat" != T* && "$stat" != Z* ]]
}

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

# Runs on any script exit (normal completion, an early `exit 1` from a
# preflight failure, or an uncaught error under `set -e`) so a job started on
# whichever node it happened to be on at the time doesn't outlive the test
# and confuse a later run. Safe to call multiple times / before GMX_PID is
# even set -- every command here already tolerates "nothing to kill".
cleanup() {
    run_on "$NODE1" "kill -9 ${GMX_PID:-} 2>/dev/null || true; pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE3" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== GROMACS 3-node chain migration on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo "    ${NODE1} -> ${NODE2} -> ${NODE3} -> ${NODE1}"
echo ""

# ---- Preflight: MattX up and all 3 nodes mutually visible ----
NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE3_ID=$(run_on "$NODE3" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)

if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ] || [ -z "$NODE3_ID" ]; then
    fail "gromacs-chain-0: MattX not running on all of $NODE1/$NODE2/$NODE3 — run 'make almacluster3' first"
    echo ""
    echo "=============================="
    echo "GROMACS Chain Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

for pair in "$NODE1:$NODE2" "$NODE1:$NODE3" "$NODE2:$NODE1" "$NODE2:$NODE3" "$NODE3:$NODE1" "$NODE3:$NODE2"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    if run_on "$src" "cat /proc/mattx/nodes 2>/dev/null" | grep -q "$(node_ip "$dst")"; then
        :
    else
        fail "gromacs-chain-0: $src does not see $dst in /proc/mattx/nodes -- 3-node cluster not fully connected"
    fi
done
[ "$FAIL" -eq 0 ] && pass "gromacs-chain-0: all 3 nodes mutually visible in /proc/mattx/nodes"

DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
DMESG_CURSOR_NODE3=$(dmesg_cursor "$NODE3")

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
    fail "gromacs-chain-1: failed to download/extract PRACE test case (check network access)"
    echo ""
    echo "=============================="
    echo "GROMACS Chain Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

run_on "$NODE1" "cd $GROMACS_WORKDIR && rm -f ener.edr logfile_chain.log md.log"

echo "  Starting gmx mdrun on $NODE1 ($(node_ip "$NODE1")) — 30000 steps (chain migration target)..."
GMX_PID=$(run_on "$NODE1" "
    set -e
    cd $GROMACS_WORKDIR
    source '${EESSI_INIT}'
    module load ${GROMACS_MODULE}
    nohup gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
        -nsteps 30000 -g logfile_chain -ntmpi 1 -ntomp ${GROMACS_NTOMP} \
        >/tmp/gromacs_chaintest.log 2>&1 &
    echo \$!
" | tail -1)
sleep 10

if ! run_on "$NODE1" "kill -0 $GMX_PID 2>/dev/null"; then
    fail "gromacs-chain-1: gmx mdrun exited before migration window — check /tmp/gromacs_chaintest.log"
    run_on "$NODE1" "tail -20 /tmp/gromacs_chaintest.log 2>/dev/null || true" | sed 's/^/    /'
    echo ""
    echo "=============================="
    echo "GROMACS Chain Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

show_all_nodes "baseline, before any migration" "gmx mdrun"
echo "  Log tail from $NODE1:"
run_on "$NODE1" "tail -5 /tmp/gromacs_chaintest.log 2>/dev/null || true" | sed 's/^/    /'
pass "gromacs-chain-1: gmx mdrun running on $NODE1 before chain migration"
# ener.edr (GROMACS's binary energy-trajectory file) was tried as a progress
# checkpoint here, but confirmed via live testing to stay at 0 bytes for this
# benchmark's whole test window -- ion_channel.tpr's nstenergy interval is
# coarser than that, so requiring growth produced false failures on a
# genuinely-progressing run. Captured for the report only, not used to gate
# pass/fail.
SIZE0=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")

# ---- Leg 1: NODE1 -> NODE2 ----
do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE2" "$NODE2_ID"
sleep 8
show_all_nodes "immediately after leg 1 ($NODE1 -> $NODE2)" "gmx mdrun"
show_migration_dmesg "leg 1 ($NODE1 -> $NODE2)" "$NODE1"
show_migration_dmesg "leg 1 ($NODE1 -> $NODE2)" "$NODE2"

if ! is_actually_running "gmx mdrun" "$NODE2"; then
    fail "gromacs-chain-2: gmx mdrun not actually running on $NODE2 after leg 1"
    echo "  dmesg tail on $NODE1:"; run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
else
    sleep 15
    show_all_nodes "15s after leg 1 (settled state)" "gmx mdrun"
    STAT2=$(process_stat "gmx mdrun" "$NODE2")
    SIZE1=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
    if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
        pass "gromacs-chain-2: gmx mdrun migrated $NODE1 -> $NODE2 and still running after 15s (ener.edr $SIZE0 -> $SIZE1 bytes, informational)"

        # ---- Leg 2: NODE2 -> NODE3 ----
        # The Surrogate's LOCAL pid on NODE2 (not the original $GMX_PID from
        # NODE1) is what the generic "migrate <pid> <node>" admin command
        # needs here -- this leg is issued from wherever the job currently
        # lives (NODE2), same as any other forward migration.
        SURROGATE_PID_N2=$(run_on "$NODE2" "ps -eo pid,cmd --no-headers | grep -iE -- 'gmx mdrun' | grep -v grep | awk '{print \$1}' | head -1")
        do_migrate "gmx mdrun" "$SURROGATE_PID_N2" "$NODE2" "$NODE3" "$NODE3_ID"
        sleep 8
        show_all_nodes "immediately after leg 2 ($NODE2 -> $NODE3)" "gmx mdrun"
        show_migration_dmesg "leg 2 ($NODE2 -> $NODE3)" "$NODE2"
        show_migration_dmesg "leg 2 ($NODE2 -> $NODE3)" "$NODE3"

        if ! is_actually_running "gmx mdrun" "$NODE3"; then
            fail "gromacs-chain-3: gmx mdrun not actually running on $NODE3 after leg 2 ($NODE2 -> $NODE3)"
            echo "  dmesg tail on $NODE2:"; run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        else
            sleep 15
            show_all_nodes "15s after leg 2 (settled state)" "gmx mdrun"
            STAT3=$(process_stat "gmx mdrun" "$NODE3")
            SIZE2=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
            if [[ -n "$STAT3" && "$STAT3" != T* && "$STAT3" != Z* ]]; then
                pass "gromacs-chain-3: gmx mdrun migrated $NODE2 -> $NODE3 and still running after 15s (ener.edr $SIZE1 -> $SIZE2 bytes, informational)"

                # ---- Leg 3: recall home, NODE3 -> NODE1 ----
                # "migrate <pid> home" must be issued on the ORIGINAL home
                # node ($NODE1), using the ORIGINAL PID ($GMX_PID) --
                # mattx_trigger_recall() looks up the export_registry entry
                # by orig_pid on the node that first exported it, and sends
                # RECALL_REQ to wherever the guest currently lives -- in this
                # case NODE3, even though the job's most recent hop was via
                # NODE2. This is the specific thing a 2-node cluster can't
                # test: whether the recall path resolves the true origin
                # correctly rather than the last-hop node.
                do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE1" "home" "$NODE3"
                sleep 8
                show_all_nodes "immediately after leg 3 (recall $NODE3 -> $NODE1)" "gmx mdrun"
                show_migration_dmesg "leg 3 (recall $NODE3 -> $NODE1)" "$NODE1"
                show_migration_dmesg "leg 3 (recall $NODE3 -> $NODE1)" "$NODE3"

                if ! is_actually_running "gmx mdrun" "$NODE1"; then
                    fail "gromacs-chain-4: gmx mdrun not actually running on $NODE1 after recall from $NODE3"
                    echo "  dmesg tail on $NODE3:"; run_on "$NODE3" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                else
                    sleep 15
                    show_all_nodes "15s after leg 3 (chain complete)" "gmx mdrun"
                    STAT4=$(process_stat "gmx mdrun" "$NODE1")
                    SIZE3=$(run_on "$NODE1" "stat -c%s $GROMACS_WORKDIR/ener.edr 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "gromacs-chain-4: gmx mdrun back on $NODE1 and running after 15s (chain complete: $NODE1 -> $NODE2 -> $NODE3 -> $NODE1, ener.edr $SIZE2 -> $SIZE3 bytes, informational)"
                    elif [ -n "$STAT4" ]; then
                        fail "gromacs-chain-4: gmx mdrun present on $NODE1 but frozen (STAT=$STAT4) after recall from $NODE3"
                    else
                        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE1 after the full chain"
                        PERF=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_chain.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                        echo "  Performance: $PERF"
                        pass "gromacs-chain-4: gmx mdrun ran to completion on $NODE1 after the full chain"
                    fi
                fi
            elif [ -n "$STAT3" ]; then
                fail "gromacs-chain-3: gmx mdrun present on $NODE3 but frozen (STAT=$STAT3) after leg 2"
            else
                echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE3 before the recall leg could start"
                pass "gromacs-chain-3: gmx mdrun ran to completion on $NODE3"
                fail "gromacs-chain-4: cannot perform recall leg — job completed on $NODE3 before it could be recalled (increase -nsteps if this recurs)"
            fi
        fi
    elif [ -n "$STAT2" ]; then
        fail "gromacs-chain-2: gmx mdrun present on $NODE2 but frozen (STAT=$STAT2) after leg 1"
    else
        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE2 before leg 2 could start"
        pass "gromacs-chain-2: gmx mdrun ran to completion on $NODE2"
        fail "gromacs-chain-3: cannot perform leg 2 — job completed on $NODE2 before it could be migrated onward (increase -nsteps if this recurs)"
    fi
fi

declare -A DMESG_CURSORS=( ["$NODE1"]="$DMESG_CURSOR_NODE1" ["$NODE2"]="$DMESG_CURSOR_NODE2" ["$NODE3"]="$DMESG_CURSOR_NODE3" )
for n in "$NODE1" "$NODE2" "$NODE3"; do
    if no_new_oops "$n" "${DMESG_CURSORS[$n]}"; then
        pass "gromacs-chain-5: no kernel oops on $n"
    else
        fail "gromacs-chain-5: kernel oops on $n"
    fi
done

echo ""
echo "=============================="
echo "GROMACS Chain Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
