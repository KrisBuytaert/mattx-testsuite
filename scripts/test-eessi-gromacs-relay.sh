#!/bin/bash
# test-eessi-gromacs-relay.sh <alma>
# 3-node GROMACS "relay" migration: node1 -> node2 -> home -> node3 -> home.
# Only alma has a 3rd node provisioned (see `make almacluster3`).
#
# This is the OTHER way to move a job across three nodes, and the one the
# upstream author (Matt) says is the actually-supported one: never hop
# remote-to-remote directly (node2 -> node3, exercised by
# test-eessi-gromacs-chain.sh and confirmed broken -- see CHANGELOG.md
# "Known Issues"). Instead, always recall home before migrating anywhere
# else: node1->node2, node2->home(node1), node1->node3, node3->home(node1).
# Every individual hop here is either home->remote or remote->home -- the
# same single-hop shape test-eessi-gromacs.sh already validates -- so if
# MattX is correct, this should just work, without the stale-state
# resurrection bug the direct chain hits.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2"; NODE3="almanode3" ;;
    *) echo "ERROR: 3-node relay migration is only provisioned for alma (make almacluster3)" >&2
       echo "Usage: $0 <alma>" >&2
       exit 1 ;;
esac

# Number of OpenMP threads gmx mdrun runs with. Override with
# GROMACS_NTOMP=1 to test single-threaded migration.
GROMACS_NTOMP="${GROMACS_NTOMP:-2}"

auto_report_wrap "eessi-gromacs-relay-ntomp${GROMACS_NTOMP}" "$@"

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

# ---- Helpers (same shape as test-eessi-gromacs-chain.sh) ----

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

cpu_seconds() {
    # Cumulative CPU time (whole seconds) for a PID, via `ps -o cputimes`.
    # Used as a real progress signal across the two recall points (leg B
    # and leg D), both of which resurrect the SAME original task_struct
    # (GMX_PID) on NODE1 via mattx_import.c's "Welcome home" path -- kernel
    # process accounting is untouched by SIGSTOP/SIGCONT, so this value
    # can only go forward while genuinely running and must never drop.
    # A stale-state resurrection (as confirmed in the direct chain test)
    # would show up here as leg D's reading being <= leg B's, despite
    # ~45s of real running time (three 15s settle windows) in between --
    # not just a passing "is it running" check, which both the broken
    # chain test and this one would show regardless.
    local pid="$1"
    run_on "$NODE1" "ps -o cputimes= -p $pid 2>/dev/null | tr -d ' '" 2>/dev/null || true
}

# $6 (actual_from) is optional and only needed for the "home" recall path,
# where the admin command must be issued on the home node ($from) but the
# job is actually currently running somewhere else. Defaults to $from (the
# ordinary forward-migration case, where they're the same node).
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
    local rc=0
    mattx_migrate "$from" "$pid" "$to_id" || rc=$?
    return "$rc"
}

# Runs on any script exit so a job started on whichever node it happened to
# be on at the time doesn't outlive the test.
cleanup() {
    run_on "$NODE1" "kill -9 ${GMX_PID:-} 2>/dev/null || true; pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE3" "pkill -9 -f '[g]mx mdrun' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== GROMACS 3-node relay migration on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo "    ${NODE1} -> ${NODE2} -> home(${NODE1}) -> ${NODE3} -> home(${NODE1})"
echo ""

# ---- Preflight: MattX up and all 3 nodes mutually visible ----
NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE3_ID=$(run_on "$NODE3" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)

if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ] || [ -z "$NODE3_ID" ]; then
    fail "gromacs-relay-0: MattX not running on all of $NODE1/$NODE2/$NODE3 — run 'make almacluster3' first"
    echo ""
    echo "=============================="
    echo "GROMACS Relay Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

for pair in "$NODE1:$NODE2" "$NODE1:$NODE3" "$NODE2:$NODE1" "$NODE2:$NODE3" "$NODE3:$NODE1" "$NODE3:$NODE2"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    if run_on "$src" "cat /proc/mattx/nodes 2>/dev/null" | grep -q "$(node_ip "$dst")"; then
        :
    else
        fail "gromacs-relay-0: $src does not see $dst in /proc/mattx/nodes -- 3-node cluster not fully connected"
    fi
done
[ "$FAIL" -eq 0 ] && pass "gromacs-relay-0: all 3 nodes mutually visible in /proc/mattx/nodes"

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
    fail "gromacs-relay-1: failed to download/extract PRACE test case (check network access)"
    echo ""
    echo "=============================="
    echo "GROMACS Relay Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

run_on "$NODE1" "cd $GROMACS_WORKDIR && rm -f ener.edr logfile_relay.log md.log"

