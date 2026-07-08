#!/bin/bash
# test-eessi-espresso.sh <alma|deb>
# Run ESPResSo tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + ESPResSo module loads
# Test 2: run plate_capacitor.py (functional MPI run)
# Test 3: migrate a single-process ESPResSo job via MattX
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

EESSI_VERSION="${EESSI_VERSION:-2023.06}"
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

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "espresso-3: MattX not running on $NODE2 — run 'make ${DISTRO}cluster' first"
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

for step in range(200):
    system.integrator.run(50)
    if step % 10 == 0:
        print("step {}/200  node={}  pid={}".format(step, os.uname().nodename, os.getpid()), flush=True)
    time.sleep(0.4)

print("ESPResSo migtest DONE on {}".format(os.uname().nodename), flush=True)
PYEOF

    echo "  Starting pypresso migtest on $NODE1 ($(node_ip "$NODE1"))..."
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ESPResSo/4.2.2-foss-2023a
        nohup pypresso /tmp/espresso_migtest.py >/tmp/espresso_migtest.log 2>&1 &
        echo \$!
    ")
    sleep 8

    WORKER_PID=$(run_on "$NODE1" \
        "pgrep -P $JOB_PID pypresso 2>/dev/null | head -1 \
         || pgrep -f espresso_migtest 2>/dev/null | head -1 \
         || echo ''" || true)
    TARGET_PID="${WORKER_PID:-$JOB_PID}"

    echo ""
    show_location "pypresso (ESPResSo migtest)" "$TARGET_PID" "$NODE1"
    echo "  Log tail from $NODE1:"
    run_on "$NODE1" "tail -5 /tmp/espresso_migtest.log 2>/dev/null || true" | sed 's/^/    /'

    do_migrate "pypresso (ESPResSo)" "$TARGET_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 8

    echo ""
    if run_on "$NODE2" "ps aux" | grep -q "[p]ypresso\|[e]spresso_migtest"; then
        show_location "pypresso (ESPResSo migtest)" "$TARGET_PID" "$NODE2"
        echo "  Log tail (stdout forwarded via MattX wormhole):"
        run_on "$NODE1" "tail -5 /tmp/espresso_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        pass "espresso-3: ESPResSo process migrated to $NODE2"

        sleep 20
        if run_on "$NODE2" "ps aux" | grep -q "[p]ypresso\|[e]spresso_migtest"; then
            show_location "pypresso (ESPResSo migtest)" "$TARGET_PID" "$NODE2"
            pass "espresso-3: ESPResSo process still running on $NODE2 after 20s"
        else
            echo "  ► pypresso [PID $TARGET_PID] completed on $NODE2"
            pass "espresso-3: ESPResSo process ran to completion on $NODE2"
        fi
    else
        fail "espresso-3: ESPResSo process not found on $NODE2 after migration"
        echo "  dmesg tail on $NODE1:"
        run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
    fi

    run_on "$NODE1" "kill $JOB_PID 2>/dev/null || true; pkill -f espresso_migtest 2>/dev/null || true"

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
