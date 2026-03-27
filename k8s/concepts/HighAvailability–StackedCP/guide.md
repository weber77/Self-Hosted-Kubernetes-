## High Availability Using a Stacked Control Plane (this repo’s lab)

This guide is a **runbook for this repo** (`Self-Hosted-Kubernetes-`) to build a **stacked-etcd HA control plane** with kubeadm on libvirt/KVM VMs.

### What “HA” means here (and what it doesn’t)

- **Stacked control plane**: each control-plane node runs `kube-apiserver`, `controller-manager`, `scheduler`, **and** a local `etcd` member.
- **HA requirement**: clients must talk to a **stable API endpoint** (load balancer or virtual IP). Without that, a multi-control-plane cluster is _not_ truly highly available for API access.

Important: the repo’s current automation script (`cluster/cluster.sh`) creates multiple control planes, but **does not configure** `--control-plane-endpoint`. That means:

- If the “primary” control plane goes down, **your `kubectl` endpoint likely breaks** unless you manually switch to another control-plane IP.
- The cluster may still function internally, but you don’t have HA access to the API.

This guide gives you two paths:

- **Path A (quick)**: use the existing scripts to create a _multi-control-plane_ cluster (**not full HA**).
- **Path B (recommended)**: implement a real HA API endpoint using a **VIP via kube-vip** (no external LB VM required) or an **HAProxy VM** (simple TCP forwarder).

---

## Prerequisites (your repo + lab)

- **A Linux host with KVM/libvirt** (the `vm/` and `cluster/` scripts assume `virsh`, libvirt networking, etc.).
- **A Kubernetes-ready VM base image**: this repo expects VMs to be cloned from `/var/lib/libvirt/images/k8s-base.qcow2`, which includes `containerd`, `kubeadm`, `kubelet`, and `kubectl` (v1.33.0 in current scripts).
- **VMs**: for HA, use **3 control planes** (odd number for etcd quorum) and any number of workers.
- **Credentials** (default from this repo’s VM provisioning): user `ubuntu`, password `ubuntu`.
- **Network**: all VMs on the same L2 segment (libvirt `default` NAT network is fine for the lab).
- **Ports** between nodes (within the libvirt network):
  - `6443/tcp` Kubernetes API
  - `2379-2380/tcp` etcd peer/client
  - `10250/tcp` kubelet API
  - plus CNI-specific traffic (Flannel VXLAN by default in this repo’s current flow)

Repo references:

- `cluster/cluster.sh`: creates VMs, runs `kubeadm init`, installs Flannel, joins control planes + workers.
- `cluster/purge-cluster.sh`: tear down VMs / clean lab.
- `cluster/join-workers.sh`: reset + join workers (useful for recovery).
- `cluster/prepare-image.sh`: builds `/var/lib/libvirt/images/k8s-base.qcow2` (Kubernetes-ready golden image).

---

## Variables to decide up front

Pick these before you start (examples assume libvirt `default` network `192.168.122.0/24`):

- `CP_COUNT=3`
- `W_COUNT=2` (or whatever you want)
- **API endpoint strategy** (choose one):
  - **VIP (recommended)**: `API_VIP=192.168.122.50` (must be unused)
  - **LB VM**: `LB_IP=192.168.122.60` and it forwards to all CPs
- **Kubernetes version**: this repo’s `cluster/cluster.sh` currently pins `--kubernetes-version=v1.33.0`
- **Pod CIDR**: pick a Pod CIDR that does **not** overlap your VM subnet (libvirt is often `192.168.122.0/24`). Example: `10.244.0.0/16`.

---

## Path A: Use current automation (multi-control-plane, not full HA)

Use this if you mainly want “multiple control planes” quickly, and you accept that your API endpoint is tied to the first control plane.

From `Self-Hosted-Kubernetes-/cluster/` on the libvirt host:

```bash
chmod +x cluster.sh create-vms.sh prepare-image.sh purge-cluster.sh join-workers.sh
./cluster.sh --control-planes 3 --workers 2
```

What happens (high level):

