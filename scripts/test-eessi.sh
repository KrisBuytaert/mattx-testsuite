#!/bin/bash
# test-eessi.sh <alma|deb|ubu>
# Run the full EESSI test suite: every workload test in scripts/test-eessi-*.sh
# except test-eessi-gromacs-chain.sh, which needs the separate 3-node cluster
# (see `make almacluster3`) rather than the normal 2-node one this target uses.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

auto_report_wrap "eessi-full" "$@"

init_cluster "$DISTRO"

TOTAL_PASS=0; TOTAL_FAIL=0
ANY_SUITE_FAILED=0

# name:script pairs, in run order.
SUITES="
ESPResSo:$SCRIPT_DIR/test-eessi-espresso.sh
GROMACS:$SCRIPT_DIR/test-eessi-gromacs.sh
QuantumESPRESSO:$SCRIPT_DIR/test-eessi-quantumespresso.sh
OpenFOAM:$SCRIPT_DIR/test-eessi-openfoam.sh
PyTorch:$SCRIPT_DIR/test-eessi-pytorch.sh
TensorFlow:$SCRIPT_DIR/test-eessi-tensorflow.sh
Bioconductor:$SCRIPT_DIR/test-eessi-bioconductor.sh
Nextflow:$SCRIPT_DIR/test-eessi-nextflow.sh
"

RESULT_LINES=""

run_suite() {
    local name="$1" script="$2"
    echo ""
    echo "######################################"
    echo "# $name"
    echo "######################################"
    local out rc=0
    out=$("$script" "$DISTRO" 2>&1) || rc=$?
    echo "$out"
    local p f
    p=$(echo "$out" | grep -c '^\[PASS\]' || true)
    f=$(echo "$out" | grep -c '^\[FAIL\]' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    # A suite that exits nonzero counts as a failure even if it crashed
    # before printing any [FAIL] line of its own (e.g. a download or
    # preflight check failing before the test body ever runs) -- otherwise
    # the aggregate summary can read "0 failed" for a suite that never
    # actually ran.
    if [ "$rc" -ne 0 ]; then
        ANY_SUITE_FAILED=1
        RESULT_LINES="${RESULT_LINES}  ${name}: FAIL (exit ${rc})\n"
    else
        RESULT_LINES="${RESULT_LINES}  ${name}: PASS\n"
    fi
}

# Read into an array first rather than `while read <<< "$SUITES"` -- inside
# the loop body, run_suite() invokes suite scripts that make many `ssh`
# calls via run_on(), and ssh (with no -n, needed elsewhere for uploading
# heredoc payloads via run_on) forwards/drains local stdin to the remote
# command. With a here-string loop, that stdin IS the remaining unread
# lines of $SUITES -- the first ssh call anywhere in the first suite
# silently consumes the rest of the list, so every suite after it just
# never runs (confirmed: this ate every suite after ESPResSo on a real
# run). Populating the array up front means the for-loop body's stdin is
# whatever the script itself was invoked with, not tied to $SUITES at all.
mapfile -t SUITE_LINES <<< "$SUITES"
for line in "${SUITE_LINES[@]}"; do
    IFS=: read -r name script <<< "$line"
    [ -n "$name" ] || continue
    run_suite "$name" "$script"
done

echo ""
echo "############################################"
echo "# EESSI Test Suite Summary"
echo "############################################"
printf '%b' "$RESULT_LINES"
echo ""
echo "  Total: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "############################################"

[ "$ANY_SUITE_FAILED" -eq 0 ] && [ "$TOTAL_FAIL" -eq 0 ]
