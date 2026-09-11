#!/bin/bash
# run-tests.sh <alma|deb|ubu>
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

auto_report_wrap "run-tests" "$@"

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

repro_test4() {
    cat <<'REPRO'

  ── Test 4 repro: sustained file I/O across migration (dd_migtest) ───────
    # 1. Upload the workload and start it on node1; note the PID
    $SSH${N1} 'cat > /tmp/dd_migtest.py' <<'PY'
import os, time, hashlib
OUT = "/tmp/dd_migtest.dat"; CHUNK = 64*1024; TICKS = 600; INTERVAL = 1.0
pid = os.getpid()
print("dd_migtest PID={} starting on {}".format(pid, os.uname().nodename), flush=True)
h = hashlib.sha256(); total = 0
with open(OUT, "wb") as f:
    for i in range(1, TICKS + 1):
        data = os.urandom(CHUNK); f.write(data); f.flush(); os.fsync(f.fileno())
        h.update(data); total += len(data)
        if i % 10 == 0:
            print("tick {}/{} bytes={} sha256={}".format(i, TICKS, total, h.hexdigest()), flush=True)
        time.sleep(INTERVAL)
print("dd_migtest DONE bytes={} sha256={}".format(total, h.hexdigest()), flush=True)
PY
    $SSH${N1} 'nohup python3 /tmp/dd_migtest.py >/tmp/dd_migtest.log 2>&1 & echo $!'
    export PID=<pid-from-above>

    # 2. Forward migration; file keeps growing on node1 even though the
    #    process is now running (frozen Deputy + Surrogate) on node2
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 8
    $SSH${N2} 'ps -eo stat,cmd | grep dd_migtest'   # expect STAT != T (actually running)
    $SSH${N1} 'stat -c%s /tmp/dd_migtest.dat'        # expect: growing on repeat checks

    # 3. Return migration -- MUST use "home", sent to node1 (the home node),
    #    NOT a numeric node id sent to node2. The kernel looks up the
    #    Surrogate's own local PID via its guest registry automatically
    #    (mattx_trigger_recall -> mattx_capture_and_return_state); this is a
    #    distinct code path from admin_write's general forward-migrate
    #    branch where mattx#8's NULL-deref/deadlock live.
    $SSH${N1} "echo 'migrate $PID home' | sudo tee /proc/mattx/admin"; sleep 8
    $SSH${N1} 'ps -eo stat,cmd | grep dd_migtest'    # expect STAT != T, back on node1
    $SSH${N1} 'stat -c%s /tmp/dd_migtest.dat'         # expect: still growing

    # Cleanup + oops check
    $SSH${N1} "pkill -9 -f '[d]d_migtest.py' 2>/dev/null; true"
    $SSH${N2} "pkill -9 -f '[d]d_migtest.py' 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}

repro_test5() {
    cat <<'REPRO'

  ── Test 5 repro: migration against a stale cluster link ────────────────
    # Found by accident during an EESSI/OSU shared-memory test: after a
    # fresh cluster (re)start, /proc/mattx/nodes on node1 kept reporting
    # node2 as a healthy connected peer with `ss -tnp state established`
    # showing NO actual TCP socket between them at all -- cluster_map held
    # a stale link with no liveness check behind it. A bounce of node2's
    # mattx service is our best working hypothesis for reliably recreating
    # that same "reported connected, actually dead" state on demand.
    #
    # 1. Bounce node2's mattx service (kills its socket to node1 outright)
    $SSH${N2} "sudo systemctl restart mattx"
    sleep 3
    $SSH${N2} 'cat /proc/mattx/nodes'   # wait for it to come back up

    # 2. Immediately try a migration FROM node1 TO node2 -- node1 may still
    #    be holding the old, now-dead socket in cluster_map
    $SSH${N1} 'migtest &>/tmp/migtest5.log & sleep 2; pgrep migtest | tail -1'
    export PID=<child-pid-from-above>
    $SSH${N1} "echo 'migrate $PID $N2_ID' | sudo tee /proc/mattx/admin"; sleep 5

    # 3. Check dmesg on node1 for the failure signature
    $SSH${N1} 'sudo dmesg | grep "Network send failed"'

    # 4. THE ACTUAL BUG: if that line is present, PID never resumes on its
    #    own -- no further dmesg output, ps shows it permanently STAT=T.
    #    Confirmed only killable with SIGKILL, never self-recovers:
    $SSH${N1} 'ps -eo pid,stat,cmd | grep migtest'   # expect (currently): stuck at STAT=T forever

    # Cleanup + oops check
    $SSH${N1} "pkill -9 migtest 2>/dev/null; true"
    $SSH${N1} 'sudo dmesg | grep -E "Oops|BUG:"'
    $SSH${N2} 'sudo dmesg | grep -E "Oops|BUG:"'
  ─────────────────────────────────────────────────────────────────────────
REPRO
}
# -----------------------------------------------------------------------------

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

check_no_oops() {
    local node="$1" cursor="$2"
    if ! no_new_oops "$node" "$cursor"; then
        fail "kernel oops on $node"
        return 1
    fi
    return 0
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

DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")

# ---- Test 1: Basic forward + return migration ----
_FAIL_T1=$FAIL
echo ""
echo "=== Test 1: Basic migration (migtest) ==="

MGR=$(run_on "$NODE1" "migtest &>/tmp/migtest.log & echo \$!")
sleep 2
PID=$(run_on "$NODE1" "pgrep -P $MGR" || true)
if [[ "$PID" =~ ^[0-9]+$ ]]; then
    echo ""
    show_location "migtest" "$NODE1"

    do_migrate "migtest" "$PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 3

    echo ""
    echo "  After forward migration:"
    show_deputy "$PID" "$NODE1"
    show_location "migtest" "$NODE2"

    run_on "$NODE1" "cat /proc/mattx/remote" | grep -q "^${PID}:" && \
        pass "test1: Deputy present on $NODE1 (/proc/mattx/remote)" || fail "test1: Deputy missing on $NODE1"

    run_on "$NODE2" "ps aux" | grep -q "[m]igtest" && \
        pass "test1: Surrogate running on $NODE2" || fail "test1: migtest not on $NODE2"

    sleep 5
    do_migrate "migtest" "$PID" "$NODE1" "$NODE1" "home" "$NODE2"
    sleep 3

    echo ""
    echo "  After return migration:"
    show_location "migtest" "$NODE1"

    run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
        pass "test1: migtest returned to $NODE1" || fail "test1: migtest not back on $NODE1"
else
    fail "test1: migtest worker did not start"
fi

run_on "$NODE1" "kill $MGR $PID 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test1: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test1: no oops on $NODE2"
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
if [[ "$SERVER_PID" =~ ^[0-9]+$ ]]; then
    NODE1_IP="$(node_ip "$NODE1")"
    echo ""
    show_location "servertestpoll" "$NODE1"

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
    show_location "servertestpoll" "$NODE2"

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
        # The process showing up in `ps` (checked above) only means the task
        # itself resumed -- the socket's bind()/listen() replay through the
        # wormhole is a separate, slightly later step (same "many extra
        # round trips" the comment above already calls out), so checking
        # reachability the instant the process appears can race a listener
        # that hasn't actually bound yet. Poll instead of checking once.
        echo "  Checking TCP reachability on $NODE1_IP:8080 through wormhole (up to 20s)..."
        WORMHOLE_OK=0
        for i in $(seq 1 10); do
            run_on "$NODE2" "nc -z $NODE1_IP 8080 2>/dev/null" && { WORMHOLE_OK=1; break; }
            sleep 2
        done
        if [ "$WORMHOLE_OK" -eq 1 ]; then
            pass "test2: wormhole still serves on $NODE1 IP ($NODE1_IP:8080)"
        else
            fail "test2: wormhole broken — $NODE1_IP:8080 not reachable after migration"
        fi
    else
        echo "  Skipping wormhole nc check — migration did not succeed (result would be a false positive)"
    fi
else
    fail "test2: servertestpoll worker did not start"
fi

run_on "$NODE1" "kill $SERVER_MGR $SERVER_PID 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test2: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test2: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T2" ] && { repro_setup; repro_test2; }

# ---- Test 3: Pingpong stress ----
_FAIL_T3=$FAIL
echo ""
echo "=== Test 3: Pingpong (5 cycles) ==="

STRESS_MGR=$(run_on "$NODE1" "migtest &>/tmp/pingpong.log & echo \$!")
sleep 2
STRESS_PID=$(run_on "$NODE1" "pgrep -P $STRESS_MGR" || true)

if [[ "$STRESS_PID" =~ ^[0-9]+$ ]]; then
    echo ""
    show_location "migtest" "$NODE1"

    for i in $(seq 1 5); do
        echo ""
        echo "  -- Cycle $i/5 --"
        do_migrate "migtest" "$STRESS_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 6
        if run_on "$NODE2" "ps aux" | grep -q "[m]igtest"; then
            show_location "migtest" "$NODE2"
            pass "test3: cycle $i forward — migtest on $NODE2"
        else
            fail "test3: lost at cycle $i (forward migration)"
            break
        fi

        do_migrate "migtest" "$STRESS_PID" "$NODE1" "$NODE1" "home" "$NODE2"
        sleep 6
        if run_on "$NODE1" "ps aux" | grep -q "[m]igtest"; then
            show_location "migtest" "$NODE1"
            pass "test3: cycle $i return — migtest back on $NODE1"
        else
            fail "test3: lost at cycle $i (return migration)"
            break
        fi
    done

    run_on "$NODE1" "ps aux" | grep -q "[m]igtest" && \
        pass "test3: migtest alive after 5 full cycles" || fail "test3: process died during pingpong"
else
    fail "test3: migtest worker did not start"
fi

run_on "$NODE1" "kill $STRESS_MGR $STRESS_PID 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test3: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test3: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T3" ] && { repro_setup; repro_test3; }