- VMs are created as `k8s-cp-a`, `k8s-cp-b`, `k8s-cp-c`, `k8s-w-a`, `k8s-w-b`
- The script runs `kubeadm init` on the first CP, applies Flannel, then joins other CPs and workers

Verify (from the first control plane VM):

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

Limitation: if `k8s-cp-a` is down, the API endpoint you used to talk to the cluster is down too (unless you switch to another CP IP manually).

---

## Path B (recommended): true stacked-CP HA with a stable API endpoint

You have two good options for a lab:

- **Option B1: kube-vip (VIP)**: no extra VM, clients use `API_VIP:6443`
- **Option B2: HAProxy VM**: one extra “lb” VM that forwards `:6443` to all CPs

### Option B1: kube-vip VIP (no load balancer VM)

This is typically the cleanest “homelab HA” approach.

#### Step 0: Ensure your VMs will have kubeadm/kubectl (prepare the base image)

On the KVM/libvirt host, from `Self-Hosted-Kubernetes-/cluster/`:

```bash
cd Self-Hosted-Kubernetes-/cluster
chmod +x cluster.sh prepare-image.sh create-vms.sh worker-node.sh
./cluster.sh --prepare-image
```

This creates/updates the golden image at:

- `/var/lib/libvirt/images/k8s-base.qcow2`

All VMs created afterward via `cluster/create-vms.sh` will inherit the Kubernetes tooling from that image.

#### Step 1: Create the VMs (control planes + workers)

You can still use the repo to create VMs. If you run `cluster/cluster.sh` it will also initialize Kubernetes, which we _don’t_ want yet for HA (because we need `--control-plane-endpoint`).

So create VMs only using `cluster/create-vms.sh` (it’s a VM provisioner, not a kubeadm runner):

```bash
cd Self-Hosted-Kubernetes-/cluster
chmod +x create-vms.sh
./create-vms.sh --prefix k8s --role cp 3
./create-vms.sh --prefix k8s --role w  2
```

Get the IPs:

```bash
virsh net-dhcp-leases default
```

Write down:

- `CP1_IP`, `CP2_IP`, `CP3_IP`
- `WORKER_IPS...`
- Choose an unused `API_VIP` in the same subnet (example: `192.168.122.50`)

#### Step 2: Install kube-vip as a static Pod (so the VIP exists before kubeadm checks it)

On the first control plane, create a kube-vip manifest that:

- advertises `API_VIP` on the control-plane nodes
- listens on `:6443`

For this lab, the common approach is to deploy kube-vip as a static Pod in `/etc/kubernetes/manifests/` so it comes up early and is managed by kubelet.

Bootstrap gotcha (important):

- On a brand-new node, **kubelet often won’t start successfully until after `kubeadm init` writes its config**.
- That means a kube-vip **static Pod may not actually start early enough** to satisfy kubeadm’s first health checks against the VIP.

The reliable lab bootstrap is:

- **Temporarily add the VIP to the first control plane interface** (so the VIP is reachable immediately)
- Run `kubeadm init --control-plane-endpoint VIP:6443`
- Then deploy kube-vip so it can “own” the VIP long-term (and later move it during failover)

Run (adjust interface name if needed; on Ubuntu/libvirt it’s often `enp1s0`):

```bash
ip -o link show | awk -F': ' '{print $2}' | grep -E '^(ens|enp|eth)' | head -n1
```

Assume it prints `enp1s0`. Then:

```bash
export VIP=192.168.122.50
export IFACE=enp1s0

sudo ip addr add "${VIP}/32" dev "${IFACE}" || true
sudo arping -I "${IFACE}" -c 3 "${VIP}" || true

sudo mkdir -p /etc/kubernetes/manifests

sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  # Pin the static Pod to this node (useful clarity for static Pods).
  nodeName: $(hostname)
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:latest
      args:
        - manager
      env:
        # Static Pods do NOT get a ServiceAccount token by default.
        # Without a kubeconfig, kube-vip will crash with:
        #   open /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or directory
        - name: KUBECONFIG
          value: /etc/kubernetes/admin.conf
        - name: vip_arp
          value: "true"
        - name: vip_interface
          value: "${IFACE}"
        - name: vip_cidr
          value: "32"
        - name: vip_address
          value: "${VIP}"
        - name: port
          value: "6443"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: "kube-system"
        - name: vip_leaderelection
          value: "true"
      securityContext:
        capabilities:
          add: ["NET_ADMIN","NET_RAW"]
      volumeMounts:
        - name: k8s-admin-conf
          mountPath: /etc/kubernetes/admin.conf
          readOnly: true
  volumes:
    - name: k8s-admin-conf
      hostPath:
        path: /etc/kubernetes/admin.conf
        type: File
EOF
```