echo "  Starting gmx mdrun on $NODE1 ($(node_ip "$NODE1")) — 30000 steps (relay migration target)..."
GMX_PID=$(run_on "$NODE1" "
    set -e
    cd $GROMACS_WORKDIR
    source '${EESSI_INIT}'
    module load ${GROMACS_MODULE}
    nohup gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
        -nsteps 30000 -g logfile_relay -ntmpi 1 -ntomp ${GROMACS_NTOMP} \
        >/tmp/gromacs_relaytest.log 2>&1 &
    echo \$!
" | tail -1)
sleep 10

if ! run_on "$NODE1" "kill -0 $GMX_PID 2>/dev/null"; then
    fail "gromacs-relay-1: gmx mdrun exited before migration window — check /tmp/gromacs_relaytest.log"
    run_on "$NODE1" "tail -20 /tmp/gromacs_relaytest.log 2>/dev/null || true" | sed 's/^/    /'
    echo ""
    echo "=============================="
    echo "GROMACS Relay Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

show_all_nodes "baseline, before any migration" "gmx mdrun"
echo "  Log tail from $NODE1:"
run_on "$NODE1" "tail -5 /tmp/gromacs_relaytest.log 2>/dev/null || true" | sed 's/^/    /'
pass "gromacs-relay-1: gmx mdrun running on $NODE1 before relay migration"

echo "  Migration tool for this run: $(mattx_tool_label)"

# ---- Leg A: NODE1 -> NODE2 (forward) ----
LEGA_RC=0
do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE2" "$NODE2_ID" || LEGA_RC=$?
sleep 8
show_all_nodes "immediately after leg A ($NODE1 -> $NODE2)" "gmx mdrun"
show_migration_dmesg "leg A ($NODE1 -> $NODE2)" "$NODE1"
show_migration_dmesg "leg A ($NODE1 -> $NODE2)" "$NODE2"

if [ "$LEGA_RC" -ne 0 ]; then
    fail "gromacs-relay-2: admin command for $NODE1 -> $NODE2 failed (exit $LEGA_RC)"
elif ! is_actually_running "gmx mdrun" "$NODE2"; then
    fail "gromacs-relay-2: gmx mdrun not actually running on $NODE2 after leg A"
    echo "  dmesg tail on $NODE1:"; run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
else
    sleep 15
    show_all_nodes "15s after leg A (settled state)" "gmx mdrun"
    STAT_A=$(process_stat "gmx mdrun" "$NODE2")
    if [[ -n "$STAT_A" && "$STAT_A" != T* && "$STAT_A" != Z* ]]; then
        pass "gromacs-relay-2: gmx mdrun migrated $NODE1 -> $NODE2 and still running after 15s"

        # ---- Leg B: recall home, NODE2 -> NODE1 ----
        LEGB_RC=0
        do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE1" "home" "$NODE2" || LEGB_RC=$?
        sleep 8
        show_all_nodes "immediately after leg B (recall $NODE2 -> $NODE1)" "gmx mdrun"
        show_migration_dmesg "leg B (recall $NODE2 -> $NODE1)" "$NODE1"
        show_migration_dmesg "leg B (recall $NODE2 -> $NODE1)" "$NODE2"

        if [ "$LEGB_RC" -ne 0 ]; then
            fail "gromacs-relay-3: recall admin command for $NODE2 -> $NODE1 failed (exit $LEGB_RC)"
        elif ! is_actually_running "gmx mdrun" "$NODE1"; then
            fail "gromacs-relay-3: gmx mdrun not actually running on $NODE1 after recall from $NODE2"
            echo "  dmesg tail on $NODE2:"; run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        else
            sleep 15
            show_all_nodes "15s after leg B (settled state)" "gmx mdrun"
            STAT_B=$(process_stat "gmx mdrun" "$NODE1")
            CPU_B="$(cpu_seconds "$GMX_PID")"
            if [[ -n "$STAT_B" && "$STAT_B" != T* && "$STAT_B" != Z* ]]; then
                pass "gromacs-relay-3: gmx mdrun recalled $NODE2 -> $NODE1 and still running after 15s (cumulative CPU time so far: ${CPU_B:-unknown}s)"

                # ---- Leg C: NODE1 -> NODE3 (fresh forward from home) ----
                LEGC_RC=0
                do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE3" "$NODE3_ID" || LEGC_RC=$?
                sleep 8
                show_all_nodes "immediately after leg C ($NODE1 -> $NODE3)" "gmx mdrun"
                show_migration_dmesg "leg C ($NODE1 -> $NODE3)" "$NODE1"
                show_migration_dmesg "leg C ($NODE1 -> $NODE3)" "$NODE3"

                if [ "$LEGC_RC" -ne 0 ]; then
                    fail "gromacs-relay-4: admin command for $NODE1 -> $NODE3 failed (exit $LEGC_RC)"
                elif ! is_actually_running "gmx mdrun" "$NODE3"; then
                    fail "gromacs-relay-4: gmx mdrun not actually running on $NODE3 after leg C"
                    echo "  dmesg tail on $NODE1:"; run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                else
                    sleep 15
                    show_all_nodes "15s after leg C (settled state)" "gmx mdrun"
                    STAT_C=$(process_stat "gmx mdrun" "$NODE3")
                    if [[ -n "$STAT_C" && "$STAT_C" != T* && "$STAT_C" != Z* ]]; then
                        pass "gromacs-relay-4: gmx mdrun migrated $NODE1 -> $NODE3 and still running after 15s"

                        # ---- Leg D: recall home, NODE3 -> NODE1 ----
                        LEGD_RC=0
                        do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE1" "home" "$NODE3" || LEGD_RC=$?
                        sleep 8
                        show_all_nodes "immediately after leg D (recall $NODE3 -> $NODE1)" "gmx mdrun"
                        show_migration_dmesg "leg D (recall $NODE3 -> $NODE1)" "$NODE1"
                        show_migration_dmesg "leg D (recall $NODE3 -> $NODE1)" "$NODE3"

                        if [ "$LEGD_RC" -ne 0 ]; then
                            fail "gromacs-relay-5: recall admin command for $NODE3 -> $NODE1 failed (exit $LEGD_RC)"
                        elif ! is_actually_running "gmx mdrun" "$NODE1"; then
                            fail "gromacs-relay-5: gmx mdrun not actually running on $NODE1 after recall from $NODE3"
                            echo "  dmesg tail on $NODE3:"; run_on "$NODE3" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                        else
                            sleep 15
                            show_all_nodes "15s after leg D (relay complete)" "gmx mdrun"
                            STAT_D=$(process_stat "gmx mdrun" "$NODE1")
                            CPU_D="$(cpu_seconds "$GMX_PID")"
                            if [[ -n "$STAT_D" && "$STAT_D" != T* && "$STAT_D" != Z* ]]; then
                                if [ -n "$CPU_B" ] && [ -n "$CPU_D" ] && [ "$CPU_D" -le "$CPU_B" ] 2>/dev/null; then
                                    fail "gromacs-relay-5: gmx mdrun is back on $NODE1 and running, but its cumulative CPU time did NOT advance across leg C (leg B: ${CPU_B}s -> leg D: ${CPU_D}s, despite ~45s of real running time on $NODE2/$NODE3/$NODE1 in between) -- this is the stale-state resurrection bug, happening here too"
                                else
                                    pass "gromacs-relay-5: gmx mdrun back on $NODE1 and running after 15s (relay complete: $NODE1 -> $NODE2 -> home -> $NODE3 -> home, cumulative CPU time ${CPU_B}s -> ${CPU_D}s -- genuinely advanced, not resurrected)"
                                fi
                            elif [ -n "$STAT_D" ]; then
                                fail "gromacs-relay-5: gmx mdrun present on $NODE1 but frozen (STAT=$STAT_D) after recall from $NODE3"
                            else
                                echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE1 after the full relay"
                                PERF=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_relay.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                                echo "  Performance: $PERF"
                                pass "gromacs-relay-5: gmx mdrun ran to completion on $NODE1 after the full relay"
                            fi
                        fi
                    elif [ -n "$STAT_C" ]; then
                        fail "gromacs-relay-4: gmx mdrun present on $NODE3 but frozen (STAT=$STAT_C) after leg C"
                    else
                        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE3 before the recall leg could start"
                        pass "gromacs-relay-4: gmx mdrun ran to completion on $NODE3"
                        fail "gromacs-relay-5: cannot perform recall leg — job completed on $NODE3 before it could be recalled (increase -nsteps if this recurs)"
                    fi
                fi
            elif [ -n "$STAT_B" ]; then
                fail "gromacs-relay-3: gmx mdrun present on $NODE1 but frozen (STAT=$STAT_B) after recall from $NODE2"
            else
                echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE1 before leg C could start"
                pass "gromacs-relay-3: gmx mdrun ran to completion on $NODE1 (after recall from $NODE2)"
                fail "gromacs-relay-4: cannot perform leg C — job completed before it could be migrated onward (increase -nsteps if this recurs)"
            fi
        fi
    elif [ -n "$STAT_A" ]; then
        fail "gromacs-relay-2: gmx mdrun present on $NODE2 but frozen (STAT=$STAT_A) after leg A"
    else
        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE2 before leg B could start"
        pass "gromacs-relay-2: gmx mdrun ran to completion on $NODE2"
        fail "gromacs-relay-3: cannot perform leg B — job completed before it could be recalled (increase -nsteps if this recurs)"
    fi
fi

declare -A DMESG_CURSORS=( ["$NODE1"]="$DMESG_CURSOR_NODE1" ["$NODE2"]="$DMESG_CURSOR_NODE2" ["$NODE3"]="$DMESG_CURSOR_NODE3" )
for n in "$NODE1" "$NODE2" "$NODE3"; do
    if no_new_oops "$n" "${DMESG_CURSORS[$n]}"; then
        pass "gromacs-relay-6: no kernel oops on $n"
    else
        fail "gromacs-relay-6: kernel oops on $n"
    fi
done

echo ""
echo "=============================="
echo "GROMACS Relay Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
