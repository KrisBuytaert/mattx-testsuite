#!/bin/bash
# test-mattxfs-umount.sh <alma|deb|ubu|fed>
# Regression test for mattx#31: after anything below /mattxfs/<node>/ has been looked up,
# `umount /mattxfs` used to crash the node ("VFS: Busy inodes after unmount of mattxfs" +
# kernel BUG at fs/super.c:650) or spin forever in shrink_dcache_parent()/d_walk() with
# s_umount held (blocking every sync() on the node). Cause: the legacy mount path used
# kill_sb = kill_litter_super, which drops a reference from every dentry although mattxfs
# never pinned them.
#
# Per cycle on node1: look up remote directories through /mattxfs, umount it, check the
# node did not reboot / hang / log an oops, then mount it again. Only the umount is
# exercised -- not `rmmod mattx` (mattx#36) -- so this test is independent of that bug.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO" in
    alma) NODE1="almanode1" ;;
    deb)  NODE1="debnode1"  ;;
    ubu)  NODE1="ubunode1"  ;;
    fed)  NODE1="fednode1"  ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed>" >&2; exit 1 ;;
esac

auto_report_wrap "test-mattxfs-umount" "$@"

init_cluster "$DISTRO"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# bounded ssh: a wedged or crashed node must fail the test, not hang it
rto() { timeout 120 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$NODE1")" "$@"; }

CYCLES="${CYCLES:-3}"
echo "=== MattXFS umount after lookups (mattx#31): $CYCLES cycles on $NODE1 ==="

BOOT_ID="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
if [ -z "$BOOT_ID" ]; then
    fail "umount-0: $NODE1 not reachable, cannot run"
else
    rto "sudo systemctl start mattx; mountpoint -q /mattxfs || sudo mount -t mattxfs none /mattxfs; sudo dmesg -C" >/dev/null 2>&1 || true
    for i in $(seq 1 "$CYCLES"); do
        echo ""
        echo "--- cycle $i ---"
        n="$(rto 'n=0; for P in $(ls /mattxfs 2>/dev/null); do n=$((n + $(ls -la /mattxfs/$P/etc 2>/dev/null | wc -l))); done; echo $n' 2>/dev/null || echo 0)"
        if [ "${n:-0}" -gt 0 ]; then
            pass "umount-$i: looked up $n directory entries below /mattxfs"
        else
            fail "umount-$i: nothing could be looked up below /mattxfs on $NODE1 (not mounted or no peers?)"
        fi
        rc=0
        rto "sudo timeout 60 umount /mattxfs" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 255 ]; then
            fail "umount-$i: connection to $NODE1 lost during umount -- the node crashed (mattx#31)"
            echo "  (waiting for $NODE1 to come back before stopping the test)"
            for _ in $(seq 1 60); do rto true >/dev/null 2>&1 && break; sleep 3; done
            break
        elif [ "$rc" -eq 124 ]; then
            fail "umount-$i: umount did not return within 60s on $NODE1 (spinning in the dcache walk, mattx#31)"
            break
        elif [ "$rc" -ne 0 ]; then
            fail "umount-$i: umount failed on $NODE1 (rc=$rc)"
        else
            pass "umount-$i: umount /mattxfs returned"
        fi
        now="$(rto "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
        [ "$now" = "$BOOT_ID" ] && pass "umount-$i: $NODE1 did not reboot" || fail "umount-$i: $NODE1 rebooted (boot_id changed)"
        bad="$(rto "sudo dmesg | grep -cE 'Busy inodes|Oops|BUG:' || true" 2>/dev/null)"
        [ "${bad:-1}" = 0 ] && pass "umount-$i: no 'Busy inodes'/oops/BUG in dmesg on $NODE1" || fail "umount-$i: 'Busy inodes'/oops/BUG in dmesg on $NODE1 (${bad:-?} lines)"
        rto "sudo mount -t mattxfs none /mattxfs" >/dev/null 2>&1 || true
        rto "mountpoint -q /mattxfs" >/dev/null 2>&1 && pass "umount-$i: /mattxfs mounted again" || fail "umount-$i: could not mount /mattxfs again on $NODE1"
    done
fi

echo ""
echo "MattXFS-Umount Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
