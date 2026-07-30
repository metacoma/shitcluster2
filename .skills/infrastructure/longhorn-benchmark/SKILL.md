---
name: longhorn-benchmark
trigger: Testing Longhorn performance and validating volume provisioning
description: Benchmark Longhorn write/read speed and validate volume lifecycle.
---

# Longhorn Benchmark & Validation Skill

Use when testing Longhorn storage performance, validating volume provisioning, or checking storage network behavior.

## Prerequisites

Before running benchmarks, ensure:
- Longhorn is deployed (`helm list -n longhorn-system`)
- All `longhorn-manager` pods are Running (2/2)
- `kubectl get nodes.longhorn.io -n longhorn-system` shows all nodes READY
- `kubectl get setting -n longhorn-system` shows all Settings APPLIED=true

## Workflow

### 1. Validate Longhorn State

```bash
# Check pods
kubectl get pods -n longhorn-system

# Check nodes and scheduling state
kubectl get nodes.longhorn.io -n longhorn-system -o wide

# Verify all settings applied
kubectl get setting -n longhorn-system | grep -v true

# Check storage classes
kubectl get sc | grep longhorn

# Check for any longhorn-manager in CrashLoopBackOff
kubectl get pods -n longhorn-system | grep CrashLoopBackOff
```

If a longhorn-manager pod is CrashLoopBackOff, check logs:
```bash
kubectl logs <pod-name> -n longhorn-system --tail=30
```
Common issue: race condition on Setting CRD during first install (multiple instance-managers updating settings concurrently). Wait 60s and retry — it self-recovers.

### 2. Create Test PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-bench-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f test-pvc.yaml
```

### 3. Create Test Pod with PVC

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-bench-pod
  namespace: default
spec:
  containers:
    - name: bench
      image: alpine:latest
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: bench-vol
          mountPath: /data
  volumes:
    - name: bench-vol
      persistentVolumeClaim:
        claimName: test-bench-pvc
  tolerations:
    - key: "node.longhorn.io/storage"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
```

```bash
kubectl apply -f test-bench-pod.yaml
```

### 4. Wait for PVC Bound and Pod Running

```bash
kubectl get pvc test-bench-pvc
kubectl get pod test-bench-pod -o wide
```

Note which node the pod is scheduled on.

### 5. Run Write Benchmark (dd with direct I/O)

```bash
for i in 1 2 3; do
  echo "=== RUN $i ==="
  kubectl exec test-bench-pod -c bench -- sh -c \
    "dd if=/dev/zero of=/data/testfile bs=1M count=1024 oflag=direct 2>&1"
  echo ""
done
```

### 6. Cleanup

```bash
kubectl delete pod test-bench-pod
kubectl delete pvc test-bench-pvc
```

## Interpreting Results

- **Good**: >200 MB/s for SSD nodes
- **Expected (current setup)**: ~27 MB/s — this is normal when:
  - Worker nodes have `allowScheduling=false`
  - Volume is provisioned on control-plane nodes via CSI plugin
  - Pod-scheduler places pod on worker, volume on control-plane
  - Data crosses node boundaries through the network
- **Low**: <50 MB/s on worker nodes with `allowScheduling=true` and SSD

## Pitfalls

1. **PVC stays Pending** — WaitForFirstConsumer needs a pod to trigger binding. Create the pod first.
2. **longhorn-manager CrashLoopBackOff** — race condition during first install. Wait 60s, the pod will restart and succeed.
3. **Worker nodes not scheduling volumes** — check `kubectl get nodes.longhorn.io` for `allowScheduling=false`. This is intentional in our config (worker nodes get no disks).
4. **Low benchmark speed** — check which node the volume was provisioned on (`kubectl get pvc -o wide`). If pod and volume are on different nodes, data crosses network.
5. **Pod not scheduling** — check tolerations match your node taints. Our cluster uses `node.longhorn.io/storage=true:NoSchedule` and `node-role.kubernetes.io/control-plane:NoSchedule`.
