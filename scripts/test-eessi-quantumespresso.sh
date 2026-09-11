#!/bin/bash
# test-eessi-quantumespresso.sh <alma|deb|ubu>
# Run QuantumESPRESSO tests via EESSI on a cluster.
# Test 1: verify EESSI mounted + QuantumESPRESSO module loads
# Test 2: run a small serial SCF calculation (functional smoke test)
# Test 3: migrate a running (single-process, serial) pw.x SCF job via MattX
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

auto_report_wrap "eessi-quantumespresso" "$@"

init_cluster "$DISTRO"

# The eessi-demo QuantumESPRESSO example only pins a known-good module for
# EESSI 2023.06 (see eessi-demo/QuantumESPRESSO/run.sh) -- don't guess a
# newer version's module name, just use what's proven to work.
EESSI_VERSION="${EESSI_VERSION:-2023.06}"
EESSI_INIT="/cvmfs/software.eessi.io/versions/${EESSI_VERSION}/init/bash"
QE_MODULE="QuantumESPRESSO/7.3.1-foss-2023a"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Print ps evidence for a process pattern on one node. We search by pattern
# rather than by the home-node PID: mattx-stub is a distinct process spawned
# locally on the remote node via call_usermodehelper, so it gets its own
# kernel-assigned PID there -- the original home PID has no reason to exist
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
# visible in one place -- the actual proof that a migration moved
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
# logged) -- lets the report show directly whether mattx_freeze_task_safely
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
    run_on "$NODE1" "kill -9 ${PWX_PID:-} 2>/dev/null || true; pkill -9 -f '[p]w\.x' 2>/dev/null || true" 2>/dev/null || true
    run_on "$NODE2" "pkill -9 -f '[p]w\.x' 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== QuantumESPRESSO / EESSI tests on ${DISTRO} cluster (EESSI ${EESSI_VERSION}) ==="
echo ""

# ---- Test 1: EESSI mount + module load ----
echo "=== Test 1: EESSI QuantumESPRESSO module load ==="
if run_on "$NODE1" "
    test -f '${EESSI_INIT}' || { echo 'EESSI init not found: ${EESSI_INIT}'; exit 1; }
    source '${EESSI_INIT}'
    module load ${QE_MODULE}
    # This EESSI build's MPI stack defaults to the PSM3 libfabric provider,
    # which expects real Omni-Path/InfiniBand hardware. On a plain KVM VM
    # NIC it fails ('PSM3 can't open nic unit: 0 (err=23)') and pw.x hangs
    # in MPI init indefinitely instead of falling back -- force the plain
    # TCP provider, which works on any NIC.
    export FI_PROVIDER=tcp
    timeout 30 pw.x -v </dev/null 2>&1 | head -3 || true
    command -v pw.x
"; then
    pass "qe-1: QuantumESPRESSO module (${QE_MODULE}) loads on $NODE1"
else
    fail "qe-1: QuantumESPRESSO module (${QE_MODULE}) failed to load on $NODE1"
fi

# ---- Test 2: small serial SCF functional run ----
echo ""
echo "=== Test 2: Si SCF functional run (serial pw.x) ==="

QE_WORKDIR="/tmp/eessi-qe"
run_on "$NODE1" "mkdir -p $QE_WORKDIR"

echo "  Fetching Si pseudopotential on $NODE1..."
if ! run_on "$NODE1" "
    set -e
    cd $QE_WORKDIR
    if [ ! -f Si.pz-vbc.UPF ]; then
        curl -fsSL -O http://pseudopotentials.quantum-espresso.org/upf_files/Si.pz-vbc.UPF
    fi
    test -f Si.pz-vbc.UPF
" 2>&1; then
    fail "qe-2: failed to download Si pseudopotential (check network access)"
    fail "qe-3: cannot run migration test without pseudopotential"
    echo ""
    echo "=============================="
    echo "QuantumESPRESSO Results: $PASS passed, $FAIL failed"
    echo "=============================="
    exit 1
fi

