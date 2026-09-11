#!/bin/bash
# test-eessi-tensorflow.sh <alma|deb|ubu>
# Run TensorFlow tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + TensorFlow module loads
# Test 2: run the eessi-demo MNIST smoke test (functional CPU training run)
# Test 3: migrate a running training loop via MattX
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

auto_report_wrap "eessi-tensorflow" "$@"

init_cluster "$DISTRO"

EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
# Only known EESSI module for 2023.06 (foss-2023a toolchain -- CPU build,
# no CUDA in the module name at all; TensorFlow has legitimate CPU-only
# builds and this is one of them, so don't skip TF as "GPU-only").
TENSORFLOW_MODULE="TensorFlow/2.13.0-foss-2023a"

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
# `ps -eo` row can only show the state of the thread-group leader; TensorFlow
# spawns intra-op/inter-op worker threads under the same PID, which can keep
# running/idling while the leader is genuinely frozen by
# mattx_freeze_task_safely() (mattx_migr.c). This is the evidence that
# distinguishes "the Deputy is truly frozen" from "the process looks idle in
# aggregate."
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
    run_on "$NODE1" "kill -9 ${JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[t]ensorflow_migtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[t]ensorflow_migtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== TensorFlow / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + TensorFlow module load ----
echo "=== Test 1: EESSI TensorFlow module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${TENSORFLOW_MODULE}
    CUDA_VISIBLE_DEVICES='' python3 -c 'import tensorflow as tf; print(tf.__version__); print(\"GPUs:\", tf.config.list_physical_devices(\"GPU\"))'
"; then
    pass "tensorflow-1: TensorFlow module (${TENSORFLOW_MODULE}) loads on $NODE1"
else
    fail "tensorflow-1: TensorFlow module (${TENSORFLOW_MODULE}) failed to load on $NODE1"
fi

# ---- Test 2: eessi-demo MNIST smoke test (functional CPU training run) ----
echo ""
echo "=== Test 2: MNIST smoke test (functional, CPU-only) ==="

echo "  Syncing demo scripts to $NODE1..."
rsync_to "$TEST_DIR/eessi-demo/TensorFlow/" "$NODE1" "/tmp/eessi-tensorflow/"

echo "  Running MNIST smoke test on $NODE1 ($(node_ip "$NODE1"))..."
if run_on "$NODE1" "
    set -e
    cd /tmp/eessi-tensorflow
    source '${EESSI_INIT}'
    module load ${TENSORFLOW_MODULE}
    export CUDA_VISIBLE_DEVICES=''
    timeout 300 python3 TensorFlow-2.x_mnist-test.py
" 2>&1; then
    pass "tensorflow-2: MNIST smoke test completed on $NODE1"
else
    fail "tensorflow-2: MNIST smoke test failed or timed out on $NODE1 (check network access for dataset download)"
fi

# ---- Test 3: Training-loop migration via MattX ----
echo ""
echo "=== Test 3: TensorFlow training-loop migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "tensorflow-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    # Upload a single-process, long-running training loop. Uses synthetic
    # data (no network dependency at migration time -- Test 2 already
    # proved the real MNIST download path works) so the migration window
    # timing doesn't depend on network reachability. Deliberately left
    # multi-threaded (TensorFlow's default intra-op/inter-op thread pools)
    # rather than pinned to 1 thread: this is what a real TensorFlow
    # workload actually looks like, and MattX's known multi-threaded Gang
    # migration reliability issue (see mattx#7, docs/BUGS.md BUG-008) is
    # exactly what real multi-threaded workloads like this one need to
    # keep exercising, not something to route around here.
    run_on "$NODE1" "cat > /tmp/tensorflow_migtest.py" <<'PYEOF'
import os
os.environ["CUDA_VISIBLE_DEVICES"] = ""

import time
import numpy as np
import tensorflow as tf

tf.config.set_visible_devices([], "GPU")

print("TensorFlow migtest PID={} starting on {}".format(os.getpid(), os.uname().nodename), flush=True)

# Small synthetic MNIST-shaped dataset -- no network dependency, and small
# enough to comfortably fit/train on a 2-vCPU, ~2GB test VM.
rng = np.random.default_rng(0)
x_train = rng.random((512, 28, 28), dtype=np.float32)
y_train = rng.integers(0, 10, size=(512,))

model = tf.keras.models.Sequential([
    tf.keras.layers.Flatten(input_shape=(28, 28)),
    tf.keras.layers.Dense(128, activation="relu"),
    tf.keras.layers.Dropout(0.2),
    tf.keras.layers.Dense(10, activation="softmax"),
])
model.compile(optimizer="adam", loss="sparse_categorical_crossentropy", metrics=["accuracy"])

EPOCHS = 200
for epoch in range(1, EPOCHS + 1):
    history = model.fit(x_train, y_train, epochs=1, batch_size=64, verbose=0)
    loss = history.history["loss"][0]
    if epoch % 5 == 0:
        print("epoch {}/{}  node={}  pid={}  loss={:.4f}".format(
            epoch, EPOCHS, os.uname().nodename, os.getpid(), loss), flush=True)
    time.sleep(0.5)

