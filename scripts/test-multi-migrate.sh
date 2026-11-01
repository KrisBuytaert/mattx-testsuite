#!/bin/bash
# test-multi-migrate.sh <alma|deb|ubu|fed>
# What happens when MANY processes are migrated at the same moment? Every other suite migrates one
# process at a time; this one fires the `migrate` admin commands in parallel (one ssh, N backgrounded
# writes to /proc/mattx/admin) and looks at the cluster afterwards.
#
# Scenarios (SIZES = burst sizes, default "2 4 8"; ROUNDS = repeats of M6, default 3):
#   M1  burst forward   N migtest on node1, all migrated to node2 at once, then all must be hosted and RUNNING there
#   M2  fan-out         the same N, half to node2 and half to node3 at once      (Alma only: needs a third node)
#   M3  crossing        N on node1 -> node2 while N on node2 -> node1, at once
#   M4  burst return    recall all of them (`migrate <pid> home`) at once; all must be home and running, no guests left
#   M5  kill mid-flight burst forward, then kill the home processes of half of them 200 ms later; the surrogates
#                       of the killed ones must disappear (Assassination), the others keep running
#   M6  repeat          M1 + M4 ROUNDS times with N=4, to catch races
#   M0  baseline        the same N moved one after another, only to print how long that takes (no verdict)
#
# Checked per scenario: no Oops/BUG in dmesg on any node, no node rebooted (boot_id), no new kdump, every
# surrogate's CPU time advances (not stuck in T), guests and remote lists match, no leftovers after cleanup.
# Timings ("time:" lines) are data for the reader, not a pass/fail threshold. Needs MattX running on all nodes.
set -uo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"
set +e

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2"; NODE3="almanode3" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2";  NODE3="" ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2";  NODE3="" ;;
    fed)  NODE1="fednode1";  NODE2="fednode2";  NODE3="" ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed>" >&2; exit 1 ;;
esac
SIZES="${SIZES:-2 4 8}"
ROUNDS="${ROUNDS:-3}"
SETTLE="${SETTLE:-90}"      # seconds to wait for a burst to land

auto_report_wrap "test-multi-migrate" "$@"
init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

NODES="$NODE1 $NODE2${NODE3:+ $NODE3}"
# bounded ssh: a wedged node must fail the test, not hang it
rto() { local n="$1"; shift; timeout 120 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$n")" "$@"; }