Note: you do not need to pre-pull the image; kubelet will pull it when it starts the static Pod.

Validate the VIP comes up:

```bash
ip addr show "$IFACE" | grep -F "$VIP" || true
```

If `kube-vip` is `CrashLoopBackOff`, check logs:

```bash
kubectl -n kube-system logs kube-vip-$(hostname) --previous || true
```

Once kube-vip is running and you can see the VIP on the interface, you may remove the temporary VIP assignment (optional):

```bash
sudo ip addr del "${VIP}/32" dev "${IFACE}" || true
```

If the VIP does not appear, the most common issues are:

- wrong interface name
- `API_VIP` already in use
- L2/ARP behavior blocked (rare in a simple libvirt network)

#### Step 3: Bootstrap the first control plane using the VIP endpoint

SSH/console into the first control plane and run:

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet

sudo kubeadm init \
  --control-plane-endpoint "192.168.122.50:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket unix:///run/containerd/containerd.sock

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

If you already tried `kubeadm init` and got an error like “`Get https://<VIP>:6443/livez: context deadline exceeded`”, it usually means the VIP wasn’t up yet. Recovery on that node:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d /var/lib/cni "$HOME/.kube"
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

Then ensure kube-vip is running and the VIP is present on the interface, and rerun `kubeadm init`.

```bash
kubectl -n kube-system get pods -o wide | grep kube-vip || true
```

Install Calico (configured to match the Pod CIDR you used in `kubeadm init`):

```bash
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

# IMPORTANT: make Calico's IP pool match kubeadm's --pod-network-cidr.
# This guide uses 10.244.0.0/16, so replace the default 192.168.0.0/16.
sudo sed -i 's#value: "192\\.168\\.0\\.0/16"#value: "10.244.0.0/16"#' calico.yaml

kubectl apply -f calico.yaml
```

Optional (if you want to schedule workloads on control planes in the lab):

```bash
kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule-
```

#### Step 4: Join the remaining control planes

Back on CP1, generate the join commands:

```bash
sudo kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs
```

You’ll use:

- the `kubeadm join ... --discovery-token-ca-cert-hash ...` command
- plus `--control-plane --certificate-key <KEY>`

On CP2 and CP3:

- join control-plane

```bash
sudo kubeadm join 192.168.122.50:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>
```

- configure kubectl:

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

#### Step 4.1: Install kube-vip on _every_ control-plane node (required for VIP failover)

For VIP failover to work, `kube-vip` must be running on **all** control-plane nodes (`k8s-cp-a`, `k8s-cp-b`, `k8s-cp-c`) with the **same** `vip_address` and the correct `vip_interface` for each node.

1. Ensure each control plane has an admin kubeconfig at `/etc/kubernetes/admin.conf`.

- On `k8s-cp-a` it exists after init.
- On joined control planes it may not be present by default; copy it from `k8s-cp-a`:

```bash
# Run this on k8s-cp-b and k8s-cp-c (adjust CP1_IP as needed)
export CP1_IP=<k8s-cp-a-ip>
sudo apt-get update -y && sudo apt-get install -y sshpass

# /etc/kubernetes/admin.conf is root-readable on the remote node, so plain scp will fail.
# Use SSH to read it with sudo, and write it locally as root.
sudo mkdir -p /etc/kubernetes
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@${CP1_IP} "sudo cat /etc/kubernetes/admin.conf" \
  | sudo tee /etc/kubernetes/admin.conf >/dev/null
sudo chmod 600 /etc/kubernetes/admin.conf
```

