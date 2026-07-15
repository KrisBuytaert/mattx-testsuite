#!/bin/bash
# Shared SSH/rsync helpers. Source this, then call init_cluster <alma|deb>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
KEYS_DIR="$TEST_DIR/keys"
SSH_KEY="$KEYS_DIR/mattx_test"
SSH_USER="mattx"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"

node_ip() {
    case "$1" in
        almanode1) echo "192.168.100.11" ;;
        almanode2) echo "192.168.100.12" ;;
        debnode1)  echo "192.168.100.21" ;;
        debnode2)  echo "192.168.100.22" ;;
        ubunode1)  echo "192.168.100.31" ;;
        ubunode2)  echo "192.168.100.32" ;;
        *) echo "ERROR: unknown node '$1'" >&2; exit 1 ;;
    esac
}

run_on() {
    local node="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_USER@$(node_ip "$node")" "$@"
}


rsync_to() {
    local src="$1" node="$2" dst="$3"
    # shellcheck disable=SC2086
    rsync -az --delete -e "ssh $SSH_OPTS" "$src" "$SSH_USER@$(node_ip "$node"):$dst"
}

rsync_from() {
    local node="$1" src="$2" dst="$3"
    # shellcheck disable=SC2086
    rsync -az -e "ssh $SSH_OPTS" "$SSH_USER@$(node_ip "$node"):$src" "$dst"
}

wait_for_ssh() {
    local node="$1"
    local ip
    ip="$(node_ip "$node")"
    echo "[wait] waiting for SSH on $node ($ip) ..."
    local i=0
    # shellcheck disable=SC2086
    until ssh $SSH_OPTS "$SSH_USER@$ip" true 2>/dev/null; do
        sleep 5
        i=$((i+1))
        [ "$i" -lt 180 ] || { echo "[error] SSH timeout on $node after 15 min"; exit 1; }
    done
    echo "[wait] $node ready"
}

# Wait until a node stops accepting SSH connections (i.e. has actually gone down).
# Use this immediately after issuing a reboot, before calling wait_for_ssh,
# to avoid a race where the node is still up when we start polling.
wait_for_ssh_down() {
    local node="$1"
    local ip
    ip="$(node_ip "$node")"
    echo "[wait] waiting for $node ($ip) to go offline..."
    local i=0
    # shellcheck disable=SC2086
    while ssh $SSH_OPTS "$SSH_USER@$ip" true 2>/dev/null; do
        sleep 3
        i=$((i+1))
        [ "$i" -lt 40 ] || break  # 2 min max; if it never went down, proceed anyway
    done
    echo "[wait] $node is offline"
}

init_cluster() {
    local distro="$1"
    case "$distro" in
        alma|deb|ubu) ;;
        *) echo "ERROR: unknown distro '$distro'" >&2; exit 1 ;;
    esac
    [ -f "$SSH_KEY" ] || {
        echo "ERROR: SSH key $SSH_KEY not found — run: make keys" >&2
        exit 1
    }
}

check_prereqs() {
    local ok=1
    for cmd in virsh virt-install qemu-img rsync ssh curl; do
        command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found" >&2; ok=0; }
    done
    { command -v cloud-localds || command -v genisoimage || command -v mkisofs; } \
        >/dev/null 2>&1 || {
        echo "ERROR: need cloud-localds, genisoimage, or mkisofs for seed ISOs" >&2
        ok=0
    }
    [ "$ok" -eq 1 ]
}
