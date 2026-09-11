#!/bin/bash
# Ad-hoc stress driver: runs test-eessi-gromacs-alma N times back-to-back to
# build real pass/fail statistics for BUG-008 (intermittent multi-thread
# migration race). Each run already saves its own official, timestamped
# report via auto_report_wrap in this same reports/ directory; this script
# just orchestrates the repeats and writes a summary tally.
#
# STATUS: individual rounds failing is the expected signal this script
# exists to measure (BUG-008 is intermittent, not a hard failure) -- it is
# not itself evidence of a new regression. See CHANGELOG.md.
set -uo pipefail
cd "$(dirname "$0")/.."
N1=192.168.100.11
N2=192.168.100.12
KEY=keys/mattx_test
ROUNDS="${1:-5}"
SUMMARY="reports/adhoc-gromacs-stress-$(date +%Y%m%d-%H%M%S).log"

echo "Stress-testing test-eessi-gromacs-alma for $ROUNDS rounds" | tee "$SUMMARY"
PASS=0
FAIL=0
for i in $(seq 1 "$ROUNDS"); do
    echo "" | tee -a "$SUMMARY"
    echo "=== ROUND $i/$ROUNDS ($(date +%T)) ===" | tee -a "$SUMMARY"
    ssh -i "$KEY" "mattx@$N1" "sudo pkill -9 -f '[g]mx mdrun' 2>/dev/null; true" >/dev/null
    ssh -i "$KEY" "mattx@$N2" "sudo pkill -9 -f '[g]mx mdrun' 2>/dev/null; true" >/dev/null
    sleep 1
    OUT=$(make test-eessi-gromacs-alma 2>&1)
    RC=$?
    REPORT=$(echo "$OUT" | grep "^Full report:" | awk '{print $NF}')
    RESULT=$(echo "$OUT" | grep "^GROMACS Results:")
    echo "  report: $REPORT" | tee -a "$SUMMARY"
    echo "  $RESULT" | tee -a "$SUMMARY"
    if [ "$RC" -eq 0 ]; then
        echo "  ROUND $i: PASS" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    else
        FAIL_LINE=$(echo "$OUT" | grep "^\[FAIL\]" | head -1)
        echo "  ROUND $i: FAIL ($FAIL_LINE)" | tee -a "$SUMMARY"
        FAIL=$((FAIL+1))
    fi
done

echo "" | tee -a "$SUMMARY"
echo "=============================================" | tee -a "$SUMMARY"
echo "FINAL TALLY: $PASS passed, $FAIL failed, out of $ROUNDS rounds" | tee -a "$SUMMARY"
echo "=============================================" | tee -a "$SUMMARY"