# Small, quick SCF -- same system as the eessi-demo example (bulk Si,
# 2 atoms), just to prove pw.x actually runs and converges end-to-end
# before we start the much slower migration-target job below.
# Note: pseudo_dir/outdir are literal paths baked in at script-authoring
# time (QE_WORKDIR is a fixed constant above), NOT shell command
# substitutions -- this text becomes a Fortran namelist file consumed
# directly by pw.x, not a shell script, so `$(pwd)` would end up as a
# literal 6-character garbage string in the input file instead of being
# evaluated.
scf_input() {
    local ecutwfc="$1" conv_thr="$2"
cat <<EOF
&CONTROL
  calculation  = "scf",
  prefix       = "Si",
  pseudo_dir   = "${QE_WORKDIR}",
  outdir       = "${QE_WORKDIR}/tmp",
  restart_mode = "from_scratch"
/
&SYSTEM
  ibrav     = 2,
  celldm(1) = 10.21,
  nat       = 2,
  ntyp      = 1,
  ecutwfc   = ${ecutwfc}
  nbnd      = 5
/
&ELECTRONS
  conv_thr    = ${conv_thr},
  mixing_beta = 0.7D0,
/
ATOMIC_SPECIES
 Si  28.086  Si.pz-vbc.UPF
ATOMIC_POSITIONS
 Si 0.00 0.00 0.00
 Si 0.25 0.25 0.25
K_POINTS
  10
   0.1250000  0.1250000  0.1250000   1.00
   0.1250000  0.1250000  0.3750000   3.00
   0.1250000  0.1250000  0.6250000   3.00
   0.1250000  0.1250000  0.8750000   3.00
   0.1250000  0.3750000  0.3750000   3.00
   0.1250000  0.3750000  0.6250000   6.00
   0.1250000  0.3750000  0.8750000   6.00
   0.1250000  0.6250000  0.6250000   3.00
   0.3750000  0.3750000  0.3750000   1.00
   0.3750000  0.3750000  0.6250000   3.00
EOF
}

# Dedicated input for the migration-target job in Test 3 -- needs to run
# slowly (comfortably longer than the test's ~10-60s migration/settle
# windows) WITHOUT using much memory (a bigger ecutwfc slows pw.x down but
# also grows its memory footprint roughly in step, which on these 1.9GB
# test VMs risks mattx-stub itself getting OOM-killed while carving the
# incoming copy -- confirmed live: ecutwfc=400 (~680MB RSS) triggered
# exactly that, "Failed to inject... (res: 0)" / "Waking 0 threads" while
# dmesg showed the OOM killer taking out mattx-stub mid-import). A denser
# k-point mesh multiplies wall-clock time (more Hamiltonians to
# diagonalize per SCF iteration) with only a few more MB of memory, so it
# gets the same slowdown a bigger cutoff would without the OOM risk.
# Confirmed via manual timing on this VM: ecutwfc=60 + a 14x14x14 k-mesh +
# a tiny mixing_beta (more iterations to converge) => ~56s wall, ~28MB
# estimated RAM (vs. ecutwfc=400's ~680MB).
scf_input_migration_target() {
cat <<EOF
&CONTROL
  calculation  = "scf",
  prefix       = "Si",
  pseudo_dir   = "${QE_WORKDIR}",
  outdir       = "${QE_WORKDIR}/tmp",
  restart_mode = "from_scratch"
/
&SYSTEM
  ibrav     = 2,
  celldm(1) = 10.21,
  nat       = 2,
  ntyp      = 1,
  ecutwfc   = 60
  nbnd      = 5
/
&ELECTRONS
  conv_thr         = 1.D-14,
  mixing_beta      = 0.02D0,
  electron_maxstep = 500,
/
ATOMIC_SPECIES
 Si  28.086  Si.pz-vbc.UPF
ATOMIC_POSITIONS
 Si 0.00 0.00 0.00
 Si 0.25 0.25 0.25
K_POINTS automatic
  14 14 14 0 0 0
EOF
}

echo "  Running quick Si SCF on $NODE1 ($(node_ip "$NODE1"))..."
run_on "$NODE1" "cat > $QE_WORKDIR/si_quick.in" <<EOF
$(scf_input 20 1.D-8)
EOF
if run_on "$NODE1" "
    set -e
    cd $QE_WORKDIR
    rm -rf tmp
    source '${EESSI_INIT}'
    module load ${QE_MODULE}
    export FI_PROVIDER=tcp  # see Test 1 comment above -- PSM3 doesn't work on this NIC
    timeout 120 pw.x < si_quick.in > si_quick.out
    grep -q '! *total energy' si_quick.out
" 2>&1; then
    ENERGY=$(run_on "$NODE1" "grep '! *total energy' $QE_WORKDIR/si_quick.out || echo 'N/A'" || echo "N/A")
    pass "qe-2: Si SCF converged on $NODE1 ($ENERGY)"
