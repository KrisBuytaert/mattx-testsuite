#!/bin/bash
# relocate-images.sh -- one-shot, run as root (sudo): move the test VMs' disks from
# /var/lib/libvirt/images to /opt/libvirt-images, enable discard on their disks and
# repoint libvirt (domains + the mattx-test-sdog storage pool) at the new place.
#
#   sudo scripts/relocate-images.sh              # copy + repoint, keep the old files
#   sudo scripts/relocate-images.sh --delete-old # same, then remove the old copies
#
# The VMs are stopped (virsh destroy) for the move and started again afterwards;
# they hold no state worth keeping (every deploy reboots them anyway).
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
OLD=/var/lib/libvirt/images
NEW="${MATTX_IMAGES_ROOT:-/opt/libvirt-images}"
OWNER="${SUDO_USER:-sdog}"
DOMS="almanode1 almanode2 almanode3"
POOL=mattx-test-sdog
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

need=$(du -sk "$OLD/mattx-base-sdog" "$OLD/mattx-test-sdog" | awk '{s+=$1} END{print s}')
avail=$(df -Pk "$(dirname "$NEW")" | awk 'NR==2{print $4}')
echo "need ${need}K, $(dirname "$NEW") has ${avail}K free"
[ "$avail" -gt $((need + 2*1024*1024)) ] || { echo "not enough room (want 2G spare)" >&2; exit 1; }

echo "== stopping VMs"
for d in $DOMS; do virsh domstate "$d" >/dev/null 2>&1 && virsh destroy "$d" 2>/dev/null || true; done

echo "== copying (sparse)"
install -d -m 2775 -o "$OWNER" -g libvirt "$NEW"
for d in mattx-base-sdog mattx-test-sdog; do
    install -d -m 2775 -o "$OWNER" -g libvirt "$NEW/$d"
    rsync -a --sparse --info=progress2 "$OLD/$d/" "$NEW/$d/"
done

echo "== SELinux label"
if command -v semanage >/dev/null; then
    semanage fcontext -a -t virt_image_t "$NEW(/.*)?" 2>/dev/null || semanage fcontext -m -t virt_image_t "$NEW(/.*)?"
fi
restorecon -R "$NEW" 2>/dev/null || true

echo "== repointing backing files"
for f in "$NEW"/mattx-test-sdog/*.qcow2; do
    b=$(qemu-img info -U "$f" | sed -n 's/^backing file: //p')
    [ -n "$b" ] || continue
    qemu-img rebase -u -f qcow2 -b "${b/$OLD/$NEW}" -F qcow2 "$f"
done

echo "== repointing libvirt (domains + discard=unmap)"
for d in $DOMS; do
    virsh dumpxml --inactive "$d" > "/root/$d.xml.bak"
    sed -e "s#$OLD#$NEW#g" \
        -e "s#<driver name='qemu' type='qcow2'\\(/>\\| \\)#<driver name='qemu' type='qcow2' discard='unmap'\\1#" \
        "/root/$d.xml.bak" > "/root/$d.xml.new"
    grep -q "discard='unmap'" "/root/$d.xml.new" || { echo "discard not added for $d" >&2; exit 1; }
    virsh define "/root/$d.xml.new" >/dev/null
done
virsh pool-dumpxml --inactive "$POOL" | sed "s#$OLD#$NEW#g" > /root/pool.xml.new
virsh pool-destroy "$POOL" >/dev/null
virsh pool-undefine "$POOL" >/dev/null
virsh pool-define /root/pool.xml.new >/dev/null
virsh pool-start "$POOL" >/dev/null
virsh pool-autostart "$POOL" >/dev/null

echo "== verifying"
for f in "$NEW"/mattx-test-sdog/*.qcow2; do qemu-img check -U "$f" | tail -1; done
for d in $DOMS; do virsh dumpxml --inactive "$d" | grep -c "$OLD" | sed "s/^/$d: references to old path: /"; done

echo "== starting VMs"
for d in $DOMS; do virsh start "$d"; done

if [ "${1:-}" = --delete-old ]; then
    echo "== removing old copies"
    rm -rf "$OLD/mattx-base-sdog" "$OLD/mattx-test-sdog"
else
    echo "Old copies kept in $OLD/mattx-{base,test}-sdog -- rerun with --delete-old, or remove them yourself once the VMs are confirmed up."
fi
df -h / "$NEW" | cat
