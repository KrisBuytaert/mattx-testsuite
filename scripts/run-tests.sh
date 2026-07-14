#!/bin/bash
# run-tests.sh <alma|deb|ubu>
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
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

# Print where a named process is currently running, with ps evidence.
show_location() {
    local name="$1" pid="$2" node="$3"
    local ip; ip="$(node_ip "$node")"
    echo "  ► $name [PID $pid] is running on $node ($ip):"
    run_on "$node" "ps -p $pid -o pid,user,stat,cmd --no-headers 2>/dev/null \
                    || ps aux | awk -v p=$pid '\$2==p{print \"   \"\$0}' \
                    || echo '   (not found in ps — may have already exited)'"
}

# Print the /proc/mattx/remote entry for a PID (home-node side after forward migration).
# Format: PID:NODEID — one line per exported process.
show_deputy() {
    local pid="$1" node="$2"
    local remote
    remote=$(run_on "$node" "cat /proc/mattx/remote 2>/dev/null || echo ''")
    echo "  Deputy export tracker on $node (/proc/mattx/remote):"
    local entry; entry=$(echo "$remote" | grep "^${pid}:" || true)
    if [ -n "$entry" ]; then
        echo "   $entry  ← Deputy PID $pid is exported to node $(echo "$entry" | cut -d: -f2)"
    else
        echo "   (PID $pid not found — migration may have failed or process already returned)"
    fi
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

check_no_oops() {
    local node="$1"
    if run_on "$node" "sudo dmesg" | grep -q "Oops\|BUG: unable to handle\|kernel BUG"; then
        fail "kernel oops on $node"
        return 1
    fi
    return 0
}

# ---- Cleanup stale test processes ----
echo "[setup] cleaning up stale test processes..."
run_on "$NODE1" "pkill migtest 2>/dev/null || true"
run_on "$NODE2" "pkill migtest 2>/dev/null || true"
run_on "$NODE1" "pkill servertestpoll 2>/dev/null || true"
run_on "$NODE2" "pkill servertestpoll 2>/dev/null || true"
sleep 1

# ---- Pre-flight ----
echo ""
echo "=== Pre-flight: cluster state ==="
NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}') || {
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE1"; exit 1
}
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}') || {
    fail "pre-flight: cannot read /proc/mattx/nodes on $NODE2"; exit 1
}
[ -n "$NODE1_ID" ] || { fail "pre-flight: could not determine node ID for $NODE1"; exit 1; }
[ -n "$NODE2_ID" ] || { fail "pre-flight: could not determine node ID for $NODE2"; exit 1; }

run_on "$NODE1" "cat /proc/mattx/nodes" | grep -qw "$NODE2_ID" || {
    fail "pre-flight: $NODE1 (ID=$NODE1_ID) does not see $NODE2 (ID=$NODE2_ID) in cluster"; exit 1
}
echo "  Cluster OK"
echo "    $NODE1: ID=$NODE1_ID  IP=$(node_ip "$NODE1")"
echo "    $NODE2: ID=$NODE2_ID  IP=$(node_ip "$NODE2")"

# ---- Test 1: Basic forward + return migration ----
_FAIL_T1=$FAIL
echo ""
echo "=== Test 1: Basic migration (migtest) ==="

MGR=$(run_on "$NODE1" "migtest &>/tmp/migtest.log & echo \$!")
sleep 2
PID=$(run_on "$NODE1" "pgrep -P $MGR" || true)
[ -n "$PID" ] || { fail "test1: migtest worker did not start"; run_on "$NODE1" "kill $MGR 2>/dev/null||true"; }

echo ""
show_location "migtest" "$PID" "$NODE1"

do_migrate "migtest" "$PID" "$NODE1" "$NODE2" "$NODE2_ID"
sleep 3

echo ""
echo "  After forward migration:"
show_deputy "$PID" "$NODE1"
show_location "migtest (Surrogate)" "$PID" "$NODE2"

run_on "$NODE1" "cat /proc/mattx/remote" | grep -q "^${PID}:" && \
    pass "test1: Deputy present on $NODE1 (/proc/mattx/remote)" || fail "test1: Deputy missing on $NODE1"

run_on "$NODE2" "ps aux" | grep -q "[m]igtest" && \
    pass "test1: Surrogate running on $NODE2" || fail "test1: migtest not on $NODE2"

sleep 5
do_migrate "migtest" "$PID" "$NODE1" "$NODE1" "home"
sleep 3

echo ""
echo "  After return migration:"
show_location "migtest" "$PID" "$NODE1"

run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
    pass "test1: migtest returned to $NODE1" || fail "test1: migtest not back on $NODE1"

