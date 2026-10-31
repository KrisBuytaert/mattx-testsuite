#!/bin/bash
# node-health.sh <alma|deb|ubu|fed> [nodes...] -- run before a deploy: reboot a node whose kernel has loaded
# mattx.ko too often since boot. Every insmod/rmmod cycle leaks a little module memory (execmem); after a
# few dozen the next insmod fails with "Cannot allocate memory" and the whole CI run dies in `make upgrade-*`
# (run 120). A reboot is the only cure. Env: MAX_LOADS (default 1 = reboot every node that already loaded the module this boot; runs 144 and 882 failed at 23 and 4 loads), DRY_RUN=1 (report only). A node that does not return within 5 min is hard-reset with virsh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed> [nodes...]}"; shift
case "$DISTRO" in
    alma) DEFAULT="almanode1 almanode2 almanode3" ;; deb) DEFAULT="debnode1 debnode2" ;;
    ubu)  DEFAULT="ubunode1 ubunode2" ;;             fed) DEFAULT="fednode1 fednode2" ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed> [nodes...]" >&2; exit 1 ;;
esac
NODES="${*:-$DEFAULT}"; MAX="${MAX_LOADS:-1}"
sshn() { local n="$1"; shift; timeout 60 ssh $SSH_OPTS -o ConnectTimeout=10 "$SSH_USER@$(node_ip "$n")" "$@"; }

for n in $NODES; do
    loads=$(sshn "$n" 'sudo journalctl -b -u mattx --no-pager 2>/dev/null | grep -c "Loading kernel module"; true' 2>/dev/null | head -1)
    exm=$(sshn "$n" 'sudo journalctl -b -k --no-pager 2>/dev/null | grep -c "execmem: unable"; true' 2>/dev/null | head -1)
    if [ -z "$loads" ]; then echo "[health] $n: unreachable (left alone)"; continue; fi
    echo "[health] $n: $loads module loads this boot, $exm execmem errors"
    if [ "$loads" -ge "$MAX" ] || [ "${exm:-0}" -gt 0 ]; then
        [ "${DRY_RUN:-0}" = 1 ] && { echo "[health] $n: would reboot"; continue; }
        echo "[health] $n: rebooting to give the module memory back"
        sshn "$n" 'sudo systemctl reboot' >/dev/null 2>&1 || true
        sleep 20
        for _ in $(seq 1 60); do sshn "$n" true >/dev/null 2>&1 && break; sleep 5; done
        if sshn "$n" true >/dev/null 2>&1; then echo "[health] $n: back up"; continue; fi
        # a shutdown can hang on a mattx receiver kthread stuck in handle_mm_fault (run 965): the guest keeps
        # answering ping with sshd gone. Hard-reset the libvirt domain (same name as the node) and wait again.
        echo "[health] $n: did not come back within 5 min, hard-resetting the VM" >&2
        LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}" virsh reset "$n" >/dev/null 2>&1 || echo "[health] $n: virsh reset failed" >&2
        sleep 20
        for _ in $(seq 1 60); do sshn "$n" true >/dev/null 2>&1 && break; sleep 5; done
        sshn "$n" true >/dev/null 2>&1 && echo "[health] $n: back up after reset" || echo "[health] $n: still down after reset" >&2
    fi
done
exit 0
