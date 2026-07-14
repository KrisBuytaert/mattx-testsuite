#!/bin/bash
# test-eessi-gromacs.sh <alma|deb>
# Run GROMACS tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + GROMACS module loads
# Test 2: run ion_channel PRACE benchmark (1000 steps)
# Test 3: migrate a running gmx mdrun via MattX
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    *) echo "Usage: $0 <alma|deb>" >&2; exit 1 ;;
esac

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

# Print where a named process is currently running, with ps evidence.
show_location() {
    local name="$1" pid="$2" node="$3"
    local ip; ip="$(node_ip "$node")"
    echo "  ► $name [PID $pid] is running on $node ($ip):"
    run_on "$node" "ps -p $pid -o pid,user,stat,cmd --no-headers 2>/dev/null \
                    || ps aux | awk -v p=$pid '\$2==p{print \"   \"\$0}' \
                    || echo '   (not found in ps — may have already exited)'"
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
        -nsteps 1000 -g logfile -ntmpi 1 -ntomp 2
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
    GMX_PID=$(run_on "$NODE1" "
        set -e
        cd $GROMACS_WORKDIR
        source '${EESSI_INIT}'
        module load ${GROMACS_MODULE}
        nohup gmx mdrun -s ion_channel.tpr -maxh 0.50 -resethway -noconfout \
            -nsteps 20000 -g logfile_mig -ntmpi 1 -ntomp 2 \
            >/tmp/gromacs_migtest.log 2>&1 &
        echo \$!
    ")
    sleep 10

    if ! run_on "$NODE1" "kill -0 $GMX_PID 2>/dev/null"; then
        fail "gromacs-3: gmx mdrun exited before migration window — check /tmp/gromacs_migtest.log"
        run_on "$NODE1" "tail -20 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    else
        echo ""
        show_location "gmx mdrun" "$GMX_PID" "$NODE1"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'

        do_migrate "gmx mdrun" "$GMX_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        echo ""
        if run_on "$NODE2" "ps aux" | grep -q "[g]mx"; then
            show_location "gmx mdrun (Surrogate)" "$GMX_PID" "$NODE2"
            echo "  Log tail (stdout forwarded via MattX wormhole):"
            run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
            pass "gromacs-3: gmx mdrun migrated to $NODE2"

            sleep 15
            if run_on "$NODE2" "ps aux" | grep -q "[g]mx"; then
                show_location "gmx mdrun (Surrogate)" "$GMX_PID" "$NODE2"
                pass "gromacs-3: gmx mdrun still running on $NODE2 after 15s"

                # ---- Return leg: migrate back NODE2 -> NODE1 ----
                do_migrate "gmx mdrun" "$GMX_PID" "$NODE2" "$NODE1" "$NODE1_ID"
                sleep 8

                echo ""
                if run_on "$NODE1" "ps aux" | grep -q "[g]mx"; then
                    show_location "gmx mdrun (returned)" "$GMX_PID" "$NODE1"
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 /tmp/gromacs_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                    pass "gromacs-4: gmx mdrun migrated back to $NODE1"

                    sleep 15
                    if run_on "$NODE1" "ps aux" | grep -q "[g]mx"; then
                        show_location "gmx mdrun (returned)" "$GMX_PID" "$NODE1"
                        pass "gromacs-4: gmx mdrun still running on $NODE1 after 15s (round trip complete)"
                    else
                        echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE1 after returning"
                        PERF3=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_mig.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                        echo "  Performance: $PERF3"
                        pass "gromacs-4: gmx mdrun ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "gromacs-4: gmx mdrun not found on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            else
                echo "  ► gmx mdrun [PID $GMX_PID] completed on $NODE2 before the return leg could start"
                PERF2=$(run_on "$NODE1" "grep 'Performance:' $GROMACS_WORKDIR/logfile_mig.log 2>/dev/null || echo 'N/A'" || echo "N/A")
                echo "  Performance: $PERF2"
                pass "gromacs-3: gmx mdrun ran to completion on $NODE2"
                fail "gromacs-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase -nsteps if this recurs)"
            fi
        else
            fail "gromacs-3: gmx mdrun not found on $NODE2 after migration"
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
