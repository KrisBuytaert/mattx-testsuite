#!/bin/bash
# test-eessi-pytorch-mp.sh <alma|deb|ubu>
# Multi-process PyTorch tests via EESSI on a cluster, based on the EESSI
# demo repo's PyTorch/pytorch_multiprocessing.py (N torch.multiprocessing
# workers training one model placed in shared memory with share_memory()).
# Test 1: run the unmodified eessi-demo script (functional baseline)
# Test 2/3: migrate a long-running variant of it (parent + N workers sharing
#           one tensor via /dev/shm-backed memory) via MattX, forward + return
#
# STATUS: new, not yet confirmed passing. Shared-memory + multi-process
# migration is a known gap (see test-dsm.sh, brainmatt/mattx#15), so treat a
# [FAIL] here as "not yet verified," not necessarily a new regression.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
DEMO_DIR="$TEST_DIR/eessi-demo/PyTorch"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu>" >&2; exit 1 ;;
esac

auto_report_wrap "eessi-pytorch-mp" "$@"

init_cluster "$DISTRO"

# Same pin as test-eessi-pytorch.sh: the demo's run.sh only knows 2023.06.
EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
PYTORCH_MODULE="PyTorch/2.1.2-foss-2023a"
# Few workers: the VMs are small and migration cost scales with process count.
NWORKERS="${PYTORCH_MP_WORKERS:-2}"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

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

# Print ps evidence for the same pattern on BOTH nodes, side by side, so a
# frozen Deputy (STAT contains 'T') and a running Surrogate are both
# visible in one place — the actual proof that a migration moved
# execution rather than just restarting a fresh process.
show_both_nodes() {
    local label="$1" pattern="$2"
    echo ""
    echo "  --- ps snapshot: $label (pattern: '$pattern') ---"
    show_location "$pattern" "$NODE1"
    show_location "$pattern" "$NODE2"
}

# Per-THREAD ps view (adds TID/WCHAN, drops the etime noise). A process-level
# `ps -eo` row can only show the state of the thread-group leader; a
# multi-threaded job can have its leader genuinely frozen by
# mattx_freeze_task_safely() (mattx_migr.c) while sibling threads keep
# running and burning CPU. PyTorch's own intraop/OpenMP thread pool makes
# this doubly relevant here — this is the evidence that distinguishes "the
# Deputy is truly frozen" from "the process looks idle in aggregate."
# IMPORTANT: the ps format string below ends in `cmd` (full command line,
# e.g. "gmx mdrun -s ion_channel.tpr ..."), NOT `comm` (bare executable
# name only, e.g. "gmx" -- no arguments, ever). This bit us for real: with
# `comm`, a multi-word $pattern like "gmx mdrun" can never match anything,
# since "mdrun" is an argument, not part of the executable name -- the
# check silently and permanently reported "no threads matching" regardless
# of whether the process was actually there. Confirmed live on a real gmx
# process (PID 91116): `ps -eo comm` printed just "gmx"; `ps -eo cmd`
# printed the full "gmx mdrun -s ion_channel.tpr -nsteps 2000 ...". If
# you're tempted to "simplify" this back to `comm` because it's shorter,
# don't -- see the two ps calls above for what that actually does.
show_threads() {
    local pattern="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    local cmd="ps -eLo pid,tid,ppid,user,stat,%cpu,wchan:24,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep"
    echo ""
    echo "  --- per-THREAD snapshot on $node (pattern: '$pattern') -- one row per thread (tid), not one row per process like the snapshot above ---"
    echo "  mattx@${node} (${ip})\$ $cmd"
    local out
    out="$(run_on "$node" "$cmd" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        echo "$out" | sed 's/^/      /'
    else
        echo "      (no threads matching '$pattern' on $node)"
    fi
}

