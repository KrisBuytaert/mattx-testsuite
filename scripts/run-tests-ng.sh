#!/bin/bash
# run-tests.sh <alma|deb>
set -euo pipefail
DISTRO="${1:?Usage: $0 <alma|deb>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
esac

init_cluster "$DISTRO"

# ---- Repro functions (printed automatically when a test fails) --------------
repro_setup() {
    cat <<'SETUP'

  To reproduce manually, set these in your shell first:
    export MATTX_KEY="<path-to-test>/keys/mattx_test"
    # AlmaLinux: N1=192.168.100.11  N2=192.168.100.12
    # Debian:    N1=192.168.100.21  N2=192.168.100.22
    export N1=192.168.100.11
    export N2=192.168.100.12
    export SSH="ssh -i $MATTX_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mattx@"
    export N2_ID=$($SSH${N2} 'cat /proc/mattx/nodes' | awk '/\(Local\)/{print $1}')
SETUP
}

repro_test1() {
    cat <<'REPRO'

  ── Test 1 repro: forward migration + return ─────────────────────────────
    # 1. Start migtest; note the child PID
    $SSH${N1} 'migtest &>/tmp/migtest.log & sleep 2; pgrep -a migtest'
    export PID=<child-pid-from-above>

    # 2. Forward migration
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 3
    $SSH${N1} 'cat /proc/mattx/remote'       # expect: <PID>:<N2_ID>  (Deputy)
    $SSH${N2} 'ps aux | grep migtest'        # expect: running (Surrogate)

    # 3. Return migration
    $SSH${N1} "echo 'migrate $PID home' | sudo tee /proc/mattx/admin"; sleep 3
    $SSH${N1} 'ps aux | grep migtest'        # expect: back on node1

    # Cleanup + oops check
    $SSH${N1} "pkill migtest 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}

repro_test2() {
    cat <<'REPRO'

  ── Test 2 repro: network wormhole (servertestpoll) ──────────────────────
    # 1. Start server on node1
    $SSH${N1} 'servertestpoll &>/tmp/server.log & echo $!'
    export PID=<pid-from-above>

    # 2. Verify reachable from node2 before migration
    $SSH${N2} "nc -z $N1 8080 && echo reachable"

    # 3. Migrate to node2
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 5
    $SSH${N2} 'ps aux | grep servertestpoll'          # expect: Surrogate on node2

    # 4. Wormhole check: still serves on node1's IP after migration
    $SSH${N2} "nc -z $N1 8080 && echo wormhole-ok"

    # Cleanup + oops check
    $SSH${N1} "kill $PID 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}

repro_test3() {
    cat <<'REPRO'

  ── Test 3 repro: pingpong stress (5 cycles) ─────────────────────────────
    # 1. Start migtest on node1; note the child PID
    $SSH${N1} 'migtest &>/tmp/pingpong.log & sleep 2; pgrep migtest | tail -1'
    export PID=<child-pid-from-above>

    # 2. Repeat these 4 commands 5 times (one full cycle each):
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 6
    $SSH${N2} 'ps aux | grep migtest'        # expect: Surrogate on node2
    $SSH${N1} "echo 'migrate $PID home' | sudo tee /proc/mattx/admin"; sleep 6
    $SSH${N1} 'ps aux | grep migtest'        # expect: back on node1

    # 3. After all cycles, process must still be alive
    $SSH${N1} 'ps aux | grep migtest'

    # Cleanup + oops check
    $SSH${N1} "pkill migtest 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}
# -----------------------------------------------------------------------------

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ---- Diagnostic helpers ----

dump_log() {
    local node="$1" logfile="$2"
    echo "  [$node] $logfile:"
    run_on "$node" "cat '$logfile' 2>/dev/null || echo '  (empty or not found)'" \
        | sed 's/^/    /'
}

dump_proc_mattx() {
    local node="$1"
    for f in nodes guests remote; do
        echo "  [$node] /proc/mattx/$f:"
        run_on "$node" "cat /proc/mattx/$f 2>/dev/null || echo '  (not found)'" \
            | sed 's/^/    /'
    done
}

dump_dmesg() {
    local node="$1" lines="${2:-50}"
    echo "  [$node] dmesg (last $lines lines):"
    run_on "$node" "sudo dmesg | tail -$lines" | sed 's/^/    /'
}

check_no_oops() {
    local node="$1"
    local out
    out=$(run_on "$node" "sudo dmesg")
    if echo "$out" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "kernel oops on $node"
        echo "  [$node] oops context:"
        echo "$out" | grep -A 10 "Oops\|BUG: unable to handle\|kernel BUG" | sed 's/^/    /'
        return 1
    fi
    return 0
}

migrate() {
    local node="$1" pid="$2" target="$3"
    run_on "$node" "echo 'migrate ${pid} ${target}' | sudo tee /proc/mattx/admin > /dev/null"
}

# ---- Cleanup stale test processes ----
run_on "$NODE1" "pkill migtest 2>/dev/null || true"
run_on "$NODE2" "pkill migtest 2>/dev/null || true"
run_on "$NODE1" "pkill servertestpoll 2>/dev/null || true"
run_on "$NODE2" "pkill servertestpoll 2>/dev/null || true"
sleep 1

# ---- Pre-flight ----
echo "=== Pre-flight: cluster state ==="

# /proc/mattx/nodes marks the local node with "(Local)" on the same line.
# Format: "<id> (Local)\t<ip>\t<cpu>\t<mem>"
NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}') || {
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE1"
    dump_dmesg "$NODE1" 30
    exit 1
}
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}') || {
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE2"
    dump_dmesg "$NODE2" 30
    exit 1
}