2. Create/update the kube-vip static Pod manifest on **each** control plane (set `IFACE` correctly, e.g. `enp1s0`):

```bash
export VIP=192.168.122.50
export IFACE=enp1s0

sudo mkdir -p /etc/kubernetes/manifests

sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:latest
      args:
        - manager
      env:
        - name: KUBECONFIG
          value: /etc/kubernetes/admin.conf
        - name: vip_arp
          value: "true"
        - name: vip_leaderelection
          value: "true"
        - name: vip_interface
          value: "${IFACE}"
        - name: vip_cidr
          value: "32"
        - name: vip_address
          value: "${VIP}"
        - name: port
          value: "6443"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: "kube-system"
      securityContext:
        capabilities:
          add: ["NET_ADMIN","NET_RAW"]
      volumeMounts:
        - name: k8s-admin-conf
          mountPath: /etc/kubernetes/admin.conf
          readOnly: true
  volumes:
    - name: k8s-admin-conf
      hostPath:
        path: /etc/kubernetes/admin.conf
        type: File
EOF
```

3. Verify kube-vip health on each control plane:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pod -o wide | grep kube-vip || true
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system logs kube-vip-$(hostname) --previous || true
```

#### Step 5: Join workers

On each worker:

```bash
sudo kubeadm join 192.168.122.50:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

#### Step 6: Verify HA behavior

On any control plane (with kubeconfig):

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
kubectl -n kube-system get endpoints kubernetes -o wide
```

If `kubectl` fails on `k8s-cp-b` / `k8s-cp-c` with `localhost:8080 was refused`, that node is missing a kubeconfig.
Quick fixes:

- Use the admin kubeconfig directly:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

Then test failover:

- power off / shutdown CP1 VM
- from your workstation or another control plane, try:

```bash
kubectl get nodes
```

If it still works via `API_VIP`, your API endpoint is HA.

If it times out after destroying `k8s-cp-a`, it means the VIP did not move. Common causes:

- kube-vip is only running on `k8s-cp-a` (it must run on **all** control planes)
- kube-vip is running but cannot talk to the API (missing `/etc/kubernetes/admin.conf`)
- wrong interface set in `vip_interface` (your lab often uses `enp1s0`, not `ens3`)

Debug on `k8s-cp-b` and `k8s-cp-c`:

```bash
ip addr show enp1s0 | grep -F 192.168.122.50 || true
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pod -o wide | grep kube-vip || true
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system logs kube-vip-$(hostname) --previous || true
```

---

### Option B2: HAProxy load balancer VM (simple and explicit)

If you prefer a classic “TCP load balancer in front of CPs”, create one extra VM (outside of Kubernetes) and run HAProxy on it.

High level steps:

- Create `k8s-lb-a` VM
- Give it a fixed IP (or record its DHCP lease)
- Configure HAProxy to listen on `:6443` and forward to `CP1_IP:6443`, `CP2_IP:6443`, `CP3_IP:6443`
- Run `kubeadm init --control-plane-endpoint "<LB_IP>:6443" --upload-certs ...`
- Join additional control planes and workers using `<LB_IP>:6443`

This option is easy to reason about, but it introduces another moving piece (the LB VM).

---

## Recovery notes (practical for this repo)

- **Reset a node** (inside a VM) before rejoining:
  - Preferred: run this repo’s reset utility inside the VM: `k8s/utils/reset-k8s-node.sh`
  - Or run the manual equivalent:

```bash
sudo kubeadm reset -f
sudo rm -rf ~/.kube /etc/cni/net.d /var/lib/cni /var/lib/kubelet /etc/kubernetes
sudo systemctl restart containerd
```

- **Re-join workers in bulk from the KVM host**:
  - Use `cluster/join-workers.sh`. For HA via VIP, point it at the VIP:

```bash
cd Self-Hosted-Kubernetes-/cluster
./join-workers.sh --control-plane-ip 192.168.122.50
```

- **Re-issue a join token** (on any control plane with kubeconfig):

```bash
sudo kubeadm token create --print-join-command
```

- **Re-upload certs for adding control planes later**:

```bash
sudo kubeadm init phase upload-certs --upload-certs
```