print("TensorFlow migtest DONE on {}".format(os.uname().nodename), flush=True)
PYEOF

    echo "  Starting training loop on $NODE1 ($(node_ip "$NODE1"))..."
    # EESSI/Lmod init prints banner lines to stdout, so `echo $!` is not
    # necessarily the only line captured — take the last line to isolate it.
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ${TENSORFLOW_MODULE}
        nohup python3 /tmp/tensorflow_migtest.py >/tmp/tensorflow_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    if ! run_on "$NODE1" "kill -0 $JOB_PID 2>/dev/null"; then
        fail "tensorflow-3: training loop exited before migration window — check /tmp/tensorflow_migtest.log"
        run_on "$NODE1" "tail -20 /tmp/tensorflow_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    else
        show_both_nodes "baseline, before outbound migration" "tensorflow_migtest"
        show_threads "tensorflow_migtest" "$NODE1"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 /tmp/tensorflow_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        EPOCHS_BEFORE=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/tensorflow_migtest.log 2>/dev/null || echo 0")

        do_migrate "tensorflow_migtest" "$JOB_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 20

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "tensorflow_migtest"
        show_threads "tensorflow_migtest" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "tensorflow_migtest" "$NODE2"; then
            echo "  Log tail (stdout forwarded via MattX wormhole):"
            run_on "$NODE1" "tail -5 /tmp/tensorflow_migtest.log 2>/dev/null || true" | sed 's/^/    /'
            pass "tensorflow-3: training loop migrated to $NODE2"

            sleep 15
            show_both_nodes "15s after outbound migration (settled state)" "tensorflow_migtest"
            STAT2=$(process_stat "tensorflow_migtest" "$NODE2")
            EPOCHS_AFTER=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/tensorflow_migtest.log 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$EPOCHS_AFTER" -le "$EPOCHS_BEFORE" ]; then
                fail "tensorflow-3: training loop present and running on $NODE2, but epoch count did not advance ($EPOCHS_BEFORE -> $EPOCHS_AFTER) -- looks alive but not making progress"
            elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                pass "tensorflow-3: training loop still running on $NODE2 after 15s (epochs $EPOCHS_BEFORE -> $EPOCHS_AFTER)"

                # ---- Return leg: recall home, NODE2 -> NODE1 ----
                # The "home" recall path (admin_write's "migrate <pid> home"
                # -> mattx_trigger_recall) is DIFFERENT from the generic
                # "migrate <pid> <node>" path and must be issued ON THE HOME
                # NODE ($NODE1), using the ORIGINAL PID ($JOB_PID) --
                # mattx_trigger_recall() looks up the export_registry entry
                # for orig_pid, which only exists on the node that originally
                # exported it, then sends a RECALL_REQ to wherever the guest
                # currently lives. Using $NODE2/the Surrogate's local PID
                # here (as the generic migrate path requires) instead hits
                # "PID is not in the export registry. Cannot recall" -- or,
                # if sent as a plain numeric-node migrate instead of "home",
                # silently takes the generic forward-migrate path, which
                # doesn't handle re-targeting a PID that already has a stale
                # Deputy/registry entry on the destination and can crash the
                # process right after wake.
                do_migrate "tensorflow_migtest" "$JOB_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 20

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "tensorflow_migtest"
                show_threads "tensorflow_migtest" "$NODE2"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "tensorflow_migtest" "$NODE1"; then
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 /tmp/tensorflow_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                    pass "tensorflow-4: training loop migrated back to $NODE1"

                    EPOCHS_RETURN=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/tensorflow_migtest.log 2>/dev/null || echo 0")
                    sleep 15
                    show_both_nodes "15s after return migration (settled state)" "tensorflow_migtest"
                    STAT4=$(process_stat "tensorflow_migtest" "$NODE1")
                    EPOCHS_FINAL=$(run_on "$NODE1" "grep -c '^epoch ' /tmp/tensorflow_migtest.log 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$EPOCHS_FINAL" -le "$EPOCHS_RETURN" ]; then
                        fail "tensorflow-4: training loop present and running on $NODE1, but epoch count did not advance ($EPOCHS_RETURN -> $EPOCHS_FINAL) -- looks alive but not making progress"
                    elif [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "tensorflow-4: training loop still running on $NODE1 after 15s (round trip complete, epochs $EPOCHS_RETURN -> $EPOCHS_FINAL)"
                    elif [ -n "$STAT4" ]; then
                        fail "tensorflow-4: training loop present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► training loop [PID $JOB_PID] completed on $NODE1 after returning"
                        pass "tensorflow-4: training loop ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "tensorflow-4: training loop not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [ -n "$STAT2" ]; then
                fail "tensorflow-3: training loop present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► training loop [PID $JOB_PID] completed on $NODE2 before the return leg could start"
                pass "tensorflow-3: training loop ran to completion on $NODE2"
                fail "tensorflow-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase EPOCHS if this recurs)"
            fi
        else
            fail "tensorflow-3: training loop not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi

        # pkill -9 -f matches its OWN argv too (which literally contains
        # "tensorflow_migtest"), so an unguarded pattern kills its own
        # remote shell/SSH session before "|| true" ever gets a chance to
        # run -- use the standard bracket trick to keep it from
        # self-matching.
        run_on "$NODE1" "kill -9 $JOB_PID 2>/dev/null || true; pkill -9 -f '[t]ensorflow_migtest' 2>/dev/null || true"
        run_on "$NODE2" "pkill -9 -f '[t]ensorflow_migtest' 2>/dev/null || true"
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "tensorflow-4: no kernel oops on $NODE1"
    else
        fail "tensorflow-4: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "tensorflow-4: no kernel oops on $NODE2"
    else
        fail "tensorflow-4: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "TensorFlow Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
