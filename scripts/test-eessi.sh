#!/bin/bash
# test-eessi.sh <alma|deb>
# Run the full EESSI test suite: ESPResSo + GROMACS.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_cluster "$DISTRO"

TOTAL_PASS=0; TOTAL_FAIL=0

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
    return $rc
}

ESPRESSO_RC=0
GROMACS_RC=0

run_suite "ESPResSo" "$SCRIPT_DIR/test-eessi-espresso.sh" || ESPRESSO_RC=$?
run_suite "GROMACS"  "$SCRIPT_DIR/test-eessi-gromacs.sh"  || GROMACS_RC=$?

echo ""
echo "############################################"
echo "# EESSI Test Suite Summary"
echo "############################################"
echo "  ESPResSo: $([ "$ESPRESSO_RC" -eq 0 ] && echo PASS || echo FAIL)"
echo "  GROMACS:  $([ "$GROMACS_RC"  -eq 0 ] && echo PASS || echo FAIL)"
echo ""
echo "  Total: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "############################################"

[ "$TOTAL_FAIL" -eq 0 ]
