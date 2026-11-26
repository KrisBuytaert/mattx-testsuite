#!/bin/bash
# test-preadspeed.sh <alma|deb|ubu|fed>
# Bulk pread64() of an inherited file by a migrated process (mattx#74: colibri "hangs" after a migration).
# The Surrogate's pread64() went through the legacy path: fd sabotaged, SIGSTOP, work item, one RPC of at most
# 4096 bytes per call -- about 38 KB/s, so a process that preads a multi-GB model file looks hung (state T) for days.
# A small python3 process opens a file made on node1, is migrated to node2 and preads all of it in 64 KB blocks;
# the data must be intact (sha256) and the rate must be at least PREADSPEED_MIN_MBPS (default 2 MB/s; the legacy
# path gives 0.04, the proxy path with 64 KB READ chunks about 10).
# Tunables: PREADSPEED_MB (default 32), PREADSPEED_MIN_MBPS, PREADSPEED_WAIT (seconds to wait for the result, 150).
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

MB="${PREADSPEED_MB:-32}"
MIN_MBPS="${PREADSPEED_MIN_MBPS:-2}"
WAIT="${PREADSPEED_WAIT:-150}"

auto_report_wrap "test-preadspeed" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

cleanup() {
    for n in "$NODE1" "$NODE2"; do run_on "$n" "sudo pkill -9 -f '[p]readspeed-prog.p[y]' 2>/dev/null || true" 2>/dev/null || true; done
    run_on "$NODE1" "rm -f /tmp/preadspeed.bin" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== bulk pread64 of an inherited file after a migration (mattx#74) on ${DISTRO} cluster ==="
NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "preadspeed: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "PreadSpeed Results: $PASS passed, $FAIL failed"; exit 1
fi
run_on "$NODE1" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
DMESG_CURSOR_1=$(dmesg_cursor "$NODE1"); DMESG_CURSOR_2=$(dmesg_cursor "$NODE2")
cleanup
SKIP=0
command -v python3 >/dev/null || SKIP=1
if [ "$SKIP" = 1 ]; then echo "[SKIP] python3 not available"; exit 0; fi

run_on "$NODE1" "cat > /tmp/preadspeed-prog.py" <<'PY'
import os, sys, time, hashlib
fd = os.open("/tmp/preadspeed.bin", os.O_RDONLY)
size = os.fstat(fd).st_size
t0 = time.time()
while time.time() - t0 < 15:          # time to be migrated; the file is only touched afterwards
    time.sleep(0.5)
t = time.time(); h = hashlib.sha256(); off = 0; nxt = 1 << 20
while off < size:
    b = os.pread(fd, 65536, off)
    if not b:
        break
    h.update(b); off += len(b)
    if off >= nxt:
        dt = time.time() - t
        sys.stdout.write("PROG %d %.2f\n" % (off, dt)); sys.stdout.flush(); nxt += 1 << 20
dt = time.time() - t
sys.stdout.write("PREAD bytes=%d sec=%.2f MBps=%.3f sha=%s\n" % (off, dt, off / dt / 1e6, h.hexdigest())); sys.stdout.flush()
PY
SHA=$(run_on "$NODE1" "head -c ${MB}M /dev/urandom > /tmp/preadspeed.bin; sha256sum /tmp/preadspeed.bin | cut -d' ' -f1; rm -f /tmp/preadspeed.out; nohup python3 -u /tmp/preadspeed-prog.py > /tmp/preadspeed.out 2>&1 < /dev/null &" | tail -1)
sleep 2
PID=$(run_on "$NODE1" "pgrep -f '^python3 -u /tmp/preadspeed-prog.py' | head -1" 2>/dev/null || true)
if [ -z "$PID" ]; then fail "preadspeed: test program did not start"; exit 1; fi
do_migrate "preadspeed-prog.py" "$PID" "$NODE1" "$NODE2" "$NODE2_ID" || true
HOSTED=0
for _ in $(seq 1 10); do
    sleep 1
    HOSTED=$(run_on "$NODE2" "pgrep -fc 'preadspeed-prog[.]py' || true" 2>/dev/null | tail -1)
    [ "${HOSTED:-0}" -gt 0 ] && break
done
[ "${HOSTED:-0}" -gt 0 ] && pass "preadspeed: process hosted on $NODE2" || fail "preadspeed: migration did not happen"

for _ in $(seq 1 "$WAIT"); do
    sleep 1
    run_on "$NODE1" "grep -q '^PREAD' /tmp/preadspeed.out" 2>/dev/null && break
done

LINE=$(run_on "$NODE1" "grep '^PREAD' /tmp/preadspeed.out || true" 2>/dev/null | tail -1)
if [ -z "$LINE" ]; then
    LAST=$(run_on "$NODE1" "grep '^PROG' /tmp/preadspeed.out | tail -1" 2>/dev/null | tail -1)
    fail "preadspeed: no result after ${WAIT}s (last progress: ${LAST:-none}) -- bulk pread64 of the migrated process is far too slow (mattx#74)"
else
    GOT_SHA=$(sed -n 's/.*sha=\([0-9a-f]*\).*/\1/p' <<<"$LINE")
    MBPS=$(sed -n 's/.*MBps=\([0-9.]*\).*/\1/p' <<<"$LINE")
    [ "$GOT_SHA" = "$SHA" ] && pass "preadspeed: ${MB} MB read back intact after the migration" || fail "preadspeed: data differs after the migration ($GOT_SHA vs $SHA)"
    if awk -v r="$MBPS" -v m="$MIN_MBPS" 'BEGIN{exit !(r+0 >= m+0)}'; then
        pass "preadspeed: bulk pread64 of the migrated process runs at ${MBPS} MB/s (>= ${MIN_MBPS})"
    else
        fail "preadspeed: bulk pread64 of the migrated process runs at ${MBPS} MB/s, expected >= ${MIN_MBPS} (mattx#74)"
    fi
fi

cleanup
check_no_oops "$NODE1" "$DMESG_CURSOR_1" && pass "preadspeed: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_2" && pass "preadspeed: no oops on $NODE2"

echo ""
echo "=============================="
echo "PreadSpeed Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
