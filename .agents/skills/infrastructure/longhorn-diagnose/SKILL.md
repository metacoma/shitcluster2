---
name: longhorn-diagnose
description: Comprehensive diagnostic workflow for Longhorn distributed storage in Kubernetes. Covers health checks, settings audit, disk/node/volume inspection, backup verification, performance analysis, and troubleshooting common failure modes. Use when investigating Longhorn issues, auditing storage health, or performing routine maintenance checks.
---

# Longhorn Diagnostics Skill

Systematic diagnostic workflow for Longhorn distributed block storage. Based on Longhorn v1.12.0 official documentation, community best practices, and real-world cluster audit experience.

## Architecture Overview

```
K8s Pod → CSI Driver → Longhorn Engine (instance-manager) → Replicas (on local disks)
                                                    ↕ (TCP replication)
                                          Replicas on other nodes
```

Key components in `longhorn-system` namespace:
- **longhorn-manager** (DaemonSet) — control plane: scheduling, attaching, backup, settings
- **longhorn-engine** (inside instance-manager pods) — I/O path for attached volumes
- **longhorn-instance-manager** (per node) — hosts engine + replica processes
- **longhorn-csi-plugin** (DaemonSet) — CSI node driver on every node
- **csi-provisioner/attacher/resizer/snapshotter** — CSI controller components
- **longhorn-ui** — web dashboard
- **engine-image** (DaemonSet) — preloads engine binaries on each node

## Diagnostic Workflow

### Phase 1: Quick Health Check

Get an immediate overview of Longhorn health in a single pass:

```bash
# 1. All Longhorn pods — look for non-Running or high restarts
kubectl get pods -n longhorn-system -o wide

# 2. All volumes — state + robustness at a glance
kubectl get volumes.longhorn.io -A -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,NODE:.spec.nodeID,SIZE:.spec.size,REPLICAS:.status.currentReplicaCount

# 3. All nodes — scheduling status
kubectl get nodes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,RO:.spec.allowScheduling,READY:status.conditions[?@.type=="Ready"].status

# 4. Engine images — should be "deployed"
kubectl get engineimages.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,STATE:.status.state

# 5. Backup target — should exist and be "active"
kubectl get backuptargets.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,URL:.spec.host,STATE:.status.state

# 6. Recurring jobs — snapshots/backups schedule
kubectl get recurringjobs.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,TASK:.spec.task,SCHEDULE:.spec.group,RETENTION:.spec.retention
```

**Red flags at this stage:**
- Any pod not in `Running` state
- Any volume with `robustness != healthy`
- Any node with `Ready: False`
- Missing `BackupTarget`
- No `RecurringJob` entries

---

### Phase 2: Settings Audit

Longhorn has ~100 settings. These are the critical ones to verify:

```bash
kubectl get settings.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,VALUE:.value --no-headers
```

#### Critical settings checklist

| Setting | Recommended | Why |
|---|---|---|
| `default-replica-count` | `2` | 3 is overkill for most; 1 has no redundancy |
| `default-data-locality` | `best-effort` | `disabled` forces all I/O over network |
| `storage-minimal-available-percentage` | `10` (dedicated disk) / `25` (root disk) | Prevents DiskPressure |
| `storage-over-provisioning-percentage` | `100` | Conservative; higher risks overcommit |
| `storage-reserved-percentage-for-default-disk` | `30` | Default; OK for dedicated disks |
| `replica-auto-balance` | `least-effort` | Prevents hot nodes without excessive rebuilds |
| `allow-volume-creation-with-degraded-availability` | `false` | Ensures all replicas are placed before volume is usable |
| `auto-salvage` | `true` | Auto-recover from single-replica failure |
| `auto-cleanup-system-generated-snapshot` | `true` | Prevents snapshot accumulation |
| `snapshot-data-integrity` | `enabled` | Detects silent data corruption |
| `snapshot-data-integrity-cronjob` | `0 2 * * *` | Nightly checksum verification |
| `guaranteed-instance-manager-cpu` | `12` (default) | Reserve CPU for storage plane |
| `fast-replica-rebuild-enabled` | `true` | Faster rebuild via diff sync |
| `freeze-filesystem-for-snapshot` | `true` | Consistent snapshots |
| `orphan-resource-auto-deletion` | `replica-data;instance` | Clean up stale resources |
| `node-drain-policy` | `block-for-eviction` | Don't auto-detach on drain |
| `disable-scheduling-on-cordoned-node` | `true` | Don't schedule on cordoned nodes |
| `replica-disk-soft-anti-affinity` | `true` | Spread replicas across disks |
| `priority-class` | `longhorn-critical` | Prevent eviction under pressure |
| `v1-data-engine` | `true` | V1 is stable; V2 needs NVMe + SPDK |
| `v2-data-engine` | `false` | Don't enable both engines simultaneously |

