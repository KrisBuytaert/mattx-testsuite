#!/bin/bash
# create-vm.sh <alma|deb|ubu> <1|2>
# Downloads base cloud image (once), creates a thin qcow2 clone,
# builds a cloud-init seed ISO, and starts the VM via virt-install.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

DISTRO="${1:?Usage: $0 <alma|deb|ubu> <1|2>}"
NODE_NUM="${2:?Usage: $0 <alma|deb|ubu> <1|2>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/../keys"
BASE_CACHE="/var/lib/libvirt/images/mattx-base-sdog"   # survives make clean
IMAGES_DIR="/var/lib/libvirt/images/mattx-test-sdog"   # per-VM disks, wiped on clean

case "$DISTRO" in
    alma)
        VM_NAME="almanode${NODE_NUM}"
        BASE_URL="https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
        BASE_IMAGE="$BASE_CACHE/almalinux-10-base.qcow2"
        OS_VARIANT="almalinux9"
        case "$NODE_NUM" in
            1) MAC="52:54:00:0a:00:11" ;;
            2) MAC="52:54:00:0a:00:12" ;;
            *) echo "ERROR: node num must be 1 or 2" >&2; exit 1 ;;
        esac
        ;;
    deb)
        VM_NAME="debnode${NODE_NUM}"
        BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
        BASE_IMAGE="$BASE_CACHE/debian-13-base.qcow2"
        OS_VARIANT="debian13"
        case "$NODE_NUM" in
            1) MAC="52:54:00:0b:00:21" ;;
            2) MAC="52:54:00:0b:00:22" ;;
            *) echo "ERROR: node num must be 1 or 2" >&2; exit 1 ;;
        esac
        ;;
    ubu)
        VM_NAME="ubunode${NODE_NUM}"
        BASE_URL="https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
        BASE_IMAGE="$BASE_CACHE/ubuntu-26-base.qcow2"
        OS_VARIANT="ubuntu25.10"
        case "$NODE_NUM" in
            1) MAC="52:54:00:0b:00:31" ;;
            2) MAC="52:54:00:0b:00:32" ;;
            *) echo "ERROR: node num must be 1 or 2" >&2; exit 1 ;;
        esac
        ;;
    *)
        echo "ERROR: unknown distro '$DISTRO'" >&2; exit 1
        ;;
esac

VM_DISK="$IMAGES_DIR/$VM_NAME.qcow2"
SEED_ISO="$IMAGES_DIR/$VM_NAME-seed.iso"
PUBKEY="$(cat "$KEYS_DIR/mattx_test.pub")"

# ---- idempotency checks ----
if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
    echo "[create] $VM_NAME already running — skipping"
    exit 0
fi
if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "shut off"; then
    echo "[create] $VM_NAME shut off — starting"
    virsh start "$VM_NAME"
    exit 0
fi

# ---- directories ----
mkdir -p "$BASE_CACHE" "$IMAGES_DIR"

# ---- download base image once, resume-safe ----
if [ -f "$BASE_IMAGE" ]; then
    echo "[create] base image already cached: $BASE_IMAGE"
else
    echo "[create] downloading $DISTRO base image (stored in $BASE_CACHE, never deleted by make clean)..."
    curl -L --progress-bar -C - -o "${BASE_IMAGE}.tmp" "$BASE_URL"
    mv "${BASE_IMAGE}.tmp" "$BASE_IMAGE"
    echo "[create] cached: $BASE_IMAGE"
fi

# ---- thin clone ----
echo "[create] creating disk for $VM_NAME (10 GB sparse)..."
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$VM_DISK" 10G

# ---- cloud-init seed ISO ----
SEED_DIR="$(mktemp -d)"
trap 'rm -rf "$SEED_DIR"' EXIT

cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local
users:
  - name: mattx
    groups: [sudo, wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${PUBKEY}
ssh_pwauth: false
EOF

cat > "$SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

SEED_TMP="$SEED_DIR/seed.iso"
if command -v cloud-localds &>/dev/null; then
    cloud-localds "$SEED_TMP" "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
elif command -v genisoimage &>/dev/null; then
    genisoimage -quiet -output "$SEED_TMP" -volid cidata \
        -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
elif command -v mkisofs &>/dev/null; then
    mkisofs -quiet -output "$SEED_TMP" -volid cidata \
        -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
fi
mv "$SEED_TMP" "$SEED_ISO"

# ---- launch VM ----
echo "[create] launching $VM_NAME..."
virt-install \
    --connect qemu:///system \
    --name        "$VM_NAME" \
    --memory      2048 \
    --vcpus       2 \
    --disk        "path=$VM_DISK,format=qcow2,bus=virtio" \
    --disk        "path=$SEED_ISO,device=cdrom,readonly=on" \
    --import \
    --os-variant  "$OS_VARIANT" \
    --network     "network=mattx-test,mac=$MAC" \
    --video virtio \
    --noautoconsole \
    --wait        0

echo "[create] $VM_NAME launched"