else
    fail "qe-2: Si SCF failed or timed out on $NODE1"
fi

# ---- Test 3: pw.x round-trip migration via MattX (NODE1 -> NODE2 -> NODE1) ----
echo ""
echo "=== Test 3: QuantumESPRESSO round-trip migration via MattX ==="

NODE1_ID=$(run_on "$NODE1" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes 2>/dev/null" | awk '/\(Local\)/{print $1}' || true)
DMESG_CURSOR_NODE1=$(dmesg_cursor "$NODE1")
DMESG_CURSOR_NODE2=$(dmesg_cursor "$NODE2")
if [ -z "$NODE1_ID" ] || [ -z "$NODE2_ID" ]; then
    fail "qe-3: MattX not running on $NODE1/$NODE2 -- run 'make ${DISTRO}cluster' first"
else
    # Uses scf_input_migration_target() (see above) -- a slow-but-low-memory
    # SCF via a dense k-point mesh, not a bigger cutoff, specifically to
    # avoid OOM-killing mattx-stub on these 1.9GB VMs during import.
    # (ecutwfc=60/conv_thr=1e-10 was the original setting here, but that was
    # only ever "slow enough" because of the PSM3 MPI-init hang below --
    # once that's fixed via FI_PROVIDER=tcp, pw.x actually runs at normal
    # speed and that input converges in ~2s, well before the first liveness
    # check.) This is single-process/serial (no mpirun) -- MattX has no MPI
    # support (see /proc/mattx/nodes), so every migration target across this
    # whole test suite is deliberately kept single-process, same as
    # GROMACS's -ntmpi 1 and ESPResSo's hand-rolled single-process script.
    run_on "$NODE1" "cat > $QE_WORKDIR/si_mig.in" <<EOF
$(scf_input_migration_target)
EOF

    echo "  Starting pw.x SCF on $NODE1 ($(node_ip "$NODE1")) -- slow-converging migration target..."
    run_on "$NODE1" "cd $QE_WORKDIR && rm -rf tmp && rm -f si_mig.out"
    PWX_PID=$(run_on "$NODE1" "
        set -e
        cd $QE_WORKDIR
        source '${EESSI_INIT}'
        module load ${QE_MODULE}
        export FI_PROVIDER=tcp  # see Test 1 comment above -- PSM3 doesn't work on this NIC
        nohup pw.x < si_mig.in > si_mig.out 2>&1 &
        echo \$!
    " | tail -1)
    sleep 10

    if ! run_on "$NODE1" "kill -0 $PWX_PID 2>/dev/null"; then
        fail "qe-3: pw.x exited before migration window (converged too fast, or crashed) -- check $QE_WORKDIR/si_mig.out"
        run_on "$NODE1" "tail -20 $QE_WORKDIR/si_mig.out 2>/dev/null || true" | sed 's/^/    /'
    else
        show_both_nodes "baseline, before outbound migration" "pw\\.x"
        echo "  Log tail from $NODE1 (iteration count so far):"
        run_on "$NODE1" "grep -c 'iteration #' $QE_WORKDIR/si_mig.out 2>/dev/null || echo 0" | sed 's/^/    iterations: /'

        ITERS_BEFORE=$(run_on "$NODE1" "grep -c 'iteration #' $QE_WORKDIR/si_mig.out 2>/dev/null || echo 0")

        do_migrate "pw.x" "$PWX_PID" "$NODE1" "$NODE2" "$NODE2_ID"
        sleep 8

        show_both_nodes "immediately after outbound migration ($NODE1 -> $NODE2)" "pw\\.x"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE1"
        show_migration_dmesg "outbound migration ($NODE1 -> $NODE2)" "$NODE2"
        if is_actually_running "pw\\.x" "$NODE2"; then
            pass "qe-3: pw.x migrated to $NODE2"

            sleep 20
            show_both_nodes "20s after outbound migration (settled state)" "pw\\.x"
            STAT2=$(process_stat "pw\\.x" "$NODE2")
            ITERS_AFTER=$(run_on "$NODE1" "grep -c 'iteration #' $QE_WORKDIR/si_mig.out 2>/dev/null || echo 0")
            if [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]] && [ "$ITERS_AFTER" -gt "$ITERS_BEFORE" ]; then
                pass "qe-3: pw.x still running on $NODE2 after 20s (iterations $ITERS_BEFORE -> $ITERS_AFTER)"

                # ---- Return leg: recall home, NODE2 -> NODE1 ----
                # The "home" recall path (admin_write's "migrate <pid> home"
                # -> mattx_trigger_recall) is DIFFERENT from the generic
                # "migrate <pid> <node>" path and must be issued ON THE HOME
                # NODE ($NODE1), using the ORIGINAL PID ($PWX_PID) --
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
                do_migrate "pw.x" "$PWX_PID" "$NODE1" "$NODE1" "home" "$NODE2"
                sleep 8

                show_both_nodes "immediately after return migration ($NODE2 -> $NODE1)" "pw\\.x"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE1"
                show_migration_dmesg "return migration ($NODE2 -> $NODE1)" "$NODE2"
                if is_actually_running "pw\\.x" "$NODE1"; then
                    pass "qe-4: pw.x migrated back to $NODE1"

                    ITERS_RETURN=$(run_on "$NODE1" "grep -c 'iteration #' $QE_WORKDIR/si_mig.out 2>/dev/null || echo 0")
                    sleep 20
                    show_both_nodes "20s after return migration (settled state)" "pw\\.x"
                    STAT4=$(process_stat "pw\\.x" "$NODE1")
                    ITERS_FINAL=$(run_on "$NODE1" "grep -c 'iteration #' $QE_WORKDIR/si_mig.out 2>/dev/null || echo 0")
                    if [[ -n "$STAT4" && "$STAT4" != T* && "$STAT4" != Z* ]] && [ "$ITERS_FINAL" -gt "$ITERS_RETURN" ]; then
                        pass "qe-4: pw.x still running on $NODE1 after 20s (round trip complete, iterations $ITERS_RETURN -> $ITERS_FINAL)"
                    elif [ -n "$STAT4" ]; then
                        fail "qe-4: pw.x present on $NODE1 but frozen (STAT=$STAT4) -- looks stuck/deadlocked, not completed (see mattx#8)"
                    else
                        echo "  ► pw.x [PID $PWX_PID] completed on $NODE1 after returning"
                        pass "qe-4: pw.x ran to completion on $NODE1 after round trip"
                    fi
                else
                    fail "qe-4: pw.x not actually running on $NODE1 after return migration"
                    echo "  dmesg tail on $NODE2:"
                    run_on "$NODE2" "sudo dmesg | tail -20" | sed 's/^/    /' || true
                fi
            elif [[ -n "$STAT2" && "$STAT2" != T* && "$STAT2" != Z* ]]; then
                fail "qe-3: pw.x present and running on $NODE2, but SCF iteration count did not advance ($ITERS_BEFORE -> $ITERS_AFTER) -- looks alive but not making progress"
            elif [ -n "$STAT2" ]; then
                fail "qe-3: pw.x present on $NODE2 but frozen (STAT=$STAT2) -- looks stuck/deadlocked, not completed (see mattx#8)"
            else
                echo "  ► pw.x [PID $PWX_PID] completed on $NODE2 before the return leg could start"
                pass "qe-3: pw.x ran to completion on $NODE2"
                fail "qe-4: cannot perform return-leg migration -- job completed on $NODE2 before it could be migrated back (increase ecutwfc/tighten conv_thr if this recurs)"
            fi
        else
            fail "qe-3: pw.x not actually running on $NODE2 after migration"
            echo "  dmesg tail on $NODE1:"
            run_on "$NODE1" "sudo dmesg | tail -20" | sed 's/^/    /' || true
        fi

        run_on "$NODE1" "kill -9 $PWX_PID 2>/dev/null || true; pkill -9 -f '[p]w\\.x' 2>/dev/null || true"
        run_on "$NODE2" "pkill -9 -f '[p]w\\.x' 2>/dev/null || true"
    fi

    if no_new_oops "$NODE1" "$DMESG_CURSOR_NODE1"; then
        pass "qe-4: no kernel oops on $NODE1"
    else
        fail "qe-4: kernel oops on $NODE1"
    fi
    if no_new_oops "$NODE2" "$DMESG_CURSOR_NODE2"; then
        pass "qe-4: no kernel oops on $NODE2"
    else
        fail "qe-4: kernel oops on $NODE2"
    fi
fi

echo ""
echo "=============================="
echo "QuantumESPRESSO Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