# dmesg evidence for the actual MattX freeze/capture/import/recall pipeline
# (config_debug_mode defaults to true, so mattx_dbg() lines are always being
# logged) — lets the report show directly whether mattx_freeze_task_safely
# ([DRAIN]/[EXTRACT]) and the remote awakening ([IMPORT]/[RECALL]) actually
# ran for this PID, rather than only inferring it from ps snapshots.
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

# STAT field of the first process matching pattern on this node, or empty
# if no matching process exists at all. Distinguishes "gone" from "present
# but frozen" -- ps aux | grep can't, which silently produced false-positive
# PASSes before this check existed (see mattx#8 for a case that hid behind
# exactly this gap).
process_stat() {
    local pattern="$1" node="$2"
    # A migrated Surrogate briefly enters signal-stop (STAT T) around wormhole
    # RPCs -- observed flipping S/T in ~1/3 of samples while the job's log
    # advanced normally -- so a single ps sample can't distinguish "frozen"
    # from "momentarily stopped". Sample ~2s remotely and report a
    # non-stopped state if ANY sample saw one; only report T/Z if every
    # sample was stopped (a genuinely frozen Deputy/hung job).
    run_on "$node" "for i in 1 2 3 4 5 6 7 8; do ps -eo stat,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep | awk '{print \$1}' | head -1; sleep 0.25; done | awk 'NF{ if (\$1 !~ /^[TZ]/) {print; found=1; exit} else if (!first) first=\$1 } END{ if (!found && first) print first }'" 2>/dev/null
}

# Is a process matching pattern actually EXECUTING on this node (STAT other
# than T=stopped or Z=zombie), as opposed to merely PRESENT?
is_actually_running() {
    local pattern="$1" node="$2"
    local stat; stat="$(process_stat "$pattern" "$node")"
    [ -n "$stat" ] && [[ "$stat" != T* && "$stat" != Z* ]]
}

# Poll (up to $3 seconds, default 120) until a process matching pattern is
# actually executing on node. A fixed sleep after `migrate` is wrong here:
# the page pump for a PyTorch process is ~200k pages and takes 10s+ on a
# cold cluster, so the Surrogate legitimately appears after a fixed 8s check.
wait_running() {
    local pattern="$1" node="$2" max="${3:-120}" i
    for ((i = 0; i < max; i += 2)); do
        is_actually_running "$pattern" "$node" && return 0
        sleep 2
    done
    return 1
}