boot_id()   { rto "$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || echo unreachable; }
crash_cnt() { rto "$1" "sudo ls /var/crash 2>/dev/null | grep -c . ; true" 2>/dev/null | head -1; }
node_id()   { rto "$1" "awk '/\\(Local\\)/{print \$1}' /proc/mattx/nodes" 2>/dev/null | head -1; }
# short bounded ssh for polling: one wedged node must not stretch a wait loop far past its deadline
rts()       { local n="$1"; shift; timeout 20 ssh $SSH_OPTS -o ConnectTimeout=5 "$SSH_USER@$(node_ip "$n")" "$@"; }
lines()     { rts "$1" "grep -c . /proc/mattx/$2 2>/dev/null; true" 2>/dev/null | head -1; }

declare -A BOOT CRASH CURSOR ID
snapshot() {
    for n in $NODES; do BOOT[$n]="$(boot_id "$n")"; CRASH[$n]="$(crash_cnt "$n")"; CURSOR[$n]="$(dmesg_cursor "$n")"; done
}
ids() { for n in $NODES; do ID[$n]="$(node_id "$n")"; done; }

# no reboot, no kdump, no oops on any node since snapshot(); $1 = label
health() {
    local tag="$1" n ok=1
    for n in $NODES; do
        [ "$(boot_id "$n")" = "${BOOT[$n]}" ] || { fail "$tag: $n rebooted or became unreachable (boot_id changed)"; ok=0; }
        [ "$(crash_cnt "$n")" = "${CRASH[$n]}" ] || { fail "$tag: new kdump on $n"; ok=0; }
        no_new_oops "$n" "${CURSOR[$n]}" || { fail "$tag: oops/BUG in dmesg on $n"; ok=0; }
    done
    [ $ok = 1 ] && pass "$tag: no reboot, kdump or oops on any node"
}

# N migtest "workers" on node $1 (migtest forks: the child does the work and is what gets migrated)
start_workers() {
    local node="$1" n="$2"
    rto "$node" "for i in \$(seq 1 $n); do nohup migtest >/dev/null 2>&1 & done; sleep 2; true" >/dev/null 2>&1
}
# pids of the working children (a migtest whose parent is a migtest)
worker_pids() {
    rto "$1" "ps -eo pid,ppid,comm --no-headers | awk '\$3==\"migtest\"{c[\$1]=1;p[\$1]=\$2} END{for(i in p) if(p[i] in c) print i}' | sort -n" 2>/dev/null
}
# fire the migrations of the given pids from node $1 to node id $2 at the same moment
burst() {
    local node="$1" target="$2"; shift 2
    local cmd="" p
    for p in "$@"; do cmd="$cmd (echo 'migrate $p $target' | sudo tee /proc/mattx/admin >/dev/null) &"; done
    local t0 rc; t0=$(date +%s.%N)
    rto "$node" "$cmd wait" >/dev/null 2>&1; rc=$?
    echo "  burst: $# migrate commands to node id $target issued from $node, admin writes returned after $(echo "$(date +%s.%N) - $t0" | bc | cut -c1-5) s (ssh rc=$rc; 124 = timed out)"
}
# wait until /proc/mattx/$2 on node $1 has $3 lines; prints the seconds it took, or -1
wait_lines() {
    local node="$1" file="$2" want="$3" start now
    start=$(date +%s)
    while :; do
        [ "$(lines "$node" "$file")" = "$want" ] && { echo "$(( $(date +%s) - start ))"; return 0; }
        now=$(date +%s); [ $((now - start)) -ge "$SETTLE" ] && break
        sleep 1
    done
    echo -1; return 1
}
# how many of the guests on node $1 did not use CPU during 4 s (frozen / stuck)
frozen_guests() {
    rto "$1" 'f() { for p in $(cut -d: -f1 /proc/mattx/guests); do echo "$p $(awk "{print \$14+\$15}" /proc/$p/stat 2>/dev/null)"; done; }
a=$(f); sleep 4; b=$(f); n=0
for p in $(echo "$a" | cut -d" " -f1); do x=$(echo "$a" | awk -v p=$p "\$1==p{print \$2}"); y=$(echo "$b" | awk -v p=$p "\$1==p{print \$2}"); [ -n "$y" ] && [ "$y" -gt "$x" ] || n=$((n+1)); done; echo $n' 2>/dev/null | tail -1
}
# deputies on the home node run in state T by design; what matters is that nobody is a zombie / vanished
cleanup() {
    for n in $NODES; do
        rto "$n" "sudo pkill -9 -x migtest; sudo pkill -9 mattx-stub; true" >/dev/null 2>&1
    done
    sleep 8
    for n in $NODES; do rto "$n" "echo 'balancer 0' | sudo tee /proc/mattx/admin >/dev/null" >/dev/null 2>&1; done
}
leftovers() {   # $1 = tag: nothing hosted or remote anywhere once everything is killed
    local tag="$1" n bad=0 w
    for n in $NODES; do
        w="$(wait_lines "$n" guests 0)"; [ "$w" = -1 ] && { bad=1; echo "  leftover guests on $n: $(rto "$n" 'cat /proc/mattx/guests' 2>/dev/null | tr '\n' ' ')"; }
        w="$(wait_lines "$n" remote 0)"; [ "$w" = -1 ] && { bad=1; echo "  leftover remote entries on $n: $(rto "$n" 'cat /proc/mattx/remote' 2>/dev/null | tr '\n' ' ')"; }
    done
    [ $bad = 0 ] && pass "$tag: no guests or remote entries left after cleanup" || fail "$tag: guests or remote entries left after cleanup"
}

trap cleanup EXIT
ids
echo "node ids: $(for n in $NODES; do echo -n "$n=${ID[$n]} "; done)"
cleanup
snapshot

# --- M0 baseline: one at a time (timing only)
for N in $SIZES; do
    start_workers "$NODE1" "$N"; read -r -a P <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"
    t0=$(date +%s.%N)
    for p in "${P[@]}"; do burst "$NODE1" "${ID[$NODE2]}" "$p"; done
    w="$(wait_lines "$NODE2" guests "${#P[@]}")"
    echo "time: M0 sequential, N=${#P[@]}: all hosted after $(echo "$(date +%s.%N) - $t0" | bc | cut -c1-5) s (wait result $w)"
    cleanup
done

# --- M1 + M4 per size
for N in $SIZES; do
    start_workers "$NODE1" "$N"; read -r -a P <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"
    [ "${#P[@]}" = "$N" ] && pass "M1 N=$N: $N workers started on $NODE1" || { fail "M1 N=$N: only ${#P[@]} workers started"; cleanup; continue; }
    t0=$(date +%s.%N)
    burst "$NODE1" "${ID[$NODE2]}" "${P[@]}"
    w="$(wait_lines "$NODE2" guests "$N")"; el="$(echo "$(date +%s.%N) - $t0" | bc | cut -c1-5)"
    if [ "$w" = -1 ]; then fail "M1 N=$N: only $(lines "$NODE2" guests) of $N processes hosted on $NODE2 after ${SETTLE}s"
    else pass "M1 N=$N: all $N hosted on $NODE2"; echo "time: M1 burst, N=$N: all hosted after $el s"; fi
    [ "$(lines "$NODE1" remote)" = "$N" ] && pass "M1 N=$N: $NODE1 lists $N remote processes" || fail "M1 N=$N: $NODE1 remote list has $(lines "$NODE1" remote) entries, want $N"
    fz="$(frozen_guests "$NODE2")"; [ "${fz:-x}" = 0 ] && pass "M1 N=$N: every surrogate on $NODE2 uses CPU" || fail "M1 N=$N: ${fz:-?} surrogate(s) on $NODE2 did not advance"
    health "M1 N=$N"
    # M4: recall all at once
    read -r -a H <<<"$(rto "$NODE1" "cut -d: -f1 /proc/mattx/remote" 2>/dev/null | tr '\n' ' ')"
    cmd=""; for p in "${H[@]}"; do cmd="$cmd (echo 'migrate $p home' | sudo tee /proc/mattx/admin >/dev/null) &"; done
    t0=$(date +%s.%N); rto "$NODE1" "$cmd wait" >/dev/null 2>&1
    w1="$(wait_lines "$NODE1" remote 0)"; w2="$(wait_lines "$NODE2" guests 0)"; el="$(echo "$(date +%s.%N) - $t0" | bc | cut -c1-5)"
    if [ "$w1" = -1 ] || [ "$w2" = -1 ]; then fail "M4 N=$N: recall incomplete (remote $(lines "$NODE1" remote), guests on $NODE2 $(lines "$NODE2" guests))"
    else pass "M4 N=$N: all $N recalled home"; echo "time: M4 burst return, N=$N: all home after $el s"; fi
    nrun=$(rto "$NODE1" "ps -eo stat,comm --no-headers | awk '\$2==\"migtest\" && \$1!~/^[TZ]/' | wc -l" 2>/dev/null | tail -1)
    [ "${nrun:-0}" -ge "$N" ] && pass "M4 N=$N: the recalled processes run on $NODE1 again" || fail "M4 N=$N: only ${nrun:-0} migtest processes running on $NODE1 after recall"
    health "M4 N=$N"
    cleanup; leftovers "M1/M4 N=$N"
done

# --- M2 fan-out (needs a third node)
if [ -n "$NODE3" ]; then
    N=4; start_workers "$NODE1" "$N"; read -r -a P <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"
    if [ "${#P[@]}" = "$N" ]; then
        ( burst "$NODE1" "${ID[$NODE2]}" "${P[0]}" "${P[1]}" ) &
        ( burst "$NODE1" "${ID[$NODE3]}" "${P[2]}" "${P[3]}" ) &
        wait
        w2="$(wait_lines "$NODE2" guests 2)"; w3="$(wait_lines "$NODE3" guests 2)"
        if [ "$w2" != -1 ] && [ "$w3" != -1 ]; then pass "M2: 2 processes hosted on $NODE2 and 2 on $NODE3"
        else fail "M2: guests on $NODE2=$(lines "$NODE2" guests) on $NODE3=$(lines "$NODE3" guests), want 2 and 2"; fi
        fz2="$(frozen_guests "$NODE2")"; fz3="$(frozen_guests "$NODE3")"
        [ "${fz2:-x}" = 0 ] && [ "${fz3:-x}" = 0 ] && pass "M2: every surrogate runs" || fail "M2: frozen surrogates ($NODE2 ${fz2:-?}, $NODE3 ${fz3:-?})"
    else fail "M2: only ${#P[@]} workers started"; fi
    health "M2"; cleanup; leftovers "M2"
else
    echo "M2 skipped: needs a third node ($DISTRO has two)"
fi

# --- M3 crossing traffic
for N in $SIZES; do
    start_workers "$NODE1" "$N"; start_workers "$NODE2" "$N"
    read -r -a A <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"; read -r -a B <<<"$(worker_pids "$NODE2" | tr '\n' ' ')"
    if [ "${#A[@]}" != "$N" ] || [ "${#B[@]}" != "$N" ]; then fail "M3 N=$N: workers started ${#A[@]}/${#B[@]}"; cleanup; continue; fi
    ( burst "$NODE1" "${ID[$NODE2]}" "${A[@]}" ) &
    ( burst "$NODE2" "${ID[$NODE1]}" "${B[@]}" ) &
    wait
    w1="$(wait_lines "$NODE1" guests "$N")"; w2="$(wait_lines "$NODE2" guests "$N")"
    if [ "$w1" != -1 ] && [ "$w2" != -1 ]; then pass "M3 N=$N: $N processes each way, $NODE1 and $NODE2 each host $N"
    else fail "M3 N=$N: guests on $NODE1=$(lines "$NODE1" guests) on $NODE2=$(lines "$NODE2" guests), want $N each"; fi
    fz1="$(frozen_guests "$NODE1")"; fz2="$(frozen_guests "$NODE2")"
    [ "${fz1:-x}" = 0 ] && [ "${fz2:-x}" = 0 ] && pass "M3 N=$N: every surrogate runs" || fail "M3 N=$N: frozen surrogates ($NODE1 ${fz1:-?}, $NODE2 ${fz2:-?})"
    health "M3 N=$N"; cleanup; leftovers "M3 N=$N"
done

# --- M5 kill home processes mid-flight
N=6; start_workers "$NODE1" "$N"; read -r -a P <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"
if [ "${#P[@]}" = "$N" ]; then
    burst "$NODE1" "${ID[$NODE2]}" "${P[@]}" &
    sleep 0.2
    rto "$NODE1" "kill -9 ${P[0]} ${P[1]} ${P[2]}" >/dev/null 2>&1
    wait
    w="$(wait_lines "$NODE2" guests 3)"
    [ "$w" != -1 ] && pass "M5: surrogates of the 3 killed processes are gone, 3 remain on $NODE2" || fail "M5: $(lines "$NODE2" guests) guests on $NODE2 after killing 3 of $N mid-flight, want 3"
    fz="$(frozen_guests "$NODE2")"; [ "${fz:-x}" = 0 ] && pass "M5: the surviving surrogates run" || fail "M5: ${fz:-?} surviving surrogate(s) frozen"
else fail "M5: only ${#P[@]} workers started"; fi
health "M5"; cleanup; leftovers "M5"

# --- M6 repeated bursts
bad=0
for r in $(seq 1 "$ROUNDS"); do
    N=4; start_workers "$NODE1" "$N"; read -r -a P <<<"$(worker_pids "$NODE1" | tr '\n' ' ')"
    burst "$NODE1" "${ID[$NODE2]}" "${P[@]}"
    w="$(wait_lines "$NODE2" guests "$N")"
    read -r -a H <<<"$(rto "$NODE1" "cut -d: -f1 /proc/mattx/remote" 2>/dev/null | tr '\n' ' ')"
    cmd=""; for p in "${H[@]}"; do cmd="$cmd (echo 'migrate $p home' | sudo tee /proc/mattx/admin >/dev/null) &"; done
    rto "$NODE1" "$cmd wait" >/dev/null 2>&1
    w1="$(wait_lines "$NODE1" remote 0)"
    echo "  round $r: forward wait=$w s, return wait=$w1 s"
    [ "$w" = -1 ] || [ "$w1" = -1 ] && bad=1
    cleanup
done
[ $bad = 0 ] && pass "M6: $ROUNDS repeated burst forward + return rounds all completed" || fail "M6: a repeated round did not complete"
health "M6"; leftovers "M6"

echo ""
echo "Multi-migrate Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