#### Settings to check per environment

```bash
# Check if using dedicated disk or root disk
kubectl get settings.longhorn.io default-data-path -n longhorn-system -o jsonpath='{.value}'

# Check backup concurrency
kubectl get settings.longhorn.io backup-concurrent-limit -n longhorn-system -o jsonpath='{.value}'

# Check snapshot limits
kubectl get settings.longhorn.io snapshot-max-count -n longhorn-system -o jsonpath='{.value}'
kubectl get settings.longhorn.io snapshot-count-warning-threshold -n longhorn-system -o jsonpath='{.value}'
```

---

### Phase 3: Node & Disk Deep Dive

#### Check all nodes with disk details

```bash
for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== Node: $node ==="
  kubectl get nodes.longhorn.io $node -n longhorn-system -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec = data.get('spec', {})
status = data.get('status', {})

print(f'  AllowScheduling: {spec.get(\"allowScheduling\", \"N/A\")}')
print(f'  Disks (spec): {len(spec.get(\"disks\", {}))}')
print(f'  DiskStatus entries: {len(status.get(\"diskStatus\", {}))}')

# Check conditions
for c in status.get('conditions', []):
    if c['status'] != 'True':
        print(f'  ⚠️  Condition {c[\"type\"]}: {c[\"status\"]} — {c.get(\"message\", \"\")}')

# Check disk details
for disk_name, disk in status.get('diskStatus', {}).items():
    max_st = disk.get('storageMaximum', 0)
    avail = disk.get('storageAvailable', 0)
    sched = disk.get('storageScheduled', 0)
    used_pct = (1 - avail/max_st) * 100 if max_st > 0 else 0
    print(f'  Disk: {disk.get(\"diskName\", \"?\")} ({disk.get(\"diskPath\", \"?\")})')
    print(f'    Type: {disk.get(\"diskType\", \"?\")}, FS: {disk.get(\"filesystemType\", \"?\")}')
    print(f'    Max: {max_st/(1024**3):.0f} GiB, Available: {avail/(1024**3):.0f} GiB, Scheduled: {sched/(1024**3):.1f} GiB')
    print(f'    Used: {used_pct:.1f}%')
    for dc in disk.get('conditions', []):
        if dc['status'] != 'True':
            print(f'    ⚠️  {dc[\"type\"]}: {dc[\"status\"]}')
"
  echo ""
done
```

#### Critical node checks

| Check | Command | Expected |
|---|---|---|
| Node has disks registered | `status.diskStatus` not empty | At least 1 disk |
| Disk filesystem type | `disk.filesystemType` | `ext4` (not ext2/ext3) |
| Disk conditions | All `Ready: True`, `Schedulable: True` | No warnings |
| Multipathd condition | `Multipathd: True` | `False` means multipathd conflict |
| Node Ready | `Ready: True` | No `NodeStatusUnknown` |
| Required packages | `RequiredPackages: True` | All packages installed |
| Kernel modules | `KernelModulesLoaded: True` | dm_crypt etc. loaded |

#### Common node issues

**No disks registered on worker nodes:**
- Symptom: `status.diskStatus = {}` but node has `node.longhorn.io/create-default-disk=config` label
- Cause: `createDefaultDiskLabeledNodes: true` only creates disks for nodes with label `node.longhorn.io/create-default-disk=true` (not `config`)
- Fix: Either add the correct label or manually add disks via Longhorn UI/API

**multipathd conflict:**
- Symptom: `Multipathd: False` with message about known issue
- Impact: Can cause PVC mount failures, attach/detach issues
- Reference: https://longhorn.io/kb/troubleshooting-volume-with-multipath

**Node NotReady:**
- Symptom: `Ready: False — Kubernetes node X not ready: NodeStatusUnknown`
- Impact: Replicas on this node are unreachable; volumes may degrade

---

### Phase 4: Volume & Replica Analysis

#### Volume health overview