[ -n "$NODE1_ID" ] || { fail "pre-flight: could not determine node ID for $NODE1"; dump_proc_mattx "$NODE1"; exit 1; }
[ -n "$NODE2_ID" ] || { fail "pre-flight: could not determine node ID for $NODE2"; dump_proc_mattx "$NODE2"; exit 1; }

run_on "$NODE1" "cat /proc/mattx/nodes" | grep -qw "$NODE2_ID" || {
    fail "pre-flight: $NODE1 (ID=$NODE1_ID) does not see $NODE2 (ID=$NODE2_ID) in cluster"
    dump_proc_mattx "$NODE1"
    dump_proc_mattx "$NODE2"
    dump_dmesg "$NODE1" 20
    dump_dmesg "$NODE2" 20
    exit 1
}
echo "cluster OK — $NODE1 ID=$NODE1_ID  $NODE2 ID=$NODE2_ID"

# ---- Test 1: Basic forward + return migration ----
_FAIL_T1=$FAIL
echo ""
echo "=== Test 1: Basic migration (migtest) ==="
MGR=$(run_on "$NODE1" "migtest &>/tmp/migtest.log & echo \$!")
sleep 2
PID=$(run_on "$NODE1" "pgrep -P $MGR 2>/dev/null || true")
if [ -z "$PID" ]; then
    fail "test1: migtest worker did not start"
    dump_log "$NODE1" /tmp/migtest.log
    run_on "$NODE1" "kill $MGR 2>/dev/null || true"
else
    migrate "$NODE1" "$PID" "$NODE2_ID"
    sleep 3

    if run_on "$NODE1" "cat /proc/mattx/guests" | grep -q "$PID"; then
        pass "test1: Deputy present on $NODE1"
    else
        fail "test1: Deputy missing on $NODE1"
        dump_proc_mattx "$NODE1"
        dump_log "$NODE1" /tmp/migtest.log
        dump_dmesg "$NODE1" 50
    fi

    if run_on "$NODE2" "ps aux" | grep -q "[m]igtest"; then
        pass "test1: Surrogate running on $NODE2"
    else
        fail "test1: migtest not on $NODE2"
        dump_proc_mattx "$NODE2"
        dump_log "$NODE1" /tmp/migtest.log
        dump_dmesg "$NODE1" 50
        dump_dmesg "$NODE2" 50
    fi

    sleep 5
    migrate "$NODE1" "$PID" "home"
    sleep 3

    if run_on "$NODE1" "ps aux" | grep -q "[m]igtest"; then
        pass "test1: migtest returned to $NODE1"
    else
        fail "test1: migtest not back on $NODE1"
        dump_proc_mattx "$NODE1"
        dump_log "$NODE1" /tmp/migtest.log
        dump_dmesg "$NODE1" 50
        dump_dmesg "$NODE2" 50
    fi

    run_on "$NODE1" "kill $MGR 2>/dev/null || true"
