---
name: ssh-connect
description: Instructions for connecting to Kubernetes cluster nodes via SSH using FQDNs and MAAS identity keys.
---

# SSH Connection to Cluster Nodes


This skill describes how to connect to the Kubernetes cluster nodes using their Fully Qualified Domain Names (FQDN).

## Configuration
- **User:** `ubuntu`
- **SSH Key Path:** `/home/ubuntu/shitcluster/maas/maas_id`
- **FQDN Pattern:** `<node>.mgmt.mansion.shitcluster.io` (e.g., `mcmp2.mgmt.mansion.shitcluster.io`)

## Connection Method

### Single Node
To connect to a specific node:
```bash
ssh -i /home/ubuntu/shitcluster/maas/maas_id ubuntu@<node>.mgmt.mansion.shitcluster.io
```

### Running Commands on Multiple Nodes
To run a command (e.g., `uptime`) across multiple nodes using a loop:
```bash
for host in mcmp2.mgmt.mansion.shitcluster.io mcmp3.mgmt.mansion.shitcluster.io; do
  echo -n "$host: "
  ssh -i /home/ubuntu/shitcluster/maas/maas_id -o StrictHostKeyChecking=no ubuntu@$host "uptime"
done
```

## Reference
The list of active nodes and their FQDNs can be found in `ansible/inventory.yml`.
