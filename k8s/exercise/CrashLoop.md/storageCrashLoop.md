## Goal

Create a Pod that uses **PersistentVolume (PV) + PersistentVolumeClaim (PVC)** and then intentionally fails on startup so Kubernetes restarts it until you see **CrashLoopBackOff**.

This is a safe demo: the Pod will crash because it can’t write to the mounted storage (permission denied), not because the cluster is broken.

## Requirements

- Host OS: Ubuntu
- Disk: > 25GB free
- RAM: >= 8GB

## 1) Create the cluster (KVM + k8s-homelab)

Clone the repo, install KVM, and create a small cluster (1 control plane, 2 workers).

```bash
chmod +x install-kvm.sh
./install-kvm.sh

cd k8s-homelab/cluster
chmod +x *
./cluster.sh --control-planes 1 --workers 2  # same as: ./cluster.sh -cp 1 -w 2
```

If DHCP is “stuck”, release and renew so you can SSH in:

```bash
virsh net-dhcp-release default
```

SSH to the control plane VM (replace the IP you see for `k8s-cp-1`):

```bash
ssh ubuntu@<k8s-cp-1-IP>
```

Password: `ubuntu`

Confirm the cluster is up:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

## 2) Create a PV + PVC + “crashy” Pod

Create a file named `persistentStorage.yaml` and paste this YAML.

Important idea:

- The PV uses `hostPath` on the node: `/home/ubuntu/storage-demo` with `DirectoryOrCreate`.
- Kubernetes creates that directory on the node as `root:root` and it is typically **not writable** by a non-root user.
- The container runs as user `1000` and tries to write a file into `/data` (the mounted volume).
- That write fails → the container exits with error → Kubernetes restarts it → **CrashLoopBackOff**.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: task-pv-volume
  labels:
    type: local
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "home/ubuntu/storage-demo"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: task-pv-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-crashloop-demo
spec:
  volumes:
    - name: task-pv-storage
      persistentVolumeClaim:
        claimName: task-pv-claim
  containers:
    - name: writer
      image: alpine:3.20
      command: ["sh", "-c", "echo 'hello from pod' > /data/hello.txt"]
      securityContext:
        runAsUser: 1000
      volumeMounts:
        - mountPath: "/data"
          name: task-pv-storage
```

Apply it:

```bash
kubectl apply -f persistentStorage.yaml
```

## 3) Watch it enter CrashLoopBackOff

Watch the Pod status change live:

```bash
kubectl get pods -w
```

After a few restarts you should see `CrashLoopBackOff` for `storage-crashloop-demo`.

## 4) Prove *why* it’s crashlooping

Describe the Pod and look at Events (near the bottom). You should see restarts and non-zero exit codes.

```bash
kubectl describe pod storage-crashloop-demo
```

Check the container logs. Because it crashes quickly, you may also want `--previous` (logs from the last crashed container instance):

```bash
kubectl logs storage-crashloop-demo
kubectl logs --previous storage-crashloop-demo
```

You should see a permission error like “can’t create /data/hello.txt: Permission denied”.

## 5) Cleanup

```bash
kubectl delete -f persistentStorage.yaml
```

If you want to also remove the directory on the node (optional), SSH to the node where it was created and delete it:

```bash
sudo rm -rf /home/ubuntu/storage-demo
```