fi
check_no_oops "$NODE1" && pass "test1: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test1: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T1" ] && { repro_setup; repro_test1; }

# ---- Test 2: Network wormhole ----
_FAIL_T2=$FAIL
echo ""
echo "=== Test 2: Network wormhole (servertestpoll) ==="
SERVER_PID=$(run_on "$NODE1" "servertestpoll &>/tmp/server.log & echo \$!")
sleep 2

NODE1_IP="$(node_ip "$NODE1")"
if run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null"; then
    pass "test2: server reachable on $NODE1 before migration"
else
    fail "test2: server not reachable before migration"
    dump_log "$NODE1" /tmp/server.log
    dump_dmesg "$NODE1" 30
fi

migrate "$NODE1" "$SERVER_PID" "$NODE2_ID"
sleep 5

if run_on "$NODE2" "ps aux" | grep -q "[s]ervertestpoll"; then
    pass "test2: Surrogate on $NODE2"
else
    fail "test2: servertestpoll not on $NODE2"
    dump_proc_mattx "$NODE1"
    dump_proc_mattx "$NODE2"
    dump_log "$NODE1" /tmp/server.log
    dump_dmesg "$NODE1" 50
    dump_dmesg "$NODE2" 50
fi

if run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null"; then
    pass "test2: wormhole still serves on $NODE1 IP"
else
    fail "test2: wormhole broken"
    dump_proc_mattx "$NODE1"
    dump_proc_mattx "$NODE2"
    dump_log "$NODE1" /tmp/server.log
    dump_dmesg "$NODE1" 50
    dump_dmesg "$NODE2" 50
fi

run_on "$NODE1" "kill $SERVER_PID 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test2: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test2: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T2" ] && { repro_setup; repro_test2; }

# ---- Test 3: Pingpong stress ----
_FAIL_T3=$FAIL
echo ""
echo "=== Test 3: Pingpong (5 cycles) ==="
STRESS_MGR=$(run_on "$NODE1" "migtest &>/tmp/pingpong.log & echo \$!")
sleep 2
STRESS_PID=$(run_on "$NODE1" "pgrep -P $STRESS_MGR")

TEST3_OK=1
for i in $(seq 1 5); do
    migrate "$NODE1" "$STRESS_PID" "$NODE2_ID"; sleep 6
    if ! run_on "$NODE2" "ps aux" | grep -q "[m]igtest"; then
        fail "test3: lost at cycle $i (forward)"
        dump_proc_mattx "$NODE1"
        dump_proc_mattx "$NODE2"
        dump_log "$NODE1" /tmp/pingpong.log
        dump_dmesg "$NODE1" 50
        dump_dmesg "$NODE2" 50
        TEST3_OK=0
        break
    fi
    migrate "$NODE1" "$STRESS_PID" "home"; sleep 6
    if ! run_on "$NODE1" "ps aux" | grep -q "[m]igtest"; then
        fail "test3: lost at cycle $i (return)"
        dump_proc_mattx "$NODE1"
        dump_proc_mattx "$NODE2"
        dump_log "$NODE1" /tmp/pingpong.log
        dump_dmesg "$NODE1" 50
        dump_dmesg "$NODE2" 50
        TEST3_OK=0
        break
    fi
done

if [ "$TEST3_OK" -eq 1 ]; then
    if run_on "$NODE1" "ps aux" | grep -q "[m]igtest"; then
        pass "test3: alive after 5 cycles"
    else
        fail "test3: process died after cycles"
        dump_log "$NODE1" /tmp/pingpong.log
        dump_dmesg "$NODE1" 30
    fi
fi

run_on "$NODE1" "kill $STRESS_MGR 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test3: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test3: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T3" ] && { repro_setup; repro_test3; }

# ---- Summary ----
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
