#!/usr/bin/env bash
set -e

VM_COUNT="$1"

if [ -z "$VM_COUNT" ]; then
  echo "Usage: $0 <number_of_vms>"
  exit 1
fi

BASE_IMAGE="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMAGE_DIR="/var/lib/libvirt/images"

echo "======================================"
echo "Kubernetes VM Provisioner"
echo "VMs requested: $VM_COUNT"
echo "======================================"

# ------------------------------------------------
# Ensure required tools exist
# ------------------------------------------------
echo "Checking required packages..."

REQUIRED_PKGS=(
  qemu-kvm
  libvirt-daemon-system
  libvirt-clients
  virtinst
  cloud-image-utils
  wget
)

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    echo "Installing $pkg"
    sudo apt-get update
    sudo apt-get install -y "$pkg"
  fi
done

# ------------------------------------------------
# Ensure libvirt service running
# ------------------------------------------------
echo "Checking libvirtd..."

sudo systemctl enable --now libvirtd

# ------------------------------------------------
# Ensure default network exists
# ------------------------------------------------
if ! sudo virsh net-info default &>/dev/null; then
  echo "Creating default libvirt network..."

  cat <<EOF | sudo tee /tmp/default-network.xml
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF

  sudo virsh net-define /tmp/default-network.xml
  sudo virsh net-start default
  sudo virsh net-autostart default
fi

if [ ! -d "$IMAGE_DIR" ]; then
  echo "Creating image directory $IMAGE_DIR"
  sudo mkdir -p "$IMAGE_DIR"
fi

# ------------------------------------------------
# Ensure Ubuntu cloud image exists
# ------------------------------------------------
echo "=== Checking Ubuntu cloud image... ==="

if [ ! -f "$BASE_IMAGE" ]; then
  echo "Downloading Ubuntu 22.04 cloud image..."
  sudo wget -O "$BASE_IMAGE" "$IMAGE_URL"
else
  echo "Image already exists"
fi

echo
echo "======================================"
echo "Creating VMs"
echo "======================================"

for i in $(seq 0 $((VM_COUNT-1))); do

  LETTER=$(printf "\\$(printf '%03o' $((97+i)))")
  VM_NAME="k8s-$LETTER"

  DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  SEED="/var/lib/libvirt/images/${VM_NAME}-seed.iso"
  WORKDIR="/tmp/${VM_NAME}-cloudinit"

  echo "----- $VM_NAME -----"

  if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "$VM_NAME already exists — skipping"
    continue
  fi

  mkdir -p "$WORKDIR"

  # ------------------------------------------------
  # Generate MAC
  # ------------------------------------------------
  MAC=$(printf '52:54:00:%02x:%02x:%02x\n' \
      $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

  echo "MAC: $MAC"

  # ------------------------------------------------
  # Cloud-init user-data
  # ------------------------------------------------
  cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: $VM_NAME

users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false

ssh_pwauth: true
package_update: true

packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  cat > "$WORKDIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"

  sudo mv "$WORKDIR/seed.iso" "$SEED"

  # ------------------------------------------------
  # Create VM disk
  # ------------------------------------------------
  sudo qemu-img create -f qcow2 -b "$BASE_IMAGE" "$DISK"

  # ------------------------------------------------
  # Create VM
  # ------------------------------------------------
  virt-install \
    --name "$VM_NAME" \
    --memory 2048 \
    --vcpus 2 \
    --disk path="$DISK",format=qcow2 \
    --disk path="$SEED",device=cdrom \
    --import \
    --network network=default,mac="$MAC" \
    --graphics none \
    --osinfo ubuntu22.04 \
    --noautoconsole

  echo "$VM_NAME created"
  echo

done

echo "======================================"
echo "VM creation finished"
echo "======================================"

echo
echo "VM list:"
echo "virsh list --all"

echo
echo "Get VM IPs:"
echo "virsh net-dhcp-leases default"
