---
name: dns-update-from-pod
description: Deploy a diagnostic pod with access to the management network to perform dynamic DNS updates on a BIND server using TSIG authentication.
---

# Update DNS Records from a Kubernetes Pod

This skill describes how to deploy a diagnostic pod with access to the management network to perform dynamic DNS updates on a BIND server using TSIG authentication.

## Prerequisites
- Multus CNI installed in the cluster.
- A BIND server configured to allow updates via TSIG for the target zone.
- Access to the TSIG key (e.g., stored in Vault or SOPS).

## Implementation Steps

### 1. Create a NetworkAttachmentDefinition (NAD)
The pod needs an IP address within the management network range to be recognized by the BIND server's ACLs/Views.

**Example Manifest (`dns-nad.yaml`):**
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: mgmt-dns-net
  namespace: <your-namespace>
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "mgmt-dns-net",
      "type": "bridge",
      "bridge": "br-management",
      "ipam": {
        "type": "static",
        "addresses": [
          {
            "address": "<ASSIGNED_MGMT_IP>/16",
            "gateway": "172.24.0.1"
          }
        ]
      }
    }
```

### 2. Deploy the DNS Update Pod
Use an image that contains `bind9-host` or `dnsutils`. The pod requires privileged access if network manipulation is needed, though for simple `nsupdate`, standard permissions may suffice depending on the environment.

**Example Manifest (`dns-pod.yaml`):**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-updater
  namespace: <your-namespace>
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name": "mgmt-dns-net", "interface": "eth1"}]'
spec:
  containers:
  - name: ubuntu
    image: ubuntu:latest
    command: ["/bin/sh", "-c", "apt-get update && apt-get install -y dnsutils && sleep infinity"]
    securityContext:
      privileged: true
      capabilities:
        add: ["NET_ADMIN"]
  restartPolicy: Always
```

### 3. Perform the DNS Update
To perform the update, you need the TSIG key name and its secret value.

#### Option A: Using a Key File (Recommended for stability)
Create a temporary key file inside the pod:
```bash
kubectl exec -n <namespace> dns-updater -- sh -c 'cat <<EOF > /tmp/dns.key
key "<KEY_NAME>" {
    algorithm hmac-sha256;
    secret "<SECRET_VALUE>";
};
EOF'
```

Then run `nsupdate`:
```bash
kubectl exec -n <namespace> dns-updater -- sh -c 'echo "server <BIND_SERVER_IP>
zone <ZONE_NAME>
update add <RECORD_NAME> 3600 A <IP_ADDRESS>
send" | nsupdate -k /tmp/dns.key'
```

#### Option B: Using the `-y` flag
```bash
kubectl exec -n <namespace> dns-updater -- sh -c 'echo "server <BIND_SERVER_IP>
zone <ZONE_NAME>
update add <RECORD_NAME> 3600 A <IP_ADDRESS>
send" | nsupdate -y <KEY_NAME>:<SECRET_VALUE>'
```

## Verification
Verify the change using `dig`:
```bash
kubectl exec -n <namespace> dns-updater -- dig @<BIND_SERVER_IP> <RECORD_NAME>
```

## Cleanup
```bash
kubectl delete pod dns-updater -n <your-namespace>
kubectl delete net-attach-def mgmt-dns-net -n <your-namespace>
```
