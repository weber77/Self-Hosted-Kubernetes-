#!/usr/bin/env bash
set -e

# ---------------------------------------------------------------------------
# create-vuln-vm.sh — Provision an ISOLATED Ubuntu 24.04 VM for CrackArmor
# AppArmor vulnerability research (CVE-2026-23268 and related).
#
# WARNING: This VM runs a deliberately UNPATCHED kernel.
#          NEVER run this on a production host or a machine you care about.
#          Use a dedicated KVM hypervisor or a throwaway machine.
#
# Prerequisites:
#   - KVM installed (see install-kvm.sh at the repo root)
#   - At least 4 GB free RAM and 25 GB free disk
#
# Usage:
#   ./create-vuln-vm.sh [--name <vm-name>]
#
# The VM will boot with:
#   - Ubuntu 24.04 (Noble Numbat) cloud image — ships AppArmor enabled
#   - Kernel >= 4.11  (AppArmor confused-deputy flaw exists since v4.11)
#   - Postfix installed (needed for the Sudo+Postfix LPE chain)
#   - An unprivileged user "jane" for exploit testing
#   - apparmor-utils installed (provides apparmor_parser, aa-exec, etc.)
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  create-vuln-vm.sh [options]

Options:
  -n, --name <name>   VM name (default: crackarmor-lab)
  -h, --help          Show this help

Example:
  ./create-vuln-vm.sh
  ./create-vuln-vm.sh --name mytest
EOF
}

VM_NAME="crackarmor-lab"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)
      [[ -z "${2:-}" ]] && { echo "Error: --name requires a value" >&2; usage; exit 1; }
      VM_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

IMAGE_DIR="/var/lib/libvirt/images"
BASE_IMAGE="${IMAGE_DIR}/noble-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

DISK="${IMAGE_DIR}/${VM_NAME}.qcow2"
SEED="${IMAGE_DIR}/${VM_NAME}-seed.iso"
WORKDIR="/tmp/${VM_NAME}-cloudinit"

DISK_GB=25
RAM_MB=4096
VCPUS=2

echo "=============================================="
echo "CrackArmor Vulnerable VM Provisioner"
echo "=============================================="
echo "VM name  : $VM_NAME"
echo "Image    : Ubuntu 24.04 (Noble Numbat)"
echo "Disk     : ${DISK_GB}G"
echo "RAM      : ${RAM_MB}MB"
echo "vCPUs    : ${VCPUS}"
echo "=============================================="
echo
echo "!!! WARNING !!!"
echo "This creates a deliberately vulnerable VM."
echo "Do NOT expose it to untrusted networks."
echo "=============================================="
echo

# ------------------------------------------------
# Preflight checks
# ------------------------------------------------
REQUIRED_PKGS=(qemu-kvm libvirt-daemon-system libvirt-clients virtinst cloud-image-utils wget)
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    echo "Installing $pkg ..."
    sudo apt-get update -qq
    sudo apt-get install -y "$pkg"
  fi
done

sudo systemctl enable --now libvirtd

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

sudo mkdir -p "$IMAGE_DIR"

# ------------------------------------------------
# Download Ubuntu 24.04 cloud image (ships with AppArmor)
# ------------------------------------------------
if [ ! -f "$BASE_IMAGE" ]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  sudo wget -O "$BASE_IMAGE" "$IMAGE_URL"
else
  echo "Cloud image already exists at $BASE_IMAGE"
fi

# ------------------------------------------------
# Abort if the VM already exists
# ------------------------------------------------
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "$VM_NAME already exists. Destroy it first with:"
  echo "  sudo virsh destroy $VM_NAME && sudo virsh undefine $VM_NAME --remove-all-storage"
  exit 1
fi

# ------------------------------------------------
# Cloud-init: set up the vulnerable environment
# ------------------------------------------------
mkdir -p "$WORKDIR"

cat > "$WORKDIR/user-data" <<'USERDATA'
#cloud-config
hostname: crackarmor-lab

users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_pwauth: true
  - name: jane
    groups: users
    shell: /bin/bash
    ssh_pwauth: true

chpasswd:
  list: |
    ubuntu:ubuntu
    jane:jane
  expire: false

ssh_pwauth: true

package_update: true
package_upgrade: false

packages:
  - qemu-guest-agent
  - postfix
  - apparmor-utils
  - apparmor
  - strace
  - build-essential
  - linux-tools-common

runcmd:
  - systemctl enable --now qemu-guest-agent
  # Confirm AppArmor is active
  - aa-status || true
  # Hold the kernel package to prevent auto-patching
  - apt-mark hold linux-image-generic linux-image-$(uname -r) || true
  # Verify the confused-deputy pseudo-files exist and are world-writable
  - ls -la /sys/kernel/security/apparmor/.load /sys/kernel/security/apparmor/.remove /sys/kernel/security/apparmor/.replace || true

write_files:
  - path: /etc/motd
    content: |
      ======================================================
       CrackArmor Lab VM — VULNERABLE BY DESIGN
       Do NOT use this VM for anything other than research.
       AppArmor confused-deputy: CVE-2026-23268
      ======================================================

USERDATA

cat > "$WORKDIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"
sudo mv "$WORKDIR/seed.iso" "$SEED"

# ------------------------------------------------
# Create disk and VM
# ------------------------------------------------
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK"
sudo qemu-img resize "$DISK" "${DISK_GB}G"

sudo chown -R libvirt-qemu:libvirt-qemu "$IMAGE_DIR"
sudo find "$IMAGE_DIR" -type d -exec chmod 755 {} \;
sudo find "$IMAGE_DIR" -type f -exec chmod 644 {} \;

MAC=$(printf '52:54:00:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --disk path="$DISK",format=qcow2 \
  --disk path="$SEED",device=cdrom \
  --import \
  --network network=default,mac="$MAC" \
  --graphics none \
  --osinfo ubuntu24.04 \
  --noautoconsole

echo
echo "=============================================="
echo "VM '$VM_NAME' created successfully"
echo "=============================================="
echo
echo "Connect:  virsh console $VM_NAME"
echo "SSH:      ssh ubuntu@\$(virsh domifaddr $VM_NAME | awk '/ipv4/{print \$4}' | cut -d/ -f1)"
echo
echo "Credentials:"
echo "  ubuntu / ubuntu  (sudo, for admin tasks)"
echo "  jane   / jane    (unprivileged, for exploit testing)"
echo
echo "Get IP:   virsh net-dhcp-leases default"
echo "Destroy:  sudo virsh destroy $VM_NAME && sudo virsh undefine $VM_NAME --remove-all-storage"
