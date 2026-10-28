#!/bin/bash
# node-health.sh <alma|deb|ubu|fed> [nodes...] -- run before a deploy: reboot a node whose kernel has loaded
# mattx.ko too often since boot. Every insmod/rmmod cycle leaks a little module memory (execmem); after a
# few dozen the next insmod fails with "Cannot allocate memory" and the whole CI run dies in `make upgrade-*`
# (run 120). A reboot is the only cure. Env: MAX_LOADS (default 25), DRY_RUN=1 (report only).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
DISTRO="${1:?Usage: $0 <alma|deb|ubu|fed> [nodes...]}"; shift
case "$DISTRO" in
    alma) DEFAULT="almanode1 almanode2 almanode3" ;; deb) DEFAULT="debnode1 debnode2" ;;
    ubu)  DEFAULT="ubunode1 ubunode2" ;;             fed) DEFAULT="fednode1 fednode2" ;;
    *) echo "Usage: $0 <alma|deb|ubu|fed> [nodes...]" >&2; exit 1 ;;
esac
NODES="${*:-$DEFAULT}"; MAX="${MAX_LOADS:-25}"
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
        sshn "$n" true >/dev/null 2>&1 && echo "[health] $n: back up" || echo "[health] $n: did not come back within 5 min" >&2
    fi
done
exit 0