# ---- Test 4: Sustained file I/O across migration (dd-style) ----
_FAIL_T4=$FAIL
echo ""
echo "=== Test 4: Sustained file I/O across migration (dd_migtest, ~10min) ==="

DD_OUT="/tmp/dd_migtest.dat"
# Two separate calls, not one combined command: $DD_OUT contains the raw,
# unescaped substring "dd_migtest" too, and pkill -f matches a process's
# FULL cmdline -- in one combined `sh -c "pkill ...; rm -f $DD_OUT ..."`,
# that rm argument makes the whole cmdline match the pkill pattern, so
# pkill -9 kills its OWN parent shell before rm ever runs (the bracket
# trick only protects against matching pkill's own invocation text, not a
# different part of the same command line).
run_on "$NODE1" "pkill -9 -f '[d]d_migtest.py' 2>/dev/null; true"
run_on "$NODE1" "rm -f $DD_OUT; true"
run_on "$NODE1" "cat > /tmp/dd_migtest.py" <<'PYEOF'
import os, time, hashlib

OUT = "/tmp/dd_migtest.dat"
CHUNK = 64 * 1024   # 64KB/tick
TICKS = 600         # 600 ticks * 1s = ~10 minutes
INTERVAL = 1.0

pid = os.getpid()
print("dd_migtest PID={} starting on {}".format(pid, os.uname().nodename), flush=True)

