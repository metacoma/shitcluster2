---
name: management-pod
description: Create a Kubernetes Pod with direct access to the host's management network (br-management) using Multus CNI for diagnostics and connectivity tests.
---

# Create Pod with Management Network

This skill describes how to create a Kubernetes Pod that has direct access to the host's management network (`br-management`) using Multus CNI and a `NetworkAttachmentDefinition`. This is useful for network diagnostics, testing connectivity to host services, or bypassing the standard K8s SDN.

## Prerequisites
- Multus CNI must be installed in the cluster.
- The node where the pod is scheduled must have the `br-management` bridge configured (typical for this cluster).

## Implementation Steps

### 1. Create a NetworkAttachmentDefinition (NAD)
The NAD tells Multus how to configure the secondary interface. It should be created in the same namespace as the Pod.

**Example Manifest (`management-nad.yaml`):**
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: management-net
  namespace: <your-namespace>
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "management-net",
      "type": "bridge",
      "bridge": "br-management",
      "ipam": {
        "type": "static",
        "addresses": [
          {
            "address": "<desired-ip>/16",
            "gateway": "172.24.0.1"
          }
        ]
      }
    }
```
Apply it: `kubectl apply -f management-nad.yaml`

### 2. Create the Pod
The Pod needs an annotation to trigger Multus and typically requires privileged mode if you intend to perform network manipulation inside the container.

**Example Manifest (`management-pod.yaml`):**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgmt-diag-pod
  namespace: <your-namespace>
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name": "management-net", "interface": "eth1"}]'
spec:
  containers:
  - name: alpine
    image: alpine
    command: ["/bin/sh", "-c", "sleep infinity"]
    securityContext:
      privileged: true
      capabilities:
        add: ["NET_ADMIN"]
  restartPolicy: Always
```
Apply it: `kubectl apply -f management-pod.yaml`

## Verification

### Check Interface
Verify that the secondary interface (`eth1`) is up and has the assigned IP:
```bash
kubectl exec -n <your-namespace> mgmt-diag-pod -- ip addr show eth1
```

### Test Connectivity
Ping a host on the management network (e.g., the node itself at `172.24.0.x`):
```bash
kubectl exec -n <your-namespace> mgmt-diag-pod -- ping -c 5 172.24.0.2
```

### Capture Traffic on Host
To verify that traffic is actually leaving the pod and hitting the bridge, run `tcpdump` on the host node:
```bash
sudo tcpdump -i br-management icmp -n
```

## Cleanup
```bash
kubectl delete pod mgmt-diag-pod -n <your-namespace>
kubectl delete net-attach-def management-net -n <your-namespace>
```
