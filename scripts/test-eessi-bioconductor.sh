#!/bin/bash
# test-eessi-bioconductor.sh <alma|deb|ubu>
# Run Bioconductor tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + R-bundle-Bioconductor module loads
# Test 2: run a real Biostrings computation (functional check)
# Test 3: migrate a running single-process Bioconductor job via MattX
#
# Unlike the demo's own dna.R (eessi-demo/Bioconductor/dna.R), this does NOT
# use AnnotationHub -- that fetches multi-GB reference genome data over the
# network on first use, which is both a one-shot operation (nothing to catch
# mid-migration) and a bad fit for a test that should work offline/isolated.
# Instead this generates its own random DNA sequence and repeatedly runs
# Biostrings::pairwiseAlignment() (a real Needleman-Wunsch dynamic-programming
# alignment, not a toy computation) against a freshly point-mutated copy each
# iteration, pacing itself with an explicit sleep like the ESPResSo test does
# with its own integrator loop.
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

auto_report_wrap "eessi-bioconductor" "$@"

init_cluster "$DISTRO"

# Prefer the newer EESSI version if available, fall back to 2023.06
EESSI_VERSION="${EESSI_VERSION:-}"
if [ -z "$EESSI_VERSION" ]; then
    if run_on "$NODE1" "test -d /cvmfs/software.eessi.io/versions/2025.06" 2>/dev/null; then
        EESSI_VERSION="2025.06"
    else
        EESSI_VERSION="2023.06"
    fi
fi
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"

# Matches eessi-demo/Bioconductor/run.sh's own version mapping.
case "$EESSI_VERSION" in
    2025.06) BIOC_MODULE="R-bundle-Bioconductor/3.20-foss-2024a-R-4.4.2" ;;
    *)       BIOC_MODULE="R-bundle-Bioconductor/3.16-foss-2022b-R-4.2.2" ;;
esac

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
    run_on "$NODE1" "kill -9 ${JOB_PID:-} 2>/dev/null || true; pkill -9 -f '[b]ioconductor_migtest' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[b]ioconductor_migtest' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== Bioconductor / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + R-bundle-Bioconductor module load ----
echo "=== Test 1: EESSI Bioconductor module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${BIOC_MODULE}
    Rscript -e 'library(Biostrings); cat(as.character(packageVersion(\"Biostrings\")), \"\n\")'
"; then
    pass "bioconductor-1: R-bundle-Bioconductor (${BIOC_MODULE}) loads on $NODE1"
else
    fail "bioconductor-1: R-bundle-Bioconductor (${BIOC_MODULE}) failed to load on $NODE1"
fi

# ---- Test 2: functional Biostrings computation ----
echo ""
echo "=== Test 2: Biostrings pairwise alignment (functional check) ==="

BIOC_WORKDIR="/tmp/eessi-bioconductor"
run_on "$NODE1" "mkdir -p $BIOC_WORKDIR"

run_on "$NODE1" "cat > $BIOC_WORKDIR/functional_check.R" <<'REOF'
suppressMessages(library(Biostrings))
set.seed(1)
bases <- c("A", "C", "G", "T")
seq1 <- DNAString(paste(sample(bases, 2000, replace = TRUE), collapse = ""))
seq2 <- DNAString(paste(sample(bases, 2000, replace = TRUE), collapse = ""))
aln <- pairwiseAlignment(seq1, seq2, type = "global")
cat("Alignment score:", score(aln), "\n")
REOF

if run_on "$NODE1" "
    set -e
    cd $BIOC_WORKDIR
    source '${EESSI_INIT}'
    module load ${BIOC_MODULE}
    timeout 120 Rscript functional_check.R
"; then
    pass "bioconductor-2: Biostrings pairwiseAlignment completed on $NODE1"
else
    fail "bioconductor-2: Biostrings pairwiseAlignment failed or timed out on $NODE1"
fi

# ---- Test 3: single-process Bioconductor migration via MattX ----
echo ""
echo "=== Test 3: Bioconductor migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "bioconductor-3: MattX not running on $NODE1/$NODE2 — run 'make ${DISTRO}cluster' first"
else
    # Upload a single-process, long-running Bioconductor job: repeatedly
    # point-mutate a DNA sequence and run a real Biostrings pairwiseAlignment
    # against the mutated copy each tick, printing the alignment score.
    # sample()/rnorm() etc. are R's own RNG, not a syscall, so nothing here
    # needs the wormhole -- this is a pure CPU-bound single-threaded job,
    # deliberately avoiding the multi-threaded Gang wake path (see mattx#7
    # follow-on: BUG-008 in docs/BUGS.md).
    run_on "$NODE1" "cat > /tmp/bioconductor_migtest.R" <<'REOF'
suppressMessages(library(Biostrings))
pid <- Sys.getpid()
node <- Sys.info()[["nodename"]]
cat(sprintf("bioconductor_migtest PID=%d starting on %s\n", pid, node))
flush(stdout())

set.seed(42)
bases <- c("A", "C", "G", "T")
seq_len <- 2000
ticks <- 600
reference <- DNAString(paste(sample(bases, seq_len, replace = TRUE), collapse = ""))
current <- reference

for (i in 1:ticks) {
    # Introduce a handful of random point mutations each tick, then align
    # the mutated sequence back against the original reference -- a real
    # Needleman-Wunsch dynamic-programming alignment via Biostrings' C
    # backend, not a toy loop.
    mut_positions <- sample(seq_len, 5)
    current_chars <- strsplit(as.character(current), "")[[1]]
    current_chars[mut_positions] <- sample(bases, 5, replace = TRUE)
    current <- DNAString(paste(current_chars, collapse = ""))

    aln <- pairwiseAlignment(reference, current, type = "global")
    if (i %% 10 == 0) {
        cat(sprintf("tick %d/%d  node=%s  pid=%d  score=%.2f\n",
                     i, ticks, node, pid, score(aln)))
        flush(stdout())
    }
    Sys.sleep(1)
}

