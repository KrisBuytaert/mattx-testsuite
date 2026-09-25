#!/bin/bash
# ensure-libvirt-network.sh <name> <host-ip> <bridge> [mac=ip ...]
# Creates and starts a NAT libvirt network with DHCP + optional MAC reservations.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

NAME="$1"
HOST_IP="$2"
BRIDGE="$3"
NETMASK="255.255.255.0"
shift 3

if virsh net-info "$NAME" 2>/dev/null | grep -q "Active:.*yes"; then
    echo "[network] $NAME already active"
    exit 0
fi

# Network is defined but not active (e.g. after a host reboot) — just start it.
# Destroying and recreating the bridge would disconnect already-running VMs,
# so this must not be the first response to a start failure: `virsh net-start`
# on a freshly-(re)defined network has been observed to fail intermittently
# with a transient libvirtd RPC error ("End of file while reading data:
# Input/output error", not a real bridge config mismatch) on the very first
# attempt, succeeding a moment later with no changes at all. Retry a few
# times before assuming the definition itself is bad.
if virsh net-info "$NAME" 2>/dev/null; then
    echo "[network] $NAME defined but inactive — starting"
    STARTED=0
    for attempt in 1 2 3 4 5; do
        if virsh net-start "$NAME" 2>/dev/null; then
            STARTED=1
            break
        fi
        echo "[network] net-start attempt $attempt failed (likely transient) — retrying in 2s"
        sleep 2
    done
    virsh net-autostart "$NAME" 2>/dev/null || true
    if [ "$STARTED" -eq 1 ] && virsh net-info "$NAME" 2>/dev/null | grep -q "Active:.*yes"; then
        echo "[network] $NAME started"
        exit 0
    fi
    # All retries exhausted — tear down and recreate as a last resort. This
    # WILL orphan any VM already attached to the old bridge instance; the
    # caller is responsible for restarting those VMs afterward.
    echo "[network] $NAME start failed after $attempt attempts — recreating (this orphans any already-running VM's network attachment)"
    virsh net-destroy  "$NAME" 2>/dev/null || true
    virsh net-undefine "$NAME" 2>/dev/null || true
fi

NETWORK_BASE="${HOST_IP%.*}"

XML=$(mktemp /tmp/mattx-net-XXXXXX.xml)
{
    echo "<network>"
    echo "  <name>${NAME}</name>"
    echo "  <bridge name='${BRIDGE}'/>"
    echo "  <forward mode='nat'/>"
    echo "  <ip address='${HOST_IP}' netmask='${NETMASK}'>"
    echo "    <dhcp>"
    echo "      <range start='${NETWORK_BASE}.2' end='${NETWORK_BASE}.254'/>"
    for res in "$@"; do
        mac="${res%%=*}"
        ip="${res##*=}"
        echo "      <host mac='${mac}' ip='${ip}'/>"
    done
    echo "    </dhcp>"
    echo "  </ip>"
    echo "</network>"
} > "$XML"

virsh net-define    "$XML"
rm -f "$XML"

# Same transient net-start flakiness as above applies to a brand-new
# definition too — retry before giving up outright.
STARTED=0
for attempt in 1 2 3 4 5; do
    if virsh net-start "$NAME" 2>/dev/null; then
        STARTED=1
        break
    fi
    echo "[network] net-start attempt $attempt failed (likely transient) — retrying in 2s"
    sleep 2
done
[ "$STARTED" -eq 1 ] || { echo "[network] ERROR: $NAME failed to start after $attempt attempts" >&2; exit 1; }

virsh net-autostart "$NAME"
echo "[network] $NAME started (${HOST_IP}, bridge=${BRIDGE}, $# reservations)"