```bash
kubectl get volumes.longhorn.io -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('items', []):
    name = v['metadata']['name']
    state = v['status'].get('state', '?')
    robust = v['status'].get('robustness', '?')
    node = v['spec'].get('nodeID', '?')
    size = int(v['spec'].get('size', 0))
    actual = v['status'].get('actualSize', 0)
    locality = v['spec'].get('dataLocality', 'N/A')
    encrypted = v['spec'].get('encrypted', False)
    from_backup = v['spec'].get('fromBackup', '')
    expansion = v['status'].get('expansionRequired', False)
    restore = v['status'].get('restoreRequired', False)

    status_icon = '✅' if robust == 'healthy' else '⚠️' if robust == 'degraded' else '🔴'
    print(f'{status_icon} {name}')
    print(f'    State: {state}, Robustness: {robust}, Node: {node}')
    print(f'    Size: {size/(1024**3):.1f} GiB, Actual: {actual/(1024**3):.2f} GiB')
    print(f'    Locality: {locality}, Encrypted: {encrypted}')
    if expansion: print(f'    ⚠️  Expansion required!')
    if restore: print(f'    ⚠️  Restore required!')
    print()
"
```

#### Replica distribution

```bash
# Check replica count per volume and their state
kubectl get replicas.longhorn.io -A -o json | python3 -c "
import json, sys
from collections import defaultdict
data = json.load(sys.stdin)
vols = defaultdict(list)
for r in data.get('items', []):
    vol = r['spec'].get('volumeName', 'unknown')
    host = r['spec'].get('hostname', 'unknown')
    state = r['status'].get('currentState', 'unknown')
    mode = r['spec'].get('mode', 'unknown')
    vols[vol].append((host, state, mode))

for vol, replicas in sorted(vols.items()):
    states = [r[1] for r in replicas]
    all_running = all(s == 'running' for s in states)
    icon = '✅' if all_running else '⚠️'
    print(f'{icon} {vol} ({len(replicas)} replicas):')
    for host, state, mode in replicas:
        print(f'    {host}: {state} (mode: {mode})')
"
```

#### Volume-to-PVC mapping

```bash
# Map PVCs to Longhorn volumes
kubectl get pvc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage | grep longhorn
```

#### Common volume issues

| Symptom | Likely Cause | Diagnostic |
|---|---|---|
| `robustness: degraded` | One replica failed/missing | Check replica states; look for rebuild in progress |
| `robustness: faulted` | All replicas lost | Check node status; may need restore from backup |
| `state: attaching` stuck | Node unreachable or iSCSI issue | Check node Ready; check instance-manager logs |
| `state: detached` unexpectedly | Node drain, eviction, or manual detach | Check events; check `auto-delete-pod-when-volume-detached-unexpectedly` |
| `expansionRequired: true` | PVC resized but volume not expanded | Manual expansion needed via Longhorn UI or API |
| `restoreRequired: true` | Volume created from backup, needs init | Check backup status |

---

### Phase 5: Backup & Disaster Recovery

#### Verify backup infrastructure

```bash
# 1. Backup target
kubectl get backuptargets.longhorn.io -n longhorn-system -o yaml

# 2. Backup volume (per-volume backup metadata)
kubectl get backupvolumes.longhorn.io -A -o custom-columns=NAME:.metadata.name,LASTBACKUP:.status.lastBackup,SIZE:.status.size,VOLUMENAME:.status.volumeName

# 3. Individual backups
kubectl get backups.longhorn.io -A -o custom-columns=NAME:.metadata.name,STATE:.status.state,SOURCE:.status.volumeName,SIZE:.status.size,CREATED:.status.backupCreatedAt

# 4. System backups (full Longhorn state)
kubectl get systembackups.longhorn.io -n longhorn-system -o yaml

# 5. Recurring jobs
kubectl get recurringjobs.longhorn.io -n longhorn-system -o yaml
```

#### Backup checklist

| Check | Command | Expected |
|---|---|---|
| BackupTarget exists | `kubectl get backuptargets` | At least 1, state=active |
| BackupTarget URL reachable | Check from Longhorn UI | Connection test passes |
| Recurring backup jobs | `kubectl get recurringjobs` | At least 1 backup job |
| Recent backups exist | `kubectl get backups` | Recent successful backups |
| System backup configured | `kubectl get systembackups` | Periodic system backups |
| Backup retention | Check recurring job retention | Reasonable (e.g., 7-30 days) |

---

### Phase 6: Performance & Resource Usage

#### Instance manager resource consumption

```bash
# CPU and memory per instance-manager pod
kubectl top pods -n longhorn-system | grep instance-manager

# Compare against guaranteed CPU
kubectl get settings.longhorn.io guaranteed-instance-manager-cpu -n longhorn-system -o jsonpath='{.value}'
```