# Highest worker progress seen so far: the epoch number on the LAST log line
# (min of the shared per-worker counters). NOT a line count -- the parent
# prints a heartbeat every 2s even when the shared counters are frozen, which
# is exactly the symptom when only the parent migrated and the workers
# (separate processes, not moved) no longer share memory with it.
last_epoch() {
    run_on "$NODE1" "grep '^epoch ' /tmp/pytorch_mp_migtest.log 2>/dev/null | tail -1 | sed -E 's|^epoch ([0-9]+)/.*|\\1|'" | tail -1 | grep -E '^[0-9]+$' || echo 0
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

# Runs on any script exit (normal completion, an early `exit 1`, or an
# uncaught error under `set -e`) so a job started on whichever node it
# happened to be on at the time doesn't outlive the test. Safe to call
# multiple times / before the PID var is even set.
cleanup() {
    run_on "$NODE1" "kill -9 ${JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[p]ytorch_mp_migtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[p]ytorch_mp_migtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== PyTorch multiprocessing / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: unmodified eessi-demo script, functional baseline ----
echo "=== Test 1: eessi-demo pytorch_multiprocessing.py (no migration) ==="
if [ ! -f "$DEMO_DIR/pytorch_multiprocessing.py" ]; then
    fail "pytorch-mp-1: $DEMO_DIR/pytorch_multiprocessing.py not found (eessi-demo symlink broken?)"
else
    run_on "$NODE1" "mkdir -p /tmp/eessi-pytorch-mp"
    run_on "$NODE1" "cat > /tmp/eessi-pytorch-mp/pytorch_multiprocessing.py" < "$DEMO_DIR/pytorch_multiprocessing.py"
    if run_on "$NODE1" "
        cd /tmp/eessi-pytorch-mp
        source '${EESSI_INIT}'
        module load ${PYTORCH_MODULE}
        timeout 180 python3 pytorch_multiprocessing.py
    " 2>&1 | tee /tmp/pytorch_mp_out.$$ \
       && grep -q 'Prediction after training' /tmp/pytorch_mp_out.$$ \
       && grep -q 'Finished Process-0' /tmp/pytorch_mp_out.$$; then
        pass "pytorch-mp-1: eessi-demo multiprocessing example runs to completion on $NODE1"
    else
        fail "pytorch-mp-1: eessi-demo multiprocessing example failed on $NODE1"
    fi
    rm -f /tmp/pytorch_mp_out.$$
fi

# ---- Test 2/3: migrate a long-running multi-process variant ----
echo ""
echo "=== Test 2/3: multi-process PyTorch migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "pytorch-mp-2: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    # Same shape as the demo (mp.Process workers + model.share_memory()), but
    # the workers loop with a sleep so the job lives long enough to migrate,
    # and the parent prints a heartbeat of the shared weight so progress is
    # visible in the log. Each worker bumps a shared counter, so "epochs
    # advance" is measurable from the log after migration.
    run_on "$NODE1" "cat > /tmp/pytorch_mp_migtest.py" <<'PYEOF'
import os, sys, time
import torch
import torch.nn as nn
import torch.multiprocessing as mp

NWORKERS = int(sys.argv[1]) if len(sys.argv) > 1 else 2
TICKS = 300

def worker(model, counter, X, Y, rank):
    torch.set_num_threads(1)
    opt = torch.optim.SGD(model.parameters(), lr=0.001)
    loss_fn = nn.MSELoss()
    for i in range(TICKS):
        opt.zero_grad()
        loss = loss_fn(model(X), Y)
        loss.backward()
        opt.step()
        counter[rank] += 1
        time.sleep(0.4)

if __name__ == "__main__":
    print("PyTorch mp migtest PID={} starting on {}".format(os.getpid(), os.uname().nodename), flush=True)
    X = torch.tensor([[1], [2], [3], [4]], dtype=torch.float32)
    Y = torch.tensor([[2], [4], [6], [8]], dtype=torch.float32)
    model = nn.Linear(1, 1)
    model.share_memory()
    counter = torch.zeros(NWORKERS, dtype=torch.int64)
    counter.share_memory_()
    procs = [mp.Process(target=worker, args=(model, counter, X, Y, r)) for r in range(NWORKERS)]
    for p in procs:
        p.start()
    while any(p.is_alive() for p in procs):
        time.sleep(2)
        w = model.weight[0][0].item()
        print("epoch {}/{}  node={}  pid={}  w={:.4f}  counts={}".format(
            int(counter.min()), TICKS, os.uname().nodename, os.getpid(), w, counter.tolist()), flush=True)
    for p in procs:
        p.join()
    print("PyTorch mp migtest DONE on {}".format(os.uname().nodename), flush=True)
PYEOF

    echo "  Starting PyTorch mp migtest ($NWORKERS workers) on $NODE1 ($(node_ip "$NODE1"))..."
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ${PYTORCH_MODULE}
        cd /tmp/eessi-pytorch-mp
        nohup python3 /tmp/pytorch_mp_migtest.py ${NWORKERS} >/tmp/pytorch_mp_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    show_both_nodes "baseline, before outbound migration" "pytorch_mp_migtest"
    show_threads "pytorch_mp_migtest" "$NODE1"
    echo "  Log tail from $NODE1:"
    run_on "$NODE1" "tail -3 /tmp/pytorch_mp_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    EPOCHS_BEFORE=$(last_epoch)
    if [ "$EPOCHS_BEFORE" -lt 1 ]; then
        fail "pytorch-mp-2: job never started producing output on $NODE1 -- nothing to migrate"
        run_on "$NODE1" "cat /tmp/pytorch_mp_migtest.log" | sed 's/^/    /' || true
    else
    do_migrate "python3 (PyTorch mp)" "$JOB_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    wait_running "pytorch_mp_migtest" "$NODE2" 120 || true
    sleep 3

    show_both_nodes "after outbound migration ($NODE1 -> $NODE2)" "pytorch_mp_migtest"
    show_threads "pytorch_mp_migtest" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
    if is_actually_running "pytorch_mp_migtest" "$NODE2"; then
        pass "pytorch-mp-2: multi-process PyTorch job migrated to $NODE2"
        # Baseline AFTER arrival, not before the migrate command: the workers
        # are separate processes that keep running (and bumping the shared
        # counters) on $NODE1 while the parent's pages are still in flight,
        # so a pre-migration baseline makes a frozen parent look like progress.
        EPOCHS_BEFORE=$(last_epoch)
        sleep 15
        show_both_nodes "15s after outbound migration (settled state)" "pytorch_mp_migtest"
        EPOCHS_AFTER=$(last_epoch)
        echo "  Log tail:"
        run_on "$NODE1" "tail -3 /tmp/pytorch_mp_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        if [ "$EPOCHS_AFTER" -le "$EPOCHS_BEFORE" ]; then
            fail "pytorch-mp-2: running on $NODE2 but shared-memory progress did not advance (epoch $EPOCHS_BEFORE -> $EPOCHS_AFTER) -- workers likely no longer share memory with the migrated parent -- alive but not making progress"
        else
            pass "pytorch-mp-2: job still progressing on $NODE2 (epoch $EPOCHS_BEFORE -> $EPOCHS_AFTER)"

            # Return leg: "home" must be issued on the home node with the
            # original PID (see test-eessi-pytorch.sh for why).
            do_migrate "python3 (PyTorch mp)" "$JOB_PID" "$NODE1" "$NODE1" "home" "$NODE2"
            wait_running "pytorch_mp_migtest" "$NODE1" 120 || true
            sleep 3
            show_both_nodes "after return migration ($NODE2 -> $NODE1)" "pytorch_mp_migtest"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
            if is_actually_running "pytorch_mp_migtest" "$NODE1"; then
                pass "pytorch-mp-3: multi-process PyTorch job migrated back to $NODE1"
                EPOCHS_RETURN=$(last_epoch)
                sleep 15
                EPOCHS_FINAL=$(last_epoch)
                if [ "$EPOCHS_FINAL" -le "$EPOCHS_RETURN" ]; then
                    fail "pytorch-mp-3: back on $NODE1 but shared-memory progress did not advance (epoch $EPOCHS_RETURN -> $EPOCHS_FINAL)"
                else
                    pass "pytorch-mp-3: round trip complete, still progressing ($EPOCHS_RETURN -> $EPOCHS_FINAL)"
                fi
            else
                fail "pytorch-mp-3: job not running on $NODE1 after return migration"
            fi
        fi
    else
        fail "pytorch-mp-2: multi-process PyTorch job not running on $NODE2 after migration"
        echo "  dmesg tail on $NODE1:"
        run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
    fi
    fi

    # Bracket trick so pkill doesn't match its own remote shell.
    run_on "$NODE1" "kill -9 $JOB_PID 2>/dev/null || true; pkill -9 -f '[p]ytorch_mp_migtest' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[p]ytorch_mp_migtest' 2>/dev/null || true"

    for n in "$NODE1:$DMESG_CURSOR_NODE1" "$NODE2:$DMESG_CURSOR_NODE2"; do
        if no_new_oops "${n%%:*}" "${n#*:}"; then
            pass "pytorch-mp-3: no kernel oops on ${n%%:*}"
        else
            fail "pytorch-mp-3: kernel oops on ${n%%:*}"
        fi
    done
fi

echo ""
echo "=============================="
echo "PyTorch-MP Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
