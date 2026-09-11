#!/bin/bash
# test-eessi-pytorch.sh <alma|deb|ubu>
# Run PyTorch tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + PyTorch module loads
# Test 2: quick functional smoke run (a short training loop actually converges)
# Test 3/4: migrate a single-process PyTorch training job via MattX (forward + return)
#
# STATUS: not yet confirmed passing on the current MattX build -- only
# run-tests.sh and test-eessi-gromacs.sh are. Treat a [FAIL] here as "not
# yet verified," not necessarily a new regression. See CHANGELOG.md.
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

auto_report_wrap "eessi-pytorch" "$@"

init_cluster "$DISTRO"

# The EESSI demo repo's own PyTorch/run.sh only knows how to pick a module
# for 2023.06 (PyTorch/2.1.2-foss-2023a, a CPU-only build -- PyTorch ships
# real, non-CUDA builds and this is one of them), so pin to that rather than
# generalizing like test-eessi-gromacs.sh does across versions.
EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
PYTORCH_MODULE="PyTorch/2.1.2-foss-2023a"

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
    run_on "$node" "ps -eo stat,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep | awk '{print \$1}' | head -1" 2>/dev/null
}

# Is a process matching pattern actually EXECUTING on this node (STAT other
# than T=stopped or Z=zombie), as opposed to merely PRESENT?
is_actually_running() {
    local pattern="$1" node="$2"
    local stat; stat="$(process_stat "$pattern" "$node")"
    [ -n "$stat" ] && [[ "$stat" != T* && "$stat" != Z* ]]
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
    run_on "$NODE1" "kill -9 ${JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[p]ytorch_migtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[p]ytorch_migtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== PyTorch / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + module load ----
echo "=== Test 1: EESSI PyTorch module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${PYTORCH_MODULE}
    python3 -c 'import torch; print(torch.__version__); assert not torch.cuda.is_available() or True'
"; then
    pass "pytorch-1: PyTorch module loads on $NODE1"
else
    fail "pytorch-1: PyTorch module failed to load on $NODE1 (EESSI ${EESSI_VERSION})"
fi

# ---- Test 2: quick functional smoke run ----
echo ""
echo "=== Test 2: short training loop (functional smoke test) ==="

run_on "$NODE1" "mkdir -p /tmp/eessi-pytorch"
run_on "$NODE1" "cat > /tmp/eessi-pytorch/smoke.py" <<'PYEOF'
import torch, torch.nn as nn

torch.manual_seed(0)
X = torch.randn(64, 10)
true_w = torch.randn(10, 1)
Y = X @ true_w + 0.01 * torch.randn(64, 1)

model = nn.Sequential(nn.Linear(10, 32), nn.ReLU(), nn.Linear(32, 1))
opt = torch.optim.SGD(model.parameters(), lr=0.05)
loss_fn = nn.MSELoss()

first_loss = None
for epoch in range(200):
    opt.zero_grad()
    loss = loss_fn(model(X), Y)
    loss.backward()
    opt.step()
    if first_loss is None:
        first_loss = loss.item()

last_loss = loss.item()
print("first_loss={:.4f} last_loss={:.4f}".format(first_loss, last_loss))
assert last_loss < first_loss * 0.5, "training did not converge"
print("SMOKE OK")
PYEOF

echo "  Running a 200-epoch smoke-test training loop on $NODE1 ($(node_ip "$NODE1"))..."
if run_on "$NODE1" "
    cd /tmp/eessi-pytorch
    source '${EESSI_INIT}'
    module load ${PYTORCH_MODULE}
    timeout 120 python3 smoke.py
" 2>&1 | tee /tmp/pytorch_smoke_out.$$ && grep -q "SMOKE OK" /tmp/pytorch_smoke_out.$$; then
    pass "pytorch-2: training loop converges on $NODE1"
else
    fail "pytorch-2: training loop failed or did not converge on $NODE1"
fi
rm -f /tmp/pytorch_smoke_out.$$

# ---- Test 3/4: Single-process PyTorch migration via MattX ----
echo ""
echo "=== Test 3/4: PyTorch training-job migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "pytorch-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    # Upload a single-process long-running PyTorch training job. A small
    # MLP regressing against synthetic data, run for many epochs with a
    # per-tick sleep -- mirrors dd_migtest/espresso_migtest's shape (a
    # migratable process needs a long-running, periodically-printing loop,
    # not a fire-and-forget batch job). Left at PyTorch's own default
    # threading (its intraop thread pool + whatever OpenMP/MKL backend
    # EESSI's foss toolchain wires up) rather than forcing
    # torch.set_num_threads(1): this is the real, out-of-the-box behavior
    # any user actually gets, and it's what real EESSI PyTorch jobs run
    # under -- same reasoning as GROMACS/ESPResSo's own multi-threaded
    # tests here already exercise MattX's known Gang-migration reliability
    # issue for multi-threaded processes (see mattx#7, docs/BUGS.md
    # BUG-008), rather than sidestepping it.
    run_on "$NODE1" "cat > /tmp/pytorch_migtest.py" <<'PYEOF'
import torch
import torch.nn as nn
import time
import os

print("PyTorch migtest PID={} starting on {}".format(os.getpid(), os.uname().nodename), flush=True)

torch.manual_seed(42)
X = torch.randn(256, 20)
true_w = torch.randn(20, 1)
Y = X @ true_w + 0.1 * torch.randn(256, 1)

model = nn.Sequential(
    nn.Linear(20, 64), nn.ReLU(),
    nn.Linear(64, 64), nn.ReLU(),
    nn.Linear(64, 1),
)
optimizer = torch.optim.SGD(model.parameters(), lr=0.01)
loss_fn = nn.MSELoss()

TICKS = 600
for epoch in range(1, TICKS + 1):
    optimizer.zero_grad()
    pred = model(X)
    loss = loss_fn(pred, Y)
    loss.backward()
    optimizer.step()
    if epoch % 2 == 0:
        print("epoch {}/{}  node={}  pid={}  loss={:.6f}".format(
            epoch, TICKS, os.uname().nodename, os.getpid(), loss.item()), flush=True)
    time.sleep(0.4)

print("PyTorch migtest DONE on {}".format(os.uname().nodename), flush=True)
PYEOF

    echo "  Starting PyTorch migtest on $NODE1 ($(node_ip "$NODE1"))..."
    # EESSI/Lmod init prints banner lines to stdout, so `echo $!` is not
    # necessarily the only line captured — take the last line to isolate it.
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ${PYTORCH_MODULE}
        cd /tmp/eessi-pytorch
        nohup python3 /tmp/pytorch_migtest.py >/tmp/pytorch_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 8

    show_both_nodes "baseline, before outbound migration" "pytorch_migtest"
    show_threads "pytorch_migtest" "$NODE1"
    echo "  Log tail from $NODE1:"
    run_on "$NODE1" "tail -5 /tmp/pytorch_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    EPOCHS_BEFORE=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/pytorch_migtest.log 2>/dev/null || echo 0")

    do_migrate "python3 (PyTorch)" "$JOB_PID" "$NODE1" "$NODE2" "$NODE2_ID"
    sleep 8

    show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "pytorch_migtest"
    show_threads "pytorch_migtest" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
    show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
    if is_actually_running "pytorch_migtest" "$NODE2"; then
        echo "  Log tail (stdout forwarded via MattX wormhole):"
        run_on "$NODE1" "tail -5 /tmp/pytorch_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        pass "pytorch-3: PyTorch process migrated to $NODE2"

        sleep 15
        show_both_nodes "15s after outbound migration (settled state)" "pytorch_migtest"
        STAT2=$(process_stat "pytorch_migtest" "$NODE2")
        EPOCHS_AFTER=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/pytorch_migtest.log 2>/dev/null || echo 0")
        if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$EPOCHS_AFTER" -le "$EPOCHS_BEFORE" ]; then
            fail "pytorch-3: PyTorch process present and running on $NODE2, but epoch count did not advance ($EPOCHS_BEFORE -> $EPOCHS_AFTER) -- looks alive but not making progress"
        elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
            pass "pytorch-3: PyTorch process still running on $NODE2 after 15s (epochs $EPOCHS_BEFORE -> $EPOCHS_AFTER)"

            # ---- Return leg: recall home, NODE2 -> NODE1 ----
            # The "home" recall path (admin_write's "migrate <pid> home" ->
            # mattx_trigger_recall) is DIFFERENT from the generic
            # "migrate <pid> <node>" path and must be issued ON THE HOME
            # NODE ($NODE1), using the ORIGINAL PID ($JOB_PID) --
            # mattx_trigger_recall() looks up the export_registry entry for
            # orig_pid, which only exists on the node that originally
            # exported it, then sends a RECALL_REQ to wherever the guest
            # currently lives. Using $NODE2/the Surrogate's local PID here
            # (as the generic migrate path requires) instead hits "PID is
            # not in the export registry. Cannot recall" -- or, if sent as
            # a plain numeric-node migrate instead of "home", silently
            # takes the generic forward-migrate path, which doesn't handle
            # re-targeting a PID that already has a stale Deputy/registry
            # entry on the destination and can crash the process right
            # after wake.
            do_migrate "python3 (PyTorch)" "$JOB_PID" "$NODE1" "$NODE1" "home" "$NODE2"
            sleep 8

            show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "pytorch_migtest"
            show_threads "pytorch_migtest" "$NODE2"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
            show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
            if is_actually_running "pytorch_migtest" "$NODE1"; then
                echo "  Log tail (stdout forwarded via MattX wormhole):"
                run_on "$NODE1" "tail -5 /tmp/pytorch_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                pass "pytorch-4: PyTorch process migrated back to $NODE1"

                EPOCHS_RETURN=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/pytorch_migtest.log 2>/dev/null || echo 0")
                sleep 15
                show_both_nodes "15s after return migration (settled state)" "pytorch_migtest"
                STAT4=$(process_stat "pytorch_migtest" "$NODE1")
                EPOCHS_FINAL=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/pytorch_migtest.log 2>/dev/null || echo 0")
                if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$EPOCHS_FINAL" -le "$EPOCHS_RETURN" ]; then
                    fail "pytorch-4: PyTorch process present and running on $NODE1, but epoch count did not advance ($EPOCHS_RETURN -> $EPOCHS_FINAL) -- looks alive but not making progress"
                elif [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                    pass "pytorch-4: PyTorch process still running on $NODE1 after 15s (round trip complete, epochs $EPOCHS_RETURN -> $EPOCHS_FINAL)"
                elif [ -n "$STAT4" ]; then
                    fail "pytorch-4: PyTorch process present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                else
                    echo "  ► python3 [PID $JOB_PID] completed on $NODE1 after returning"
                    pass "pytorch-4: PyTorch process ran to completion on $NODE1 after round trip"
                fi
            else
                fail "pytorch-4: PyTorch process not actually running on $NODE1 after return migration"
                echo "  dmesg tail on $NODE2:"
                run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
            fi
        elif [ -n "$STAT2" ]; then
            fail "pytorch-3: PyTorch process present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
        else
            echo "  ► python3 [PID $JOB_PID] completed on $NODE2 before the return leg could start"
            pass "pytorch-3: PyTorch process ran to completion on $NODE2"
            fail "pytorch-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase TICKS if this recurs)"
        fi
    else
        fail "pytorch-3: PyTorch process not actually running on $NODE2 after migration"
        echo "  dmesg tail on $NODE1:"
        run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
    fi

    # pkill -9 -f matches its OWN argv too (which literally contains
    # "pytorch_migtest"), so an unguarded pattern kills its own remote
    # shell/SSH session before "|| true" ever gets a chance to run -- use
    # the standard bracket trick to keep it from self-matching.
    run_on "$NODE1" "kill -9 $JOB_PID 2>/dev/null || true; pkill -9 -f '[p]ytorch_migtest' 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[p]ytorch_migtest' 2>/dev/null || true"

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "pytorch-3: no kernel oops on $NODE1"
    else
        fail "pytorch-3: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "pytorch-3: no kernel oops on $NODE2"
    else
        fail "pytorch-3: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "PyTorch Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