#### Volume I/O metrics (via VictoriaMetrics/Prometheus)

```bash
# Using Grafana MCP tools:
# Volume write throughput
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_write_throughput' endTime=now queryType=instant

# Volume read throughput
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_read_throughput' endTime=now queryType=instant

# Volume write IOPS
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_write_iops' endTime=now queryType=instant

# Volume read IOPS
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_read_iops' endTime=now queryType=instant

# Volume write latency
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_write_latency' endTime=now queryType=instant

# Volume read latency
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_volume_read_latency' endTime=now queryType=instant

# Volume actual size vs capacity
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='(avg by (volume) (longhorn_volume_actual_size_bytes)) / (avg by (volume) (longhorn_volume_capacity_bytes)) * 100' endTime=now queryType=instant
```

#### Disk space usage

```bash
# Per-disk usage percentage
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='(longhorn_disk_usage_bytes/longhorn_disk_capacity_bytes)*100' endTime=now queryType=instant

# Per-node storage usage
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='(longhorn_node_storage_usage_bytes/longhorn_node_storage_capacity_bytes) * 100' endTime=now queryType=instant
```

#### Volume state counts

```bash
# Count volumes by state
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='count(longhorn_volume_state{state="attached"})' endTime=now queryType=instant

# Count degraded volumes
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='count(longhorn_volume_robustness{state="degraded"} == 1)' endTime=now queryType=instant

# Count faulted volumes
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='count(longhorn_volume_robustness{state="faulted"} == 1)' endTime=now queryType=instant
```

---

### Phase 7: Log Analysis

#### Manager logs (control plane)

```bash
# All manager pods (use kubetail if available)
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=500 | grep -iE "warn|error|fail|critical|degrad|unhealthy|rebuild|evict|timeout"

# Specific node's manager
kubectl logs -n longhorn-system -l app=longhorn-manager -l longhorn.io/node=mcmp2 --tail=200
```

#### Instance manager logs (I/O path)

```bash
# All instance managers
kubectl logs -n longhorn-system -l longhorn.io/component=instance-manager --tail=200 | grep -iE "error|fail|timeout|disconnect"

# Specific instance manager
kubectl logs -n longhorn-system instance-manager-xxxx --tail=200
```

#### CSI plugin logs

```bash
kubectl logs -n longhorn-system -l app=longhorn-csi-plugin --tail=200 | grep -iE "error|fail|timeout"
```

#### CSI controller logs

```bash
kubectl logs -n longhorn-system -l app=csi-provisioner --tail=200 | grep -iE "error|fail"
kubectl logs -n longhorn-system -l app=csi-attacher --tail=200 | grep -iE "error|fail"
```

#### Key log patterns to watch for

| Pattern | Meaning |
|---|---|
| `Failed to get ... Pod` (metrics.k8s.io) | Metrics Server unavailable; non-critical |
| `v1 Endpoints is deprecated` | K8s API deprecation warning; non-critical |
| `replica ... is faulted` | Replica lost; rebuild should start |
| `engine ... is down` | Engine process crashed; volume affected |
| `timeout waiting for replica` | Network issue or slow disk |
| `failed to rebuild replica` | Rebuild failed; check source replica |
| `snapshot ... failed` | Snapshot operation failed; check disk space |

---

### Phase 8: StorageClass & Provisioning

```bash
# Check all StorageClasses using Longhorn
kubectl get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,REPLICAS:.parameters.numberOfReplicas,LOCALITY:.parameters.dataLocality,ENCRYPT:.parameters.encrypted,DEFAULT:.storageclass.kubernetes.io/is-default-class

# Check Helm values for Longhorn
helm get values longhorn -n longhorn-system

# Check default settings from Helm
kubectl get settings.longhorn.io default-replica-count -n longhorn-system -o jsonpath='{.value}'
kubectl get settings.longhorn.io default-data-locality -n longhorn-system -o jsonpath='{.value}'
```

#### StorageClass best practices

| Parameter | Recommended | Notes |
|---|---|---|
| `numberOfReplicas` | `2` | Balance redundancy vs. disk usage |
| `dataLocality` | `best-effort` | Local replica when possible |
| `encrypted` | `true` (sensitive data) | Adds CPU overhead |
| `fromBackup` | (empty) | Only for DR restore |
| `staleReplicaTimeout` | `30` | Minutes before stale replica is removed |
| `unmapMarkSnapChainRemoved` | `enabled` | Better space reclamation |
| `fsType` | `ext4` | Not ext2/ext3 |
| `reclaimPolicy` | `Delete` | Clean up on PVC delete |
| `volumeBindingMode` | `WaitForFirstConsumer` | Schedule near consumer |

