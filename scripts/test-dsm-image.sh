#!/bin/bash
# test-dsm-image.sh <alma|deb|ubu|fed>
# Matt's DSM image tests (bin/dsmimagetest, and the older dsmimagetest-v1): a Manager
# forks N workers that wait 10 s (the migration window), then repaint a BMP into a SysV
# shared-memory canvas chunk by chunk (atomic claim, plus "chaos" overwrites and read
# torture), and the Manager writes the canvas out as output_dsm_test.bmp.
#
# We migrate half of the workers to node2 inside that window, so chunks are painted on
# both nodes through the DSM. Verdict:
#   - output_dsm_test.bmp must be byte-identical to the input (a chunk lost, stale or torn
#     by the DSM shows up as a differing byte; the canvas starts as 0x55 filler)
#   - the Manager must finish within the timeout (hang = fail)
#   - at least one chunk must have been painted on node2 (otherwise nothing crossed nodes
#     and the comparison proves nothing: fail, not pass)
#   - no kernel oops on either node
# The input is generated here (deterministic, no 0x55 runs), ~230 kB = 57 chunks.
# Tunables: DSMIMG_WORKERS (default 4), DSMIMG_OPS (5), DSMIMG_DELAY (0.02),
# DSMIMG_TOOLS ("dsmimagetest dsmimagetest-v1").
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1"; NODE2="almanode2" ;;
    deb)  NODE1="debnode1";  NODE2="debnode2"  ;;
    ubu)  NODE1="ubunode1";  NODE2="ubunode2"  ;;
    fed)  NODE1="fednode1";  NODE2="fednode2"  ;;
esac

auto_report_wrap "test-dsm-image" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORKERS="${DSMIMG_WORKERS:-4}"; OPS="${DSMIMG_OPS:-5}"; DELAY="${DSMIMG_DELAY:-0.02}"
TOOLS="${DSMIMG_TOOLS:-dsmimagetest dsmimagetest-v1}"
WORK='$HOME/dsmimg'
KEY_HEX=0x4d415456

cleanup() {
    for n in "$NODE1" "$NODE2"; do
        run_on "$n" "pkill -9 -f '[d]smimagetest' 2>/dev/null || true" 2>/dev/null || true
    done
    run_on "$NODE1" "ipcrm -M $KEY_HEX 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== DSM image tests ($TOOLS) on ${DISTRO} cluster ==="

if ! run_on "$NODE1" "command -v dsmimagetest" >/dev/null 2>&1; then
    echo "SKIP: dsmimagetest not installed on $NODE1 (MattX commit predates it)"
    echo ""; echo "=============================="
    echo "DSM-Image Results: 0 passed, 0 failed (skipped)"
    echo "=============================="
    exit 0
fi

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "dsm-image: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "DSM-Image Results: $PASS passed, $FAIL failed"; exit 1
fi
run_on "$NODE1" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"

# deterministic 320x240 24-bit BMP; byte values never form 0x55 runs
python3 -I - <<'PY' | run_on "$NODE1" "mkdir -p $WORK && cat > $WORK/in.bmp"
import struct, sys
w, h = 320, 240
row = w * 3
hdr = b"BM" + struct.pack("<IHHI", 54 + row * h, 0, 0, 54) + struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, row * h, 2835, 2835, 0, 0)
body = bytearray()
for y in range(h):
    for x in range(w):
        for c in range(3):
            v = (x * 7 + y * 13 + c * 31 + (x * y) % 251) & 0xFF
            body.append(v if v != 0x55 else 0x56)
sys.stdout.buffer.write(hdr + bytes(body))
PY
IN_SUM=$(run_on "$NODE1" "sha256sum $WORK/in.bmp | cut -c1-16")
echo "  input: $(run_on "$NODE1" "stat -c %s $WORK/in.bmp") bytes, sha256 $IN_SUM..., workers=$WORKERS ops=$OPS delay=$DELAY"

