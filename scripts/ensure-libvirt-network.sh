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
# Destroying and recreating the bridge would disconnect already-running VMs.
if virsh net-info "$NAME" 2>/dev/null; then
    echo "[network] $NAME defined but inactive — starting"
    virsh net-start     "$NAME" 2>/dev/null || true
    virsh net-autostart "$NAME" 2>/dev/null || true
    if virsh net-info "$NAME" 2>/dev/null | grep -q "Active:.*yes"; then
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