---

### Phase 9: Monitoring & Alerting

#### Verify metrics collection

```bash
# Check if longhorn-backend service exists
kubectl get svc -n longhorn-system | grep longhorn-backend

# Check if VMServiceScrape exists for Longhorn
kubectl get vmservicescrape -A | grep longhorn

# Check if metrics are actually being scraped
mcphub_grafana-mcp-query_prometheus datasourceUid=vm expr='longhorn_node_count_total' endTime=now queryType=instant
```

#### Recommended Grafana alerts

| Alert | Condition | Severity |
|---|---|---|
| Longhorn Volume Faulted | `count(longhorn_volume_robustness{state="faulted"} == 1) > 0` | Critical |
| Longhorn Volume Degraded | `count(longhorn_volume_robustness{state="degraded"} == 1) > 0` | Warning |
| Longhorn Disk Space Low | `(longhorn_disk_usage_bytes/longhorn_disk_capacity_bytes) > 0.85` | Warning |
| Longhorn Disk Space Critical | `(longhorn_disk_usage_bytes/longhorn_disk_capacity_bytes) > 0.95` | Critical |
| Longhorn Node Not Ready | `longhorn_node_status{condition="ready"} == 0` | Critical |
| Longhorn Replica Rebuild | `rate(longhorn_replica_rebuild_count[5m]) > 0` | Info |
| Longhorn Volume Write Latency High | `longhorn_volume_write_latency > 100` | Warning |

#### Grafana dashboard

The official Longhorn dashboard (UID: `cea6emq4o8zy8c`) provides 27 panels covering:
- Node count, schedulable, disabled, failed
- Volume count by state (attached, detached, degraded, faulty)
- Node/disk capacity tables
- Storage usage timeseries
- Volume I/O (throughput, IOPS, latency)
- Manager and instance-manager CPU/memory

---

### Phase 10: Common Failure Scenarios

#### Scenario 1: Volume stuck in "attaching"

```bash
# 1. Check volume details
kubectl get volume.longhorn.io <volume-name> -A -o yaml

# 2. Check target node status
kubectl get node <node-name>
kubectl get nodes.longhorn.io <node-name> -n longhorn-system -o yaml

# 3. Check instance-manager on target node
kubectl logs -n longhorn-system -l longhorn.io/node=<node-name>,longhorn.io/component=instance-manager --tail=200

# 4. Check CSI plugin on target node
kubectl logs -n longhorn-system -l app=longhorn-csi-plugin -l longhorn.io/node=<node-name> --tail=200

# 5. Check for multipathd conflict
systemctl status multipathd  # on the node
```

#### Scenario 2: Replica rebuild failing

```bash
# 1. Check replica states
kubectl get replicas.longhorn.io -A | grep <volume-name>

# 2. Check source replica health
kubectl logs -n longhorn-system -l longhorn.io/component=instance-manager --tail=500 | grep -i "rebuild\|replica.*fail"

# 3. Check disk space on target node
kubectl get nodes.longhorn.io <target-node> -n longhorn-system -o json | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'{k}: avail={v[\"storageAvailable\"]/(1024**3):.0f}GiB') for k,v in d['status'].get('diskStatus',{}).items()]"

# 4. Check network connectivity between nodes
# (from a pod on source node to target node IP on port 10000-10035)
```

#### Scenario 3: Disk full / DiskPressure

```bash
# 1. Check disk usage
kubectl get nodes.longhorn.io -n longhorn-system -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('items', []):
    for disk_name, disk in n.get('status', {}).get('diskStatus', {}).items():
        max_st = disk.get('storageMaximum', 0)
        avail = disk.get('storageAvailable', 0)
        if max_st > 0 and (1 - avail/max_st) > 0.8:
            print(f'⚠️  {n[\"metadata\"][\"name\"]}/{disk.get(\"diskName\", \"?\")}: {(1-avail/max_st)*100:.1f}% used')
"

# 2. Check for orphaned replica data
kubectl get settings.longhorn.io orphan-resource-auto-deletion -n longhorn-system -o jsonpath='{.value}'

# 3. Check snapshot count per volume
kubectl get volumes.longhorn.io -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('items', []):
    snap_count = len(v.get('status', {}).get('snapshot', {}) or {})
    if snap_count > 50:
        print(f'⚠️  {v[\"metadata\"][\"name\"]}: {snap_count} snapshots')
"
```

