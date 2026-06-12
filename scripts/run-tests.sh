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

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

check_no_oops() {
    local node="$1"
    if run_on "$node" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "kernel oops on $node"
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
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE1"; exit 1
}
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}') || {
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE2"; exit 1
}

[ -n "$NODE1_ID" ] || { fail "pre-flight: could not determine node ID for $NODE1"; exit 1; }
[ -n "$NODE2_ID" ] || { fail "pre-flight: could not determine node ID for $NODE2"; exit 1; }

# Verify each node sees the other
run_on "$NODE1" "cat /proc/mattx/nodes" | grep -qw "$NODE2_ID" || {
    fail "pre-flight: $NODE1 (ID=$NODE1_ID) does not see $NODE2 (ID=$NODE2_ID) in cluster"; exit 1
}
echo "cluster OK — $NODE1 ID=$NODE1_ID  $NODE2 ID=$NODE2_ID"

# ---- Test 1: Basic forward + return migration ----
echo ""
echo "=== Test 1: Basic migration (migtest) ==="
MGR=$(run_on "$NODE1" "migtest &>/tmp/migtest.log & echo \$!")
sleep 2
PID=$(run_on "$NODE1" "pgrep -P $MGR")
[ -n "$PID" ] || { fail "test1: migtest worker did not start"; run_on "$NODE1" "kill $MGR 2>/dev/null||true"; } && \

migrate "$NODE1" "$PID" "$NODE2_ID"
sleep 3

run_on "$NODE1" "cat /proc/mattx/guests" | grep -q "$PID" && \
    pass "test1: Deputy present on $NODE1" || fail "test1: Deputy missing on $NODE1"

run_on "$NODE2" "ps aux" | grep -q "[m]igtest" && \
    pass "test1: Surrogate running on $NODE2" || fail "test1: migtest not on $NODE2"

sleep 5
migrate "$NODE1" "$PID" "home"
sleep 3

run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
    pass "test1: migtest returned to $NODE1" || fail "test1: migtest not back on $NODE1"

run_on "$NODE1" "kill $MGR 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test1: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test1: no oops on $NODE2"

# ---- Test 2: Network wormhole ----
echo ""
echo "=== Test 2: Network wormhole (servertestpoll) ==="
SERVER_PID=$(run_on "$NODE1" "servertestpoll &>/tmp/server.log & echo \$!")
sleep 2

NODE1_IP="$(node_ip "$NODE1")"
run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null" && \
    pass "test2: server reachable on $NODE1 before migration" || \
    fail "test2: server not reachable before migration"

migrate "$NODE1" "$SERVER_PID" "$NODE2_ID"
sleep 5

run_on "$NODE2" "ps aux" | grep -q "[s]ervertestpoll" && \
    pass "test2: Surrogate on $NODE2" || fail "test2: servertestpoll not on $NODE2"

run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null" && \
    pass "test2: wormhole still serves on $NODE1 IP" || \
    fail "test2: wormhole broken"

run_on "$NODE1" "kill $SERVER_PID 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test2: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test2: no oops on $NODE2"

# ---- Test 3: Pingpong stress ----
echo ""
echo "=== Test 3: Pingpong (5 cycles) ==="
STRESS_MGR=$(run_on "$NODE1" "migtest &>/tmp/pingpong.log & echo \$!")
sleep 2
STRESS_PID=$(run_on "$NODE1" "pgrep -P $STRESS_MGR")

for i in $(seq 1 5); do
    migrate "$NODE1" "$STRESS_PID" "$NODE2_ID"; sleep 6
    run_on "$NODE2" "ps aux" | grep -q "[m]igtest" || { fail "test3: lost at cycle $i (forward)"; break; }
    migrate "$NODE1" "$STRESS_PID" "home"; sleep 6
    run_on "$NODE1" "ps aux" | grep -q "[m]igtest" || { fail "test3: lost at cycle $i (return)"; break; }
done

run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
    pass "test3: alive after 5 cycles" || fail "test3: process died"

run_on "$NODE1" "kill $STRESS_MGR 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test3: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test3: no oops on $NODE2"

# ---- Summary ----
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