h = hashlib.sha256()
total = 0
with open(OUT, "wb") as f:
    for i in range(1, TICKS + 1):
        data = os.urandom(CHUNK)
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
        h.update(data)
        total += len(data)
        if i % 10 == 0:
            print("tick {}/{}  node={}  pid={}  bytes={}  sha256={}".format(
                i, TICKS, os.uname().nodename, pid, total, h.hexdigest()), flush=True)
        time.sleep(INTERVAL)

print("dd_migtest DONE on {} bytes={} sha256={}".format(os.uname().nodename, total, h.hexdigest()), flush=True)
PYEOF

echo "  Starting dd_migtest on $NODE1 ($(node_ip "$NODE1")) -- single open fd to a plain file,"
echo "  os.urandom()-generated data (getrandom(2), no lingering fd to a character device),"
echo "  fsync'd writes every tick. Tests the ghost-file wormhole path directly, not just process"
echo "  presence: the fd was opened on \$NODE1 before migration, so every write after migration"
echo "  must be RPC'd back through mattx_fileio.c to keep landing there."
DD_PID=$(run_on "$NODE1" "nohup python3 /tmp/dd_migtest.py >/tmp/dd_migtest.log 2>&1 & echo \$!")
sleep 5

echo ""
show_location "dd_migtest" "$NODE1"
echo "  Log tail from $NODE1:"
run_on "$NODE1" "tail -5 /tmp/dd_migtest.log 2>/dev/null || true" | sed 's/^/    /'