cat(sprintf("bioconductor_migtest DONE on %s\n", node))
flush(stdout())
REOF

    echo "  Starting Bioconductor migtest on $NODE1 ($(node_ip "$NODE1"))..."
    # EESSI/Lmod init prints banner lines to stdout, so `echo $!` is not
    # necessarily the only line captured — take the last line to isolate it.
    JOB_PID=$(run_on "$NODE1" "
        source '${EESSI_INIT}'
        module load ${BIOC_MODULE}
        nohup Rscript /tmp/bioconductor_migtest.R >/tmp/bioconductor_migtest.log 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    if ! run_on "$NODE1" "kill -0 $JOB_PID 2>/dev/null"; then
        fail "bioconductor-3: bioconductor_migtest exited before migration window — check /tmp/bioconductor_migtest.log"
        run_on "$NODE1" "tail -20 /tmp/bioconductor_migtest.log 2>/dev/null || true" | sed 's/^/    /'
    else
        show_both_nodes "baseline, before outbound migration" "bioconductor_migtest"
        echo "  Log tail from $NODE1:"
        run_on "$NODE1" "tail -5 /tmp/bioconductor_migtest.log 2>/dev/null || true" | sed 's/^/    /'
        TICKS_BEFORE=$(run_on "$NODE1" "grep -c '^tick ' /tmp/bioconductor_migtest.log 2>/dev/null || echo 0")

        do_migrate "bioconductor_migtest" "$JOB_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "bioconductor_migtest"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "bioconductor_migtest" "$NODE2"; then
            echo "  Log tail (stdout forwarded via MattX wormhole):"
            run_on "$NODE1" "tail -5 /tmp/bioconductor_migtest.log 2>/dev/null || true" | sed 's/^/    /'
            pass "bioconductor-3: bioconductor_migtest migrated to $NODE2"

            sleep 15
            show_both_nodes "15s after outbound migration (settled state)" "bioconductor_migtest"
            STAT2=$(process_stat "bioconductor_migtest" "$NODE2")
            TICKS_AFTER=$(run_on "$NODE1" "grep -c '^tick ' /tmp/bioconductor_migtest.log 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$TICKS_AFTER" -le "$TICKS_BEFORE" ]; then
                fail "bioconductor-3: bioconductor_migtest present and running on $NODE2, but tick count did not advance ($TICKS_BEFORE -> $TICKS_AFTER) -- looks alive but not making progress"
            elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                pass "bioconductor-3: bioconductor_migtest still running on $NODE2 after 15s (ticks $TICKS_BEFORE -> $TICKS_AFTER)"

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
                do_migrate "bioconductor_migtest" "$JOB_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "bioconductor_migtest"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "bioconductor_migtest" "$NODE1"; then
                    echo "  Log tail (stdout forwarded via MattX wormhole):"
                    run_on "$NODE1" "tail -5 /tmp/bioconductor_migtest.log 2>/dev/null || true" | sed 's/^/    /'
                    pass "bioconductor-4: bioconductor_migtest migrated back to $NODE1"

                    TICKS_RETURN=$(run_on "$NODE1" "grep -c '^tick ' /tmp/bioconductor_migtest.log 2>/dev/null || echo 0")
                    sleep 15
                    show_both_nodes "15s after return migration (settled state)" "bioconductor_migtest"
                    STAT4=$(process_stat "bioconductor_migtest" "$NODE1")
                    TICKS_FINAL=$(run_on "$NODE1" "grep -c '^tick ' /tmp/bioconductor_migtest.log 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$TICKS_FINAL" -le "$TICKS_RETURN" ]; then
                        fail "bioconductor-4: bioconductor_migtest present and running on $NODE1, but tick count did not advance ($TICKS_RETURN -> $TICKS_FINAL) -- looks alive but not making progress"
                    elif [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]]; then
                        pass "bioconductor-4: bioconductor_migtest still running on $NODE1 after 15s (round trip complete, ticks $TICKS_RETURN -> $TICKS_FINAL)"
                    elif [ -n "$STAT4" ]; then
                        fail "bioconductor-4: bioconductor_migtest present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► bioconductor_migtest [PID $JOB_PID] completed on $NODE1 after returning"
                        pass "bioconductor-4: bioconductor_migtest ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "bioconductor-4: bioconductor_migtest not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [ -n "$STAT2" ]; then
                fail "bioconductor-3: bioconductor_migtest present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► bioconductor_migtest [PID $JOB_PID] completed on $NODE2 before the return leg could start"
                pass "bioconductor-3: bioconductor_migtest ran to completion on $NODE2"
                fail "bioconductor-4: cannot perform return-leg migration — job completed on $NODE2 before it could be migrated back (increase tick count if this recurs)"
            fi
        else
            fail "bioconductor-3: bioconductor_migtest not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi

        # pkill -9 -f matches its OWN argv too (which literally contains
        # "bioconductor_migtest"), so an unguarded pattern kills its own
        # remote shell/SSH session before "|| true" ever gets a chance to
        # run -- use the standard bracket trick to keep it from self-matching.
        run_on "$NODE1" "kill -9 $JOB_PID 2>/dev/null || true; pkill -9 -f '[b]ioconductor_migtest' 2>/dev/null || true"
        run_on "$NODE2" "pkill -9 -f '[b]ioconductor_migtest' 2>/dev/null || true"
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "bioconductor-4: no kernel oops on $NODE1"
    else
        fail "bioconductor-4: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "bioconductor-4: no kernel oops on $NODE2"
    else
        fail "bioconductor-4: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "Bioconductor Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
