#!/bin/bash
# fetch-crash-dump.sh <alma|deb|ubu> <1|2|3>
# Lists and fetches any kdump-captured crash dumps from a node's /var/crash
# into test/crash-dumps/<node>-<timestamp>/. Requires kdump to have been
# set up on that node by setup-node.sh (alma only, as of this writing --
# see CHANGELOG.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DISTRO="${1:?Usage: $0 <alma|deb|ubu> <1|2|3>}"
NODE_NUM="${2:?Usage: $0 <alma|deb|ubu> <1|2|3>}"

case "$DISTRO-$NODE_NUM" in
    alma-1) NODE="almanode1" ;;
    alma-2) NODE="almanode2" ;;
    alma-3) NODE="almanode3" ;;
    deb-1)  NODE="debnode1"  ;;
    deb-2)  NODE="debnode2"  ;;
    ubu-1)  NODE="ubunode1"  ;;
    ubu-2)  NODE="ubunode2"  ;;
    *) echo "Usage: $0 <alma|deb|ubu> <1|2|3 (alma only)>" >&2; exit 1 ;;
esac

init_cluster "$DISTRO"

echo "=== Crash dumps on $NODE (/var/crash) ==="
DUMPS="$(run_on "$NODE" "sudo find /var/crash -mindepth 1 -maxdepth 1 -type d 2>/dev/null" || true)"
if [ -z "$DUMPS" ]; then
    echo "(none found -- either nothing has crashed since kdump was enabled, or kdump isn't active on this node; check 'sudo kdumpctl status' on $NODE)"
    exit 0
fi
echo "$DUMPS"

OUT_DIR="$SCRIPT_DIR/../crash-dumps/${NODE}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
echo ""
echo "Fetching into $OUT_DIR ..."
# vmcore files are root-owned, 0600 by default -- rsync runs as the
# unprivileged mattx ssh user, so open them up enough to read first.
run_on "$NODE" "sudo chmod -R a+rX /var/crash"
rsync_from "$NODE" "/var/crash/" "$OUT_DIR/"

echo ""
echo "Done. Each subdirectory has a vmcore (raw kernel memory dump) and a"
echo "vmcore-dmesg.txt (just the crash's dmesg buffer -- start there, it's"
echo "usually enough to see the actual oops/panic without needing the full"
echo "'crash' debugger + a matching debuginfo kernel)."
echo ""
echo "  cat $OUT_DIR/*/vmcore-dmesg.txt"
