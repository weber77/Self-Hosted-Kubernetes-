#!/usr/bin/env bash
set -e

VM_NAME="${1:-}"

if [ -z "$VM_NAME" ]; then
  echo "ERROR: no VM name provided"
  echo "Usage: $0 <vm-name>"
  exit 1
fi

IMG_DIR="/var/lib/libvirt/images"
CLOUD_DIR="$HOME/cloudinit-$VM_NAME"
BASE_IMAGE="$IMG_DIR/jammy-server-cloudimg-amd64.img"
VM_DISK="$IMG_DIR/$VM_NAME.qcow2"
SEED_ISO="$IMG_DIR/seed-$VM_NAME.iso"

echo "=== Rebuilding VM: $VM_NAME ==="

# -------------------------------------------------
# Generate a UNIQUE MAC address
# -------------------------------------------------
# 52:54:00 is the QEMU/KVM OUI prefix.
# The last 3 bytes are randomized to guarantee uniqueness.
# DHCP assigns IP based on MAC, so this prevents duplicate IPs.
# -------------------------------------------------
MAC_ADDRESS=$(printf '52:54:00:%02x:%02x:%02x\n' \
  $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

echo "Using MAC address: $MAC_ADDRESS"

# -------------------------------------------------
# destroy + undefine if exists
# -------------------------------------------------
if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "Destroying existing VM..."
  virsh destroy "$VM_NAME" || true
  virsh undefine "$VM_NAME" || true
fi

# -------------------------------------------------
# remove old disks + seed
# -------------------------------------------------
echo "Removing old images..."
sudo rm -f "$IMG_DIR/"*"$VM_NAME"*

# -------------------------------------------------
# recreate cloud-init directory
# -------------------------------------------------
echo "Preparing cloud-init..."
rm -rf "$CLOUD_DIR"
mkdir -p "$CLOUD_DIR"
cd "$CLOUD_DIR"

# -------------------------------------------------
# user-data
# -------------------------------------------------
cat <<EOF > user-data
#cloud-config
hostname: $VM_NAME
users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
ssh_pwauth: true
EOF

# -------------------------------------------------
# meta-data
# -------------------------------------------------
cat <<EOF > meta-data
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

# -------------------------------------------------
# create seed iso
# -------------------------------------------------
cloud-localds seed-$VM_NAME.iso user-data meta-data
sudo mv seed-$VM_NAME.iso "$SEED_ISO"

# -------------------------------------------------
# copy base image (full clone)
# -------------------------------------------------
echo "Creating VM disk..."
sudo cp "$BASE_IMAGE" "$VM_DISK"
sudo chown libvirt-qemu:kvm "$VM_DISK" 2>/dev/null || true

# -------------------------------------------------
# create VM with EXPLICIT MAC
# -------------------------------------------------
echo "Creating VM..."
virt-install \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --disk path="$VM_DISK",format=qcow2 \
  --disk path="$SEED_ISO",device=cdrom \
  --import \
  --network network=default,mac="$MAC_ADDRESS" \
  --graphics none \
  --osinfo ubuntu22.04 \
  --noautoconsole

echo
echo "✅ VM rebuilt successfully"
echo "MAC: $MAC_ADDRESS"
echo
echo "Start with:"
echo "  virsh start $VM_NAME"
echo
echo "Get IP:"
echo "  virsh net-dhcp-leases default"
