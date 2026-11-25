#!/bin/bash
# test-fileoffset.sh <alma|deb|ubu|fed>
# File offsets of descriptors a process inherits from its home node, across a migration (mattx#78):
#   - write(2) to an inherited "2> file" must continue at the Deputy's position. It used to restart at byte 0 of the
#     file after the migration and overwrite what was already there (ksys_write() passes a COPY of f_pos, the
#     Surrogate's proxy took every plain write for a pwrite at its own position 0).
#   - pwrite64()/pread64() on such a descriptor must work (they failed with ESPIPE: the proxy file lacked
#     FMODE_PREAD/PWRITE), must use the offset of the caller and must not move the position,
#   - preadv() of the file at an offset must read there too (the iov_iter path).
#   - pread64() of a PIPE after the migration must fail with ESPIPE, as it does natively (it group-stopped the
#     process for ever, mattx#79).
# A small python3 process writes a numbered line to stderr every second, pwrite()s a marker at offset 20 of a second
# file, pread()s its header back and preadv()s it; it is migrated to node2 and observed for ~15 s.
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

auto_report_wrap "test-fileoffset" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

cleanup() {
    for n in "$NODE1" "$NODE2"; do run_on "$n" "sudo pkill -9 -f '[f]ileoffset-(prog|pipe).py' 2>/dev/null || true" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

echo "=== file offsets across a migration (write/pwrite/pread of inherited fds, mattx#78) on ${DISTRO} cluster ==="

if ! run_on "$NODE1" "command -v python3" >/dev/null 2>&1; then
    echo "SKIP: python3 not installed on $NODE1"
    echo ""; echo "=============================="; echo "FileOffset Results: 0 passed, 0 failed (skipped)"; echo "=============================="
    exit 0
fi

NODE2_ID=$(run_on "$NODE2" "cat /proc/mattx/nodes" 2>/dev/null | awk '/\(Local\)/{print $1}' || true)
if [ -z "$NODE2_ID" ]; then
    fail "fileoffset: MattX not running on $NODE2 -- run 'make ${DISTRO}cluster' first"
    echo ""; echo "FileOffset Results: $PASS passed, $FAIL failed"; exit 1
fi
run_on "$NODE1" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
run_on "$NODE2" "echo 'balancer 0' | sudo tee /proc/mattx/admin > /dev/null"
DMESG_CURSOR_1=$(dmesg_cursor "$NODE1"); DMESG_CURSOR_2=$(dmesg_cursor "$NODE2")

run_on "$NODE1" "cat > /tmp/fileoffset-prog.py" <<'PY'
import os, sys, time, errno
fd = os.open("/tmp/fileoffset-p.out", os.O_RDWR | os.O_CREAT | os.O_TRUNC)
os.pwrite(fd, b"HEADER-0123456789\n", 0)
i = 0
while True:
    i += 1
    sys.stderr.write("line %04d\n" % i)
    try:
        os.pwrite(fd, ("p%04d" % i).encode(), 20)
        got = os.pread(fd, 6, 0)
        b = bytearray(6); os.preadv(fd, [b], 0); pv = bytes(b)
        if pv != got: raise OSError(errno.EIO, "preadv differs")
    except OSError as e:
        sys.stdout.write("%d EXC %s\n" % (i, errno.errorcode.get(e.errno, e.errno))); sys.stdout.flush(); time.sleep(1); continue
    sys.stdout.write("%d pread=%s preadv=%s\n" % (i, got.decode(), pv.decode())); sys.stdout.flush()
    time.sleep(1)
PY
run_on "$NODE1" "rm -f /tmp/fileoffset.err /tmp/fileoffset.out /tmp/fileoffset-p.out; nohup python3 -u /tmp/fileoffset-prog.py 2> /tmp/fileoffset.err > /tmp/fileoffset.out < /dev/null &" || true
sleep 6
PID=$(run_on "$NODE1" "pgrep -f '[f]ileoffset-prog.py' | head -1" 2>/dev/null || true)
if [ -z "$PID" ]; then fail "fileoffset: test program did not start"; exit 1; fi
PRE=$(run_on "$NODE1" "wc -l < /tmp/fileoffset.err" | tail -1)
do_migrate "fileoffset-prog.py" "$PID" "$NODE1" "$NODE2" "$NODE2_ID" || true
# up to 45 s for 10 more lines (the first seconds after a migration can be slow)
for _ in $(seq 1 45); do
    sleep 1
    [ "$(run_on "$NODE1" 'wc -l < /tmp/fileoffset.err' 2>/dev/null | tail -1)" -ge $((PRE + 10)) ] && break
done

HOSTED=$(run_on "$NODE2" "pgrep -fc '[f]ileoffset-prog.py' || true" 2>/dev/null | tail -1)
[ "${HOSTED:-0}" -gt 0 ] && pass "fileoffset: process hosted on $NODE2" || fail "fileoffset: migration did not happen"

# stderr: lines 1..K in order, none overwritten, and K well beyond the lines written before the migration
LOG=$(run_on "$NODE1" "cat /tmp/fileoffset.err")
K=$(echo "$LOG" | grep -c '^line ' || true)
SEQ=$(echo "$LOG" | awk '/^line /{n++; if ($2+0 != n) bad=1} END{print bad?"bad":"ok"}')
if [ "$SEQ" = ok ] && [ "$K" -ge $((PRE + 8)) ]; then
    pass "fileoffset: inherited stderr file continued at the right offset ($PRE lines before, $K in all, in order)"
else
    fail "fileoffset: stderr file overwritten or stalled after the migration ($PRE lines before the migration, $K lines in the file, order $SEQ)"
    echo "$LOG" | head -6 | sed 's/^/    /'
fi

# pwrite/pread of an inherited descriptor
OUT=$(run_on "$NODE1" "cat /tmp/fileoffset.out")
EXC=$(echo "$OUT" | grep -c ' EXC ' || true)
LASTLINE=$(echo "$OUT" | tail -1)
if [ "$EXC" -eq 0 ] && echo "$LASTLINE" | grep -q 'pread=HEADER'; then
    pass "fileoffset: pwrite64/pread64 work on the inherited fd after the migration ($LASTLINE)"
else
    fail "fileoffset: pwrite64/pread64 on the inherited fd failed ($EXC errors; last: $LASTLINE)"
    echo "$OUT" | grep ' EXC ' | head -2 | sed 's/^/    /'
fi
MARK=$(run_on "$NODE1" "dd if=/tmp/fileoffset-p.out bs=1 skip=20 count=5 2>/dev/null")
HEAD=$(run_on "$NODE1" "head -c 17 /tmp/fileoffset-p.out")
LASTN=$(echo "$LASTLINE" | awk '{print $1+0}')
if [ "$HEAD" = "HEADER-0123456789" ] && [ "${MARK#p}" -ge $((LASTN - 1)) ] 2>/dev/null; then
    pass "fileoffset: pwrite landed at the offset of the caller after the migration (header intact, marker $MARK)"
else
    fail "fileoffset: pwrite file wrong (header '$HEAD', marker '$MARK', program at line $LASTN)"
fi
if echo "$OUT" | tail -3 | grep -q 'preadv=HEADER'; then
    pass "fileoffset: preadv at an offset reads there after the migration"
else
    fail "fileoffset: preadv at an offset did not read the header after the migration"
fi

# --- pread64() of a pipe after the migration (mattx#79): must return ESPIPE, not stop the process ---
cleanup
run_on "$NODE1" "cat > /tmp/fileoffset-pipe.py" <<'PY'
import os, sys, time, errno
r, w = os.pipe()
i = 0
while True:
    i += 1
    try:
        os.pread(r, 1, 0); pe = "NOERR"
    except OSError as e:
        pe = errno.errorcode.get(e.errno, str(e.errno))
    sys.stdout.write("%d pipe-pread=%s\n" % (i, pe)); sys.stdout.flush()
    time.sleep(1)
PY
run_on "$NODE1" "rm -f /tmp/fileoffset-pipe.out; nohup python3 -u /tmp/fileoffset-pipe.py > /tmp/fileoffset-pipe.out 2>&1 < /dev/null &" || true
sleep 5
PID=$(run_on "$NODE1" "pgrep -f '[f]ileoffset-pipe.py' | head -1" 2>/dev/null || true)
do_migrate "fileoffset-pipe.py" "$PID" "$NODE1" "$NODE2" "$NODE2_ID" || true
PRE=$(run_on "$NODE1" "wc -l < /tmp/fileoffset-pipe.out" | tail -1)
sleep 12
POST=$(run_on "$NODE1" "wc -l < /tmp/fileoffset-pipe.out" | tail -1)
STOPPED=$(run_on "$NODE2" "ps -eLo stat=,args= | grep -c '^T.*[f]ileoffset-pipe.py' || true" 2>/dev/null | tail -1)
HOSTED=$(run_on "$NODE2" "ps -eLo stat=,args= | grep -c '[f]ileoffset-pipe.py' || true" 2>/dev/null | tail -1)
if [ "$POST" -ge $((PRE + 4)) ] && [ "${STOPPED:-1}" = 0 ] && [ "${HOSTED:-0}" -gt 0 ] && ! run_on "$NODE1" "grep -q NOERR /tmp/fileoffset-pipe.out"; then
    pass "fileoffset: pread64 of a pipe returns ESPIPE after the migration, process keeps running ($PRE -> $POST lines)"
else
    fail "fileoffset: pread64 of a pipe after the migration: $PRE -> $POST lines, $STOPPED thread(s) group-stopped (T) of $HOSTED on $NODE2 (mattx#79)"
fi

cleanup
check_no_oops "$NODE1" "$DMESG_CURSOR_1" && pass "fileoffset: no oops on $NODE1"
check_no_oops "$NODE2" "$DMESG_CURSOR_2" && pass "fileoffset: no oops on $NODE2"

echo ""
echo "=============================="
echo "FileOffset Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
