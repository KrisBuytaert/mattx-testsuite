#!/bin/bash
# setup-node.sh <alma|deb> <1|2>
# Waits for SSH, installs build/runtime deps, configures /etc/hosts.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb> <1|2>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO-$NODE_NUM" in
    alma-1) NODE="almanode1"; PEER="almanode2"; PEER_IP="192.168.100.12" ;;
    alma-2) NODE="almanode2"; PEER="almanode1"; PEER_IP="192.168.100.11" ;;
    deb-1)  NODE="debnode1";  PEER="debnode2";  PEER_IP="192.168.100.22" ;;
    deb-2)  NODE="debnode2";  PEER="debnode1";  PEER_IP="192.168.100.21" ;;
    *) echo "Usage: $0 <alma|deb> <1|2>" >&2; exit 1 ;;
esac

init_cluster "$DISTRO"
wait_for_ssh "$NODE"

# Full system update first so the running kernel matches available kernel-devel.
# Cloud images ship a kernel that may lag the repo; building against mismatched
# headers produces a .ko with the wrong vermagic and insmod rejects it.
echo "[setup] updating $NODE and rebooting into latest kernel..."
case "$DISTRO" in
    alma)
        run_on "$NODE" "sudo dnf update -y"
        ;;
    deb)
        # -o DPkg::Lock::Timeout makes apt itself wait for the dpkg frontend
        # lock instead of failing fast — cloud-init/unattended-upgrades often
        # hold it for a while right after boot. Waiting on `apt-get update`
        # (which uses a different lock) doesn't guarantee this one is free.
        run_on "$NODE" "sudo apt-get update -qq -o DPkg::Lock::Timeout=180"
        run_on "$NODE" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o DPkg::Lock::Timeout=180"
        ;;
esac
run_on "$NODE" "sudo reboot" || true
wait_for_ssh_down "$NODE"
wait_for_ssh "$NODE"

echo "[setup] installing packages on $NODE..."
case "$DISTRO" in
    alma)
        # CRB repo is required for libnl3-devel on AlmaLinux 10 / RHEL 10
        run_on "$NODE" "sudo dnf config-manager --set-enabled crb 2>/dev/null || true"
        run_on "$NODE" "sudo dnf install -y gcc make git pkg-config rsync libnl3-devel kernel-devel \
            policycoreutils-python-utils setools-console nmap-ncat"
        # Set SELinux permissive — mattx-stub runs as kernel_generic_helper_t which by default
        # cannot create netlink_generic_socket or write to /tmp. A proper policy module needs
        # to be built once we have a full audit log; use 'make selinux-policy-alma' for that.
        run_on "$NODE" "sudo setenforce 0 || true"
        run_on "$NODE" "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config"
        run_on "$NODE" "
            KVER=\$(uname -r)
            sudo ln -sfn \"/usr/src/kernels/\${KVER}\" \"/lib/modules/\${KVER}/build\"
            [ -f \"/lib/modules/\${KVER}/build/Makefile\" ] || {
                echo 'ERROR: kernel headers missing for '\"\${KVER}\" >&2; exit 1
            }
            echo '[setup] kernel headers OK: '\"\${KVER}\"
        "
        ;;
    deb)
        run_on "$NODE" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=180 \
            gcc make git pkg-config libnl-3-dev libnl-genl-3-dev rsync netcat-openbsd"
        run_on "$NODE" "
            set -e
            KVER=\$(uname -r)
            echo '[setup] installing kernel headers for '\"\${KVER}\"
            if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=180 \"linux-headers-\${KVER}\" 2>/dev/null; then
                echo '[setup] exact headers not cached; refreshing apt and retrying...'
                sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=180
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=180 \"linux-headers-\${KVER}\" || {
                    echo '[setup] WARNING: exact headers unavailable, falling back to linux-headers-amd64'
                    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=180 linux-headers-amd64
                    echo '[setup] WARNING: running kernel may not match installed headers — build might fail'
                }
            fi
            [ -d \"/lib/modules/\${KVER}/build\" ] || {
                echo 'ERROR: no build dir under /lib/modules/'\"\${KVER}\" >&2; exit 1
            }
            echo '[setup] kernel headers OK: '\"\${KVER}\"
        "
        ;;
esac

echo "[setup] adding $PEER to /etc/hosts on $NODE..."
HOSTS_LINE="$PEER_IP $PEER"
run_on "$NODE" "grep -qF '$PEER' /etc/hosts || echo '$HOSTS_LINE' | sudo tee -a /etc/hosts >/dev/null"

run_on "$NODE" "sudo mkdir -p /mattxfs"

echo "[setup] $NODE ready"
