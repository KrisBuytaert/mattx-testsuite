#!/bin/bash
# test-dsm-rw.sh <alma|deb|ubu|fed>
# The DSM "microscope" (mattx#66, atomic DSM): bin/dsmreadwritetest run through
# bin/dsmrw-loop. The Manager writes pages natively on the home node, the
# worker is migrated and polls; a write that the worker never sees is a stale
# page (the #66 bug). Scenarios: ctl atomic store rw rwfield mp.
#
# Verdict per scenario: FAIL, HANG or ERR in any run fails it. WARN (ack latency
# clustering around the 50 ms Sweeper period: consistency only eventual) and
# INCONCLUSIVE are printed but do not fail. Tunables: DSMRW_RUNS (default 1),
# DSMRW_ROUNDS (300), DSMRW_DELAYS ("0 0.1").
#
# dsmrw-loop follows the kernel log of the remote node over ssh from the home
# node, so a local ssh-agent with the test key is forwarded to node1 (the key
# itself is never copied to the node).
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    fed)  NODE1="fednode1";  NODE2="fednode2"  ;;
esac

auto_report_wrap "test-dsm-rw" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

RUNS="${DSMRW_RUNS:-1}"; ROUNDS="${DSMRW_ROUNDS:-300}"; DELAYS="${DSMRW_DELAYS:-0 0.1}"
LOOP='$HOME/mattx/bin/dsmrw-loop'
OUTDIR="dsmrw-$(date +%Y%m%d-%H%M%S)"

cleanup() {
    run_on "$NODE1" "pkill -9 -f '[d]smreadwritetest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[d]smreadwritetest' 2>/dev/null || true" 2>/dev/null || true
    [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== DSM microscope (dsmreadwritetest via dsmrw-loop) on ${DISTRO} cluster ==="

# Older MattX commits have no dsmrw-loop: nothing to run, not a failure.
if ! run_on "$NODE1" "test -x $LOOP && command -v dsmreadwritetest" >/dev/null 2>&1; then
    echo "SKIP: dsmrw-loop / dsmreadwritetest not installed on $NODE1 (MattX commit predates them)"
    echo ""
    echo "=============================="
    echo "DSM-RW Results: 0 passed, 0 failed (skipped)"
    echo "=============================="
    exit 0
fi

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "dsm-rw: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "DSM-RW Results: $PASS passed, $FAIL failed"; exit 1
fi

run_on "$NODE1" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE1" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf 'Host 192.168.100.*\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n' > ~/.ssh/config && chmod 600 ~/.ssh/config"

DMESG_CURSOR_1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_2=$(dmesg_cursor "$NODE2")

eval "$(ssh-agent -s)" >/dev/null
ssh-add "$SSH_KEY" 2>/dev/null

echo "  runs=$RUNS rounds=$ROUNDS delays=[$DELAYS] node2 id=$NODE2_ID (output on $NODE1: ~/$OUTDIR)"
LOG=$(mktemp)
set +e
# shellcheck disable=SC2086
ssh $SSH_OPTS -A "$SSH_USER@$(node_ip "$NODE1")" \
    "cd ~ && timeout 3000 $LOOP --remote $SSH_USER@$(node_ip "$NODE2") --node $NODE2_ID -n $RUNS -r $ROUNDS -d '$DELAYS' -s all --outdir ~/$OUTDIR" \
    2>&1 | tee "$LOG"
LOOP_RC=${PIPESTATUS[0]}
set -e

# Summary rows: scenario delay runs PASS FAIL HANG ERR INCON INVAL pass% CI fail/Mround avg max warned
echo ""
ROWS=$(awk '/^scenario +delay/{f=1; next} /^-+$/{f=0} f && NF>=9 {print}' "$LOG")
if [ -z "$ROWS" ]; then
    fail "dsm-rw: no summary table from dsmrw-loop (rc=$LOOP_RC) -- harness or infrastructure problem"
else
    while read -r scen delay runs npass nfail nhang nerr nincon ninval rest; do
        bad=$((nfail + nhang + nerr))
        warned=$(echo "$rest" | awk '{print $NF}')
        if [ "$bad" -gt 0 ]; then
            fail "dsm-rw: $scen d=$delay: $nfail FAIL, $nhang HANG, $nerr ERR in $runs run(s)"
        elif [ "$npass" -eq 0 ] && [ "$nincon" -eq 0 ] && [ "$ninval" -eq 0 ]; then
            pass "dsm-rw: $scen d=$delay: no failure in $runs run(s) (WARN: latency near the 50 ms Sweeper period, consistency only eventual)"
        else
            pass "dsm-rw: $scen d=$delay: $npass/$runs PASS, 0 FAIL ($nincon inconclusive, $ninval invalid, $warned warned)"
        fi
    done <<< "$ROWS"
fi
rm -f "$LOG"

echo "  evidence of bad runs (fail-*/warn-*), if any, on $NODE1:"
run_on "$NODE1" "ls -d ~/$OUTDIR/fail-* ~/$OUTDIR/warn-* 2>/dev/null | head -20; ls ~/$OUTDIR/runs.csv 2>/dev/null" | sed 's/^/    /' || true

check_no_oops "$NODE1" "$DMESG_CURSOR_1" && pass "dsm-rw: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_2" && pass "dsm-rw: no oops on $NODE2"

echo ""
echo "=============================="
echo "DSM-RW Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