do_migrate "dd_migtest" "$DD_PID" "$NODE1" "$NODE2" "$NODE2_ID"
sleep 8

echo ""
if is_actually_running "dd_migtest.py" "$NODE2"; then
    show_location "dd_migtest" "$NODE2"
    echo "  Log tail (stdout forwarded via MattX wormhole):"
    run_on "$NODE1" "tail -5 /tmp/dd_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    pass "test4: dd_migtest migrated to $NODE2"

    SIZE_BEFORE=$(run_on "$NODE1" "stat -c%s $DD_OUT 2>/dev/null || echo 0")
    sleep 20
    SIZE_AFTER=$(run_on "$NODE1" "stat -c%s $DD_OUT 2>/dev/null || echo 0")
    if is_actually_running "dd_migtest.py" "$NODE2" && [ "$SIZE_AFTER" -gt "$SIZE_BEFORE" ]; then
        show_location "dd_migtest" "$NODE2"
        pass "test4: dd_migtest still running on $NODE2, file on $NODE1 still growing ($SIZE_BEFORE -> $SIZE_AFTER bytes)"

        # ---- Return leg: the INTENDED recall mechanism -- "migrate <pid>
        # home" sent to the HOME node ($NODE1), using the same original PID
        # from the whole test, exactly like Test 1/3 above. The kernel looks
        # up the Surrogate's own local PID via its guest registry
        # automatically (mattx_trigger_recall -> mattx_capture_and_return_state)
        # -- a dedicated code path, distinct from the general forward-migrate
        # admin_write branch where mattx#8's NULL-deref/deadlock live.
        do_migrate "dd_migtest" "$DD_PID" "$NODE1" "$NODE1" "home" "$NODE2"
        sleep 8

        echo ""
        if is_actually_running "dd_migtest.py" "$NODE1"; then
            show_location "dd_migtest" "$NODE1"
            echo "  Log tail:"
            run_on "$NODE1" "tail -5 /tmp/dd_migtest.log 2>/dev/null || true" | sed 's/^/    /'
            pass "test4: dd_migtest migrated back to $NODE1"

            SIZE_BEFORE2=$(run_on "$NODE1" "stat -c%s $DD_OUT 2>/dev/null || echo 0")
            sleep 20
            SIZE_AFTER2=$(run_on "$NODE1" "stat -c%s $DD_OUT 2>/dev/null || echo 0")
            if is_actually_running "dd_migtest.py" "$NODE1" && [ "$SIZE_AFTER2" -gt "$SIZE_BEFORE2" ]; then
                pass "test4: dd_migtest still running on $NODE1 after return, file still growing ($SIZE_BEFORE2 -> $SIZE_AFTER2 bytes) -- round trip complete"
            else
                fail "test4: dd_migtest not actually running, or file stopped growing, on $NODE1 after return migration settled"
            fi
        else
            fail "test4: dd_migtest not actually running on $NODE1 after return migration"
            echo "  dmesg tail on $NODE2:"
            run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi
    else
        fail "test4: dd_migtest not actually running on $NODE2, or file stopped growing on $NODE1, 15s after migration"
    fi
else
    fail "test4: dd_migtest not actually running on $NODE2 after migration"
    echo "  dmesg tail on $NODE1:"
    run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
fi

run_on "$NODE1" "kill -9 $DD_PID 2>/dev/null || true; pkill -9 -f '[d]d_migtest.py' 2>/dev/null || true"
run_on "$NODE2" "pkill -9 -f '[d]d_migtest.py' 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test4: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test4: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T4" ] && { repro_setup; repro_test4; }