idx=0
for TOOL in $TOOLS; do
    idx=$((idx+1))
    if ! run_on "$NODE1" "command -v $TOOL" >/dev/null 2>&1; then
        echo "  $TOOL not installed on $NODE1, skipping"; continue
    fi
    echo ""
    echo "=== $TOOL: migrate half of the workers to $NODE2, compare the output ==="
    C1=$(dmesg_cursor "$NODE1"); C2=$(dmesg_cursor "$NODE2")
    run_on "$NODE1" "ipcrm -M $KEY_HEX 2>/dev/null || true; rm -f $WORK/output_dsm_test.bmp $WORK/$TOOL.log"
    MGR=$(run_on "$NODE1" "cd $WORK && ($TOOL $WORKERS $OPS $DELAY in.bmp &>$TOOL.log & echo \$!)")
    # the workers are forked 0.5 s apart and sleep 10 s: be done migrating well inside that
    for _ in $(seq 1 20); do
        N=$(run_on "$NODE1" "pgrep -P $MGR | wc -l" 2>/dev/null || echo 0)
        [ "$N" -ge "$WORKERS" ] && break; sleep 0.3
    done
    PIDS=$(run_on "$NODE1" "pgrep -P $MGR" || true)
    MOVED=0; i=0
    for P in $PIDS; do
        i=$((i+1)); [ $((i % 2)) -eq 0 ] || continue
        do_migrate "$TOOL worker" "$P" "$NODE1" "$NODE2" "$NODE2_ID" && MOVED=$((MOVED+1)) || true
    done
    echo "  migrated $MOVED of $WORKERS workers"

    DONE=0
    for _ in $(seq 1 60); do
        run_on "$NODE1" "grep -q 'Clean exit' $WORK/$TOOL.log 2>/dev/null" && { DONE=1; break; }
        sleep 2
    done
    if [ "$DONE" -ne 1 ]; then
        fail "dsm-image/$TOOL: Manager did not finish within ~120 s (hang)"
        run_on "$NODE1" "tail -8 $WORK/$TOOL.log 2>/dev/null; ps -eo pid,stat,cmd | grep -i '[d]smimagetest'" | sed 's/^/    /' || true
    else
        if run_on "$NODE1" "cmp -s $WORK/in.bmp $WORK/output_dsm_test.bmp"; then
            pass "dsm-image/$TOOL: output is byte-identical to the input"
        else
            DIFF=$(run_on "$NODE1" "cmp -l $WORK/in.bmp $WORK/output_dsm_test.bmp 2>&1 | wc -l" || echo "?")
            FIRST=$(run_on "$NODE1" "cmp $WORK/in.bmp $WORK/output_dsm_test.bmp 2>&1 | head -1" || true)
            fail "dsm-image/$TOOL: output differs from the input ($DIFF bytes differ; $FIRST; chunk = byte/4096)"
        fi
        N2PAINT=$(run_on "$NODE1" "grep -c \"Node $NODE2_ID\\] Painted\" $WORK/$TOOL.log" || echo 0)
        N1PAINT=$(run_on "$NODE1" "grep -c 'Painted chunk' $WORK/$TOOL.log" || echo 0)
        if [ "${N2PAINT:-0}" -gt 0 ]; then
            pass "dsm-image/$TOOL: $N2PAINT of $N1PAINT chunks were painted on $NODE2 (node $NODE2_ID)"
        else
            fail "dsm-image/$TOOL: no chunk was painted on node $NODE2_ID -- nothing crossed nodes, the comparison proves nothing"
        fi
    fi
    run_on "$NODE1" "pkill -9 -f '[d]smimagetest' 2>/dev/null; ipcrm -M $KEY_HEX 2>/dev/null || true"
    run_on "$NODE2" "pkill -9 -f '[d]smimagetest' 2>/dev/null || true"
    check_no_oops "$NODE1" "$C1" && pass "dsm-image/$TOOL: no oops on $NODE1"
    check_no_oops "$NODE2" "$C2" && pass "dsm-image/$TOOL: no oops on $NODE2"
done

echo ""
echo "=============================="
echo "DSM-Image Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