#### Scenario 4: Node goes down

```bash
# 1. Check which volumes were on the node
kubectl get volumes.longhorn.io -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('items', []):
    if v['spec'].get('nodeID') == '<failed-node>':
        print(f'{v[\"metadata\"][\"name\"]}: state={v[\"status\"].get(\"state\")}, robustness={v[\"status\"].get(\"robustness\")}')
"

# 2. Check if auto-salvage is enabled
kubectl get settings.longhorn.io auto-salvage -n longhorn-system -o jsonpath='{.value}'

# 3. Check node-down-pod-deletion-policy
kubectl get settings.longhorn.io node-down-pod-deletion-policy -n longhorn-system -o jsonpath='{.value}'

# 4. Wait for rebuild (check replica states)
kubectl get replicas.longhorn.io -A | grep <volume-name>
```

---

## Quick Reference: Essential Commands

```bash
# One-liner health check
echo "=== Pods ===" && kubectl get pods -n longhorn-system --no-headers | grep -v Running && echo "OK" || echo "ISSUES"
echo "=== Volumes ===" && kubectl get volumes.longhorn.io -A --no-headers | grep -v healthy && echo "OK" || echo "ISSUES"
echo "=== Nodes ===" && kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.allowScheduling}{\"\n\"}{end}'
echo "=== Backups ===" && kubectl get backuptargets.longhorn.io -n longhorn-system --no-headers
echo "=== Recurring ===" && kubectl get recurringjobs.longhorn.io -n longhorn-system --no-headers

# Full diagnostic dump (save to file)
kubectl get settings.longhorn.io -n longhorn-system -o yaml > longhorn-settings.yaml
kubectl get volumes.longhorn.io -A -o yaml > longhorn-volumes.yaml
kubectl get nodes.longhorn.io -n longhorn-system -o yaml > longhorn-nodes.yaml
kubectl get engineimages.longhorn.io -n longhorn-system -o yaml > longhorn-engineimages.yaml
kubectl get backuptargets.longhorn.io -n longhorn-system -o yaml > longhorn-backuptargets.yaml
kubectl get recurringjobs.longhorn.io -n longhorn-system -o yaml > longhorn-recurringjobs.yaml
kubectl get replicas.longhorn.io -A -o yaml > longhorn-replicas.yaml
kubectl get pods -n longhorn-system -o yaml > longhorn-pods.yaml
kubectl get events -n longhorn-system --sort-by='.lastTimestamp' > longhorn-events.txt
```

## Version & Upgrade Notes

```bash
# Current version
kubectl get settings.longhorn.io current-longhorn-version -n longhorn-system -o jsonpath='{.value}'

# Latest available version
kubectl get settings.longhorn.io latest-longhorn-version -n longhorn-system -o jsonpath='{.value}'

# Stable versions
kubectl get settings.longhorn.io stable-longhorn-versions -n longhorn-system -o jsonpath='{.value}'

# Helm release info
helm list -n longhorn-system
helm get values longhorn -n longhorn-system
```

**Before upgrading:**
1. Export all settings: `kubectl get settings.longhorn.io -n longhorn-system -o yaml`
2. Create a system backup
3. Verify all volumes are healthy
4. Check release notes for breaking changes
5. Some upgrades reset custom settings — verify after upgrade

## Known Longhorn Gotchas

| Issue | Description | Mitigation |
|---|---|---|
| **Bulk PVC creation race** | Scheduler places multiple replicas on same disk before space accounting catches up | Set `storage-over-provisioning-percentage` to 100%; stagger PVC creation |
| **Volume attachment storm** | After node reboot, all volumes reattach simultaneously, saturating network | Increase `mkfs-ext4-parameters` timeout; set `concurrent-volume-backup-restore-per-node-limit` |
| **Network partition / split-brain** | Divergent replicas after network split | Use dedicated storage network if possible |
| **Snapshot accumulation** | System snapshots from rebuilds/attach cycles consume 2-3x volume data | Enable `auto-cleanup-system-generated-snapshot`; set recurring snapshot retention |
| **Upgrades reset settings** | Some Longhorn upgrades reset custom settings to defaults | Export settings before upgrade; verify after |
| **HDD latency** | Spinning disks cause volume instability under concurrent I/O | Use SSD/NVMe; latency matters more than IOPS |
| **Both V1+V2 engines** | Each node runs separate instance-managers, doubling CPU overhead | Enable only one data engine per cluster |