_FAIL_T5=$FAIL
echo ""
echo "=== Test 5: migration against a stale cluster link (peer service bounce) ==="
# Isolated, MPI/EESSI-free reproduction of a bug found via the OSU
# shared-memory suite: /proc/mattx/nodes can keep reporting a peer as
# connected long after its actual TCP socket is gone (cluster_map holds a
# stale link with no liveness check). A migration attempted against that
# stale link fails to send its blueprint, and the source process — a
# single, un-threaded process here, ruling out any gang/MPI angle — is left
# frozen (STAT=T) with NO recovery path: mattx_migr.c discards
# mattx_comm_send()'s return value outright, so nothing ever un-freezes it.
#
# Bouncing node2's mattx service (killing its socket to node1) is our best
# working hypothesis for recreating that "reported connected, actually
# dead" state on demand, rather than waiting for it to occur naturally.
run_on "$NODE2" "sudo systemctl restart mattx"
i=0
until run_on "$NODE2" "cat /proc/mattx/nodes" >/dev/null 2>&1; do
    sleep 2; i=$((i+1))
    [ "$i" -lt 15 ] || { fail "test5: node2 mattx service did not come back after restart"; break; }
done
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" | awk '/\(Local\)/{print $1}')

DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")

MGR5=$(run_on "$NODE1" "migtest &>/tmp/migtest5.log & echo \$!")
sleep 2
PID5=$(run_on "$NODE1" "pgrep -P $MGR5 migtest 2>/dev/null | tail -1" || true)
PID5="${PID5:-$MGR5}"

show_location "migtest" "$NODE1"
do_migrate "migtest" "$PID5" "$NODE1" "$NODE2" "$NODE2_ID"
sleep 5

# See the comment on no_new_oops() in lib.sh for why this can't use a plain
# `$1`-based awk split: dmesg right-pads the timestamp for column alignment,
# which silently breaks that approach for any uptime under ~2.7 hours.
SEND_FAILED=$(run_on "$NODE1" "sudo dmesg | awk -v c=$DMESG_CURSOR_NODE1 '
    match(\$0, /^\[[ 0-9.]+\]/) {
        ts = substr(\$0, RSTART + 1, RLENGTH - 2); gsub(/ /, \"\", ts)
        if ((ts + 0) > (c + 0)) print
    }' | grep -c 'Network send failed'" || echo 0)

if [ "$SEND_FAILED" -gt 0 ]; then
    echo "  ► reproduced: blueprint send failed against the stale link (see dmesg below)"
    run_on "$NODE1" "sudo dmesg | tail -10" | sed 's/^/    /'

    # The actual regression contract: a failed send must not leave the
    # source process frozen forever. Poll a while before declaring it
    # stuck -- currently expected to fail, since nothing in mattx_migr.c
    # ever un-freezes it on a failed send.
    RECOVERED=0
    for _ in $(seq 1 6); do
        sleep 5
        STAT5=$(process_stat "migtest" "$NODE1")
        if [ -n "$STAT5" ] && [[ "$STAT5" != T* ]]; then RECOVERED=1; break; fi
    done
    if [ "$RECOVERED" -eq 1 ]; then
        pass "test5: source process recovered/resumed on $NODE1 after a failed migration send"
    else
        fail "test5: source process left permanently frozen (STAT=T) on $NODE1 after a failed migration send -- no recovery path in mattx_migr.c"
    fi
else
    echo "  ► stale-link condition did not reproduce this run (send succeeded) -- falling back to a normal migration assertion"
    if is_actually_running "migtest" "$NODE2"; then
        show_location "migtest" "$NODE2"
        pass "test5: migtest migrated normally to $NODE2 (stale-link condition not present this run)"
    else
        fail "test5: migtest not actually running on $NODE2 after migration"
    fi
fi

run_on "$NODE1" "kill -9 $PID5 2>/dev/null || true; pkill -9 migtest 2>/dev/null || true"
run_on "$NODE2" "pkill -9 migtest 2>/dev/null || true"
check_no_oops "$NODE1" "$DMESG_CURSOR_NODE1" && pass "test5: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_NODE2" && pass "test5: no oops on $NODE2"
[ "$FAIL" -gt "$_FAIL_T5" ] && { repro_setup; repro_test5; }

# ---- Summary ----
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