run_on "$NODE1" "kill $MGR 2>/dev/null || true"
check_no_oops "$NODE1" && pass "test1: no oops on $NODE1"
check_no_oops "$NODE2" && pass "test1: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T1" ] && { repro_setup; repro_test1; }

# ---- Test 2: Network wormhole ----
_FAIL_T2=$FAIL
echo ""
echo "=== Test 2: Network wormhole (servertestpoll) ==="

SERVER_MGR=$(run_on "$NODE1" "servertestpoll &>/tmp/server.log & echo \$!")
sleep 2
# servertestpoll forks: the Manager (SERVER_MGR, just waitpid()s) and the
# Worker child, which actually holds the listening socket. Migrate the
# Worker's PID, not the Manager's -- mirrors what test1/test3 already do via
# pgrep -P for migtest. Migrating the Manager instead sends a process whose
# only job is `waitpid(child_pid)` on a PID that doesn't exist as its child
# once resumed on the target node; waitpid() fails (ECHILD, unchecked) and
# the Manager exits within milliseconds of resuming -- which the kernel then
# (correctly) reports as a real process death, not a bug in MattX itself.
SERVER_PID=$(run_on "$NODE1" "pgrep -P $SERVER_MGR" || true)
[ -n "$SERVER_PID" ] || { fail "test2: servertestpoll worker did not start"; run_on "$NODE1" "kill $SERVER_MGR 2>/dev/null||true"; }

NODE1_IP="$(node_ip "$NODE1")"
echo ""
show_location "servertestpoll" "$SERVER_PID" "$NODE1"

echo "  Checking TCP reachability on $NODE1_IP:8080 before migration..."
run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null" && \
    pass "test2: server reachable on $NODE1 before migration" || \
    fail "test2: server not reachable before migration"

do_migrate "servertestpoll" "$SERVER_PID" "$NODE1" "$NODE2" "$NODE2_ID"

# A socket-holding process needs many extra syscall-replay round trips (bind,
# listen, connect, ...) to reconstruct on the target, unlike a bare migtest —
# that can take 30s+. Poll instead of a fixed sleep so we don't fail a
# migration that's simply still in flight.
echo "  Waiting for migration to complete (up to 60s)..."
for i in $(seq 1 30); do
    run_on "$NODE2" "ps aux" | grep -q "[s]ervertestpoll" && break
    sleep 2
done

echo ""
echo "  After migration:"
show_deputy "$SERVER_PID" "$NODE1"
show_location "servertestpoll (Surrogate)" "$SERVER_PID" "$NODE2"

MIGRATED=0
if run_on "$NODE2" "ps aux" | grep -q "[s]ervertestpoll"; then
    pass "test2: Surrogate running on $NODE2"
    MIGRATED=1
else
    fail "test2: servertestpoll not on $NODE2"
    echo "  dmesg tail on $NODE1 (migration diagnostics):"
    run_on "$NODE1" "sudo dmesg | tail -15" | sed 's/^/    /' || true
fi

if [ "$MIGRATED" -eq 1 ]; then
    echo "  Checking TCP reachability on $NODE1_IP:8080 through wormhole..."
    run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null" && \
        pass "test2: wormhole still serves on $NODE1 IP ($NODE1_IP:8080)" || \
        fail "test2: wormhole broken — $NODE1_IP:8080 not reachable after migration"
else
    echo "  Skipping wormhole nc check — migration did not succeed (result would be a false positive)"
fi

run_on "$NODE1" "kill $SERVER_MGR 2>/dev/null || true"
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

echo ""
show_location "migtest" "$STRESS_PID" "$NODE1"

for i in $(seq 1 5); do
    echo ""
    echo "  -- Cycle $i/5 --"
    do_migrate "migtest" "$STRESS_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 6
    if run_on "$NODE2" "ps aux" | grep -q "[m]igtest"; then
        show_location "migtest (Surrogate)" "$STRESS_PID" "$NODE2"
        pass "test3: cycle $i forward — migtest on $NODE2"
    else
        fail "test3: lost at cycle $i (forward migration)"
        break
    fi

    do_migrate "migtest" "$STRESS_PID" "$NODE1" "$NODE1" "home"
    sleep 6
    if run_on "$NODE1" "ps aux" | grep -q "[m]igtest"; then
        show_location "migtest" "$STRESS_PID" "$NODE1"
        pass "test3: cycle $i return — migtest back on $NODE1"
    else
        fail "test3: lost at cycle $i (return migration)"
        break
    fi
done

run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
    pass "test3: migtest alive after 5 full cycles" || fail "test3: process died during pingpong"

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
