#!/bin/bash
# setup-eessi.sh <alma|deb> <1|2>
# Install CVMFS client + configure EESSI on a cluster node.
set -euo pipefail

DISTRO="${1:?Usage: $0 <alma|deb> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb> <1|2>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "$DISTRO-$NODE_NUM" in
    alma-1) NODE="almanode1" ;;
    alma-2) NODE="almanode2" ;;
    deb-1)  NODE="debnode1"  ;;
    deb-2)  NODE="debnode2"  ;;
    *) echo "Usage: $0 <alma|deb> <1|2>" >&2; exit 1 ;;
esac

init_cluster "$DISTRO"

echo "[eessi] setting up CVMFS + EESSI on $NODE ..."

case "$DISTRO" in
    alma)
        run_on "$NODE" "
            set -e
            if rpm -q cvmfs &>/dev/null; then
                echo '[eessi] CVMFS already installed'
            else
                echo '[eessi] installing CVMFS on AlmaLinux...'
                sudo dnf install -y https://cvmrepo.s3.cern.ch/cvmrepo/yum/cvmfs-release-latest.noarch.rpm
                sudo dnf install -y cvmfs autofs
                sudo dnf install -y https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm
                echo '[eessi] CVMFS installed'
            fi
        "
        ;;
    deb)
        run_on "$NODE" "
            set -e
            if dpkg -l cvmfs 2>/dev/null | grep -q '^ii'; then
                echo '[eessi] CVMFS already installed'
            else
                echo '[eessi] installing CVMFS on Debian...'
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release wget autofs
                TMP=\$(mktemp -d)
                wget -q -O \"\$TMP/cvmfs-release-latest_all.deb\" \
                    https://cvmrepo.s3.cern.ch/cvmrepo/apt/cvmfs-release-latest_all.deb
                sudo dpkg -i \"\$TMP/cvmfs-release-latest_all.deb\"
                sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cvmfs
                wget -q -O \"\$TMP/cvmfs-config-eessi_latest_all.deb\" \
                    https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi_latest_all.deb
                sudo dpkg -i \"\$TMP/cvmfs-config-eessi_latest_all.deb\"
                rm -rf \"\$TMP\"
                echo '[eessi] CVMFS installed'
            fi
        "
        ;;
esac

echo "[eessi] configuring CVMFS on $NODE..."
run_on "$NODE" "
    set -e
    sudo bash -c 'cat > /etc/cvmfs/default.local' <<'EOF'
CVMFS_CLIENT_PROFILE=single
CVMFS_QUOTA_LIMIT=10000
CVMFS_HTTP_PROXY=DIRECT
CVMFS_REPOSITORIES=software.eessi.io
EOF
    sudo cvmfs_config setup
    sudo systemctl enable --now autofs 2>/dev/null || true
"

echo "[eessi] probing software.eessi.io on $NODE..."
run_on "$NODE" "
    # Explicit probe forces the FUSE connection; autofs alone only creates
    # the mountpoint without actually fetching data.
    sudo cvmfs_config probe software.eessi.io
    sudo systemctl restart autofs 2>/dev/null || true
    sleep 2
"

echo "[eessi] verifying EESSI data on $NODE..."
EESSI_VERSIONS=$(run_on "$NODE" "
    ls /cvmfs/software.eessi.io/versions/ 2>/dev/null || true
" || true)

if [ -z "$EESSI_VERSIONS" ]; then
    echo "[eessi] mount present but empty — attempting full remount on $NODE..."
    run_on "$NODE" "
        echo '[eessi] unmounting stale CVMFS...'
        sudo cvmfs_config umount 2>/dev/null || true
        sudo umount /cvmfs/software.eessi.io 2>/dev/null || true
        sleep 2
        echo '[eessi] restarting autofs...'
        sudo systemctl restart autofs
        sleep 3
        echo '[eessi] re-probing...'
        sudo cvmfs_config probe software.eessi.io || true
        sleep 3
        echo '[eessi] current mount state:'
        mount | grep cvmfs || echo '  (no cvmfs mounts)'
        echo '[eessi] CVMFS process state:'
        sudo cvmfs_config status 2>/dev/null || true
        echo '[eessi] connectivity check to stratum-1:'
        curl -sI --max-time 10 http://cvmfs-stratum-one.cern.ch/cvmfs/software.eessi.io/.cvmfspublished \
            | head -3 || echo '  WARNING: stratum-1 unreachable'
    "
    EESSI_VERSIONS=$(run_on "$NODE" "
        ls /cvmfs/software.eessi.io/versions/ 2>/dev/null || true
    " || true)
fi

if [ -z "$EESSI_VERSIONS" ]; then
    echo "[eessi] ERROR: /cvmfs/software.eessi.io still empty after remount on $NODE" >&2
    echo "[eessi] Diagnostics:" >&2
    run_on "$NODE" "
        echo '--- /etc/cvmfs/default.local ---'
        cat /etc/cvmfs/default.local
        echo '--- cvmfs_config chksetup ---'
        sudo cvmfs_config chksetup 2>&1 || true
        echo '--- autofs status ---'
        sudo systemctl status autofs --no-pager 2>&1 | tail -20 || true
        echo '--- dmesg FUSE ---'
        sudo dmesg | grep -i 'fuse\|cvmfs' | tail -20 || true
    " >&2 || true
    exit 1
fi

echo "[eessi] EESSI versions available on $NODE: $(echo "$EESSI_VERSIONS" | tr '\n' ' ')"
echo "[eessi] $NODE ready"
