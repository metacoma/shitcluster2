---
name: add-monitoring
description: Add monitoring for a new service in the cluster. This includes researching metrics, configuring metric collection via VMServiceScrape (VictoriaMetrics), and adding a corresponding Grafana dashboard.
---

# Add Monitoring Skill

This skill provides a standardized workflow for adding observability to a service deployed in the shitcluster. The stack uses **VictoriaMetrics** (via VMServiceScrape) for metric collection and **Grafana** for visualization.

## Workflow Overview

The process consists of four main phases: Research $\rightarrow$ Metric Collection $\rightarrow$ Visualization $\rightarrow$ Deployment.

## 1. Research & Discovery

Before implementing, you must identify *what* to monitor and *how* the service exposes its data.

### Finding Metrics and Dashboards
Use search tools (e.g., `ddgs`) to find Prometheus-compatible metrics and dashboards. Since VictoriaMetrics is Prometheus-compatible, always look for "Prometheus" integrations.

**Recommended Search Queries:**
- `"<service-name> prometheus metrics guide"`
- `"<service-name> grafana dashboard id"`
- `"<service-name> monitoring kubernetes prometheus"`

### Identifying the Metrics Endpoint
Once you know the service supports Prometheus metrics, verify the actual endpoint in the cluster:
1. **Find the Service/Pod**: `kubectl get svc -n <namespace>` or `kubectl get pods -n <namespace> --show-labels`.
2. **Check Ports**: Look for ports named `metrics`, `http-metrics`, or ports commonly used (e.g., 9090, 9100, 9402).
3. **Verify the Path**: If possible, check if `/metrics` returns data:
   `kubectl exec -it <pod> -n <namespace> -- curl localhost:<port>/metrics`

## 2. Implementing Metric Collection (VMServiceScrape)

In this cluster, we use `VMServiceScrape` resources from the VictoriaMetrics Operator to tell the VM Agent which targets to scrape.

**File**: `gitops/workloads/apps/monitoring.k`

Add a `vm_service_scrape.VMServiceScrape` resource with the following logic:
- **Metadata Name**: `<service>-metrics`.
- **Namespace**: Use `_config.monitoring.namespace` (usually `monitoring`).
- **Selector**: Match labels that uniquely identify the service pods (e.g., `app.kubernetes.io/name`).
- **Namespace Selector**: Specify the namespace where the target service is running.
- **Endpoints**: Define the port name (must match the Pod's container port name) and scrape interval.

**Example:**
```kcl
vm_service_scrape.VMServiceScrape {
  metadata = {
    name = "my-app-metrics"
    namespace = _config.monitoring.namespace
  }
  spec = {
    selector.matchLabels = { "app.kubernetes.io/name" = "my-app" }
    namespaceSelector.matchNames = ["my-app-ns"]
    endpoints = [{
      port = "http-metrics"
      interval = "30s"
    }]
  }
}
```

## 3. Implementing Visualization (Grafana Dashboard)

Add the discovered dashboard to the Grafana Helm values in KCL.

**File**: `gitops/workloads/apps/monitoring.k` $\rightarrow$ `monitoring_app(...)` call for Grafana.

Find the `dashboards.default` dictionary and add an entry:
- **Key**: A unique name for the dashboard (e.g., `"my-app-dashboard"`).
- **gnetId**: The ID from grafana.com/grafana/dashboards.
- **revision**: Usually `1`, unless a specific version is required.
- **datasource**: Must be set to `"VictoriaMetrics"`.

**Example:**
```kcl
dashboards = {
  default = {
    "my-app-dashboard" = {
      gnetId = 12345
      revision = 1
      datasource = "VictoriaMetrics"
    }
  }
}
```

## 4. Validation & Deployment

1. **Validate KCL**: Run the local validation container to ensure no syntax errors:
   `docker run --rm -v $(pwd)/gitops/workloads:/app -w /app ghcr.io/metacoma/kcl-vals:latest kcl run .`
2. **Commit & Push**: 
   - `git add gitops/workloads/apps/monitoring.k`
   - `git commit -m "feat: add monitoring for <service>"`
   - `git push origin master`
3. **Verify Sync**: Monitor ArgoCD to ensure the `workloads` application reaches **Synced** and **Healthy** state.
4. **Final Check**: Open Grafana and verify that the new dashboard is populated with data from VictoriaMetrics.
