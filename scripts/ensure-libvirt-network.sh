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

# Multiple rigs/polecats on this host can invoke this script concurrently for
# the same shared libvirt network. Without serialization, two invocations can
# interleave their check-then-act sequences: one process's "start failed —
# recreating" branch can destroy the bridge right after another VM has already
# attached its tap to it, silently orphaning that VM's networking (its DHCP
# broadcasts leave the NIC but the tap is no longer enslaved to the live
# bridge, so they're never seen by dnsmasq). Serialize the whole
# check-then-act sequence with a host-wide lock so concurrent callers see a
# consistent state instead of racing.
LOCKFILE="/tmp/mattx-net-${NAME}.lock"
exec 9>"$LOCKFILE"
flock -w 120 9 || { echo "[network] ERROR: could not acquire lock for $NAME after 120s"; exit 1; }

# Capture net-info into a variable rather than piping it to grep -q: grep -q
# exits as soon as it finds a match, which can close the pipe while virsh is
# still writing and kill it with SIGPIPE. Under `set -o pipefail` that
# SIGPIPE-tainted exit status makes the pipeline report failure even though
# grep found the match — so an already-active network was misread as
# inactive on every check after the first, deterministically driving this
# script into the destructive "start failed — recreating" branch below and
# tearing down a perfectly healthy network (orphaning any VM already
# attached to its bridge).
NET_INFO="$(virsh net-info "$NAME" 2>/dev/null || true)"

if grep -q "Active:.*yes" <<<"$NET_INFO"; then
    echo "[network] $NAME already active"
    exit 0
fi

# Network is defined but not active (e.g. after a host reboot) — just start it.
# Destroying and recreating the bridge would disconnect already-running VMs.
if [ -n "$NET_INFO" ]; then
    echo "$NET_INFO"
    echo "[network] $NAME defined but inactive — starting"
    virsh net-start     "$NAME" 2>/dev/null || true
    virsh net-autostart "$NAME" 2>/dev/null || true
    NET_INFO="$(virsh net-info "$NAME" 2>/dev/null || true)"
    if grep -q "Active:.*yes" <<<"$NET_INFO"; then
        echo "[network] $NAME started"
        exit 0
    fi
    # Start failed (e.g. bridge config mismatch) — tear down and recreate
    echo "[network] $NAME start failed — recreating"
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
virsh net-start     "$NAME"
virsh net-autostart "$NAME"
rm -f "$XML"
echo "[network] $NAME started (${HOST_IP}, bridge=${BRIDGE}, $# reservations)"
