# Rancher Local StorageClass Guide (Homelab)

This guide shows how to set up dynamic local storage using the `local-path-provisioner` and create a working `StorageClass` for a self-hosted Kubernetes cluster.

## When to use this

Use this setup when:

- Your cluster is local (VMs, bare metal, mini-PCs)
- You are not using AWS EBS, GCE PD, Azure Disk, etc.
- You want simple dynamic PVC provisioning for labs/dev workloads

## Prerequisites

- Kubernetes cluster is running and healthy
- `kubectl` is configured for the cluster
- At least one worker node has writable local disk space

Check:

```bash
kubectl get nodes -o wide
kubectl get sc
```

## Step 1) Install local-path-provisioner

Apply the official Rancher manifest:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
```

Verify:

```bash
kubectl -n local-path-storage get pods
kubectl get storageclass
```

You should see a class like `local-path`.

## Step 2) Use a StorageClass

In this repo, `storageClass.yaml` is updated for homelab usage:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Apply it:

```bash
kubectl apply -f ./storageClass.yaml
kubectl get sc
```

## Step 3) Make it default (optional)

If you want PVCs without `storageClassName` to use this class:

```bash
kubectl patch storageclass standard -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

If another default class exists, remove its default annotation first.

## Step 4) Validate with a test PVC

Create `pvc-test.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
---
```

Apply and check:

```bash
kubectl apply -f pvc-test.yaml
kubectl get pvc pvc-test
kubectl get pv
```

PVC should move to `Pending` and no PV is created because our `volumeBindingMode: WaitForFirstConsumer`.

## Step 5) Create consumer Pod

Create `test-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - mountPath: /data
          name: test-vol
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: pvc-test
```

Apply and check:

```bash
kubectl apply -f pvc-test.yaml
kubectl get pvc pvc-test -w
kubectl get pv
```

PVC should move to `Bound` and a PV should be created and status move to `Bound`.

## Important notes

- Local-path volumes are node-local, not replicated.
- If a pod moves to a different node, local data may not follow.
- Great for labs/dev/test; not ideal for highly available production data.
- For HA/distributed storage, consider Longhorn, Rook-Ceph, or NFS CSI.

## Troubleshooting

Check provisioner logs:

```bash
kubectl -n local-path-storage logs deploy/local-path-provisioner
```

Describe stuck PVC:

```bash
kubectl describe pvc pvc-test
```

Common causes:

- Provisioner not installed/running
- Wrong `storageClassName`
- Node disk path permission issues
