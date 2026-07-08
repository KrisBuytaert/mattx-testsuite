#!/bin/bash
# destroy-vm.sh <vm-name>
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

VM_NAME="${1:?Usage: $0 <vm-name>}"
IMAGES_DIR="/var/lib/libvirt/images/mattx-test-sdog"

virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
rm -f "$IMAGES_DIR/$VM_NAME.qcow2" "$IMAGES_DIR/$VM_NAME-seed.iso"
echo "[destroy] $VM_NAME removed"
