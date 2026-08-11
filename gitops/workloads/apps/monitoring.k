import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import file
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
mon_cfg = _config.monitoring

monitoring_app = lambda helm: any, values: any, sync: any -> argoproj.Application {
    #monitoring_app = lambda helm : any, values : any, sync : any -> any {
    argoproj.Application {
        metadata = {
            name = helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = mon_cfg.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = helm.chart_name
                repoURL = helm.repo
                targetRevision = helm.chart_version
                helm = {
                    values = yaml.encode(values)
                }
            }
            syncPolicy = {
                automated = {
                    selfHeal = True
                }
            } | sync
        }
    }
}

manifests = [
    k8s.Namespace {
        metadata.name = mon_cfg.namespace
    }
    monitoring_app(mon_cfg.kube_state_metrics.helm, values={
        nodeSelector = _config.nodeSelector.worker
        service.annotations = {
            "prometheus.io/port" = "8080"
        }
        resources.requests = {
            cpu = "100m"
            memory = "128Mi"
        }
        resources.limits = {
            cpu = "500m"
            memory = "256Mi"
        }
        image = {
            tag = "v2.10.0"
        }
    }, sync={})
    monitoring_app(mon_cfg.node_exporter.helm, values={
        service = {
            annotations = {
                "prometheus.io/port" = "9100"
            }
        }
    }, sync={})
    monitoring_app(mon_cfg.blackbox_exporter.helm, values={
        nodeSelector = _config.nodeSelector.worker
        service.annotations = {
            "prometheus.io/scrape" = "true"
            "prometheus.io/port" = "9115"
        }
    }, sync={})
    monitoring_app(mon_cfg.alertmanager.helm, values={
        nodeSelector = _config.nodeSelector.worker
        extraArgs = {
            "log.level" = "debug"
        }
        extraSecretMounts = [{
            name = "secret-files"
            mountPath = "/etc/secrets"
            subPath = ""
            secretName = mon_cfg.alertmanager.secret_name
            readOnly = True
        }]
        config = {
            route = {
                group_by = [
                    "alertname"
                    "severity"
                    "namespace"
                ]
                group_interval = "30s"
                group_wait = "10s"
                receiver = "default"
                repeat_interval = "1m"
                routes = [
                    {
                        receiver = "default-traceback"
                        matchers = [
                            'type="traceback"'
                        ]
                    }
                ]
            }
            receivers = [
                {
                    name = "default"
                    webhook_configs = [
                        {
                            url = "http://127.0.0.1:9094/print"
                            send_resolved = False
                        }
                    ]
                }
                {
                    name = "default-traceback"
                    telegram_configs = [
                        {
                            bot_token_file = "/etc/secrets/telegram_bot_token"
                            chat_id = mon_cfg.notifications.telegram.chat_id
                            message = r"""
🚨 *{{ .CommonLabels.alertname }}*  ({{ .CommonLabels.severity }})

*Where*
• ns: `{{ .CommonLabels.namespace }}`
• pod: `{{ .CommonLabels.pod_name }}/{{ .CommonLabels.container_name }}`
• node: `{{ .CommonLabels.hostname }}`

*What*
• {{ (index .Alerts 0).Annotations.summary }}

*Traceback*
```{{ (index .Alerts 0).Annotations.description }}```
"""
                            parse_mode = "Markdown"
                            send_resolved = False
                        }
                    ]
                }
            ]
            templates = [
                "/etc/alertmanager/*.tmpl"
            ]
        }
    }, sync={})
    monitoring_app(mon_cfg.vm_operator.helm, values={
        nodeSelector = _config.nodeSelector.worker
    }, sync={
        syncOptions = [
            "RespectIgnoreDifferences=true"
        ]
    }) | {
        spec.ignoreDifferences = [
            {
                group = ""
                kind = "Secret"
                name = "${mon_cfg.vm_operator.helm.release_name}-validation"
                namespace = mon_cfg.namespace
                jsonPointers = ["/data"]
            }
            {
                group = "admissionregistration.k8s.io"
                kind = "ValidatingWebhookConfiguration"
                name = "${mon_cfg.vm_operator.helm.release_name}-validation"
                namespace = mon_cfg.namespace
                jqPathExpressions = ['.webhooks[]?.clientConfig.caBundle']
            }
        ]
    }
    monitoring_app(mon_cfg.vm_single.helm, values={
        server = {
            nodeSelector = _config.nodeSelector.worker
            persistentVolume = {
                enabled = True
                storageClassName = _config.storageClass
            }
            extraArgs = {
                "opentelemetry.usePrometheusNaming" = "true"
            }
        }
    }, sync={})
    monitoring_app(mon_cfg.vm_agent.helm, values={
        nodeSelector = _config.nodeSelector.worker
        remoteWrite = [{
            url = "http://vm-single-victoria-metrics-single-server:8428/api/v1/write"
        }]
        extraScrapeConfigs = [
            {
                job_name = "litellm"
                metrics_path = "/metrics"
                scrape_interval = "30s"
                bearer_token = "ref+vault://kv/litellm#master_key"
                static_configs = [{
                    targets = ["litellm.ai.svc:4000"]
                }]
            }
            {
                job_name = "llamacpp"
                metrics_path = _config.external.llamacpp.metrics_path
                scrape_interval = _config.external.llamacpp.interval
                static_configs = [{
                    targets = ["${_config.external.llamacpp.host}:${_config.external.llamacpp.port}"]
                }]
            }
            {
                job_name = "longhorn"
                metrics_path = "/metrics"
                scrape_interval = "30s"
                static_configs = [{
                    targets = ["${_config.longhorn.metrics_service}.${_config.longhorn.namespace}:${_config.longhorn.metrics_port}"]
                }]
            }
        ]
    }, sync={})
    monitoring_app(mon_cfg.grafana.helm, values={
        nodeSelector = _config.nodeSelector.worker
        adminUser = "ref+vault://kv/grafana#adminUser"
        adminPassword = "ref+vault://kv/grafana#adminPassword"
        image.tag = mon_cfg.grafana.helm.app_version
        service = {
            type = "LoadBalancer"
            loadBalancerIP = "172.25.1.5"
        }
        persistence = {
            enabled = True
        }
        dashboardProviders = {
            "dashboardproviders.yaml" = {
                apiVersion = 1
                providers = [{
                    name = "default"
                    orgId = 1
                    folder = ""
                    type = "file"
                    disableDeletion = False
                    editable = True
                    options = {
                        path = "/var/lib/grafana/dashboards/default"
                    }
                }]
            }
        }
        dashboards = {
            default = {
                "hwmon-node-exporter" = {
                    gnetId = 24629
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "pi-hole-exporter" = {
                    gnetId = 10176
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "cert-manager" = {
                    gnetId = 11001
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "longhorn-dashboard" = {
                    gnetId = 22705
                    revision = 1
                    datasource = [{
                        name = "DS_PROMETHEUS"
                        value = "VictoriaMetrics"
                    }]
                }
                "litellm" = {
                    gnetId = 24965
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "node-exporter-full" = {
                    gnetId = 1860
                    revision = 45
                    datasource = "VictoriaMetrics"
                }
                "kubernetes-pods" = {
                    gnetId = 6417
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "kubernetes-pod-dashboard" = {
                    gnetId = 21298
                    revision = 1
                    datasource = "VictoriaMetrics"
                }
                "kubernetes-monitoring" = {
                    gnetId = 13077
                    revision = 3
                    datasource = "VictoriaMetrics"
                }
                "k8s-views-global" = {
                    gnetId = 15757
                    revision = 43
                    datasource = "VictoriaMetrics"
                }
                "k8s-views-namespaces" = {
                    gnetId = 15758
                    revision = 46
                    datasource = "VictoriaMetrics"
                }
                "k8s-views-nodes" = {
                    gnetId = 15759
                    revision = 40
                    datasource = "VictoriaMetrics"
                }
                "k8s-views-pods" = {
                    gnetId = 15760
                    revision = 39
                    datasource = "VictoriaMetrics"
                }
                "lact-gpu-metrics" = {
                    json = file.read("apps/grafana_data/lact-gpu-metrics.json")
                    datasource = "VictoriaMetrics"
                }
                "bird-bgp" = {
                    json = file.read("apps/grafana_data/bird-bgp.json")
                    datasource = "VictoriaMetrics"
                }
            }
        }
        datasources = {
            "datasources.yaml" = {
                apiVersion = 1
                datasources = [{
                    name = "VictoriaMetrics"
                    type = "prometheus"
                    uid = "vm"
                    access = "proxy"
                    url = "http://${_config.monitoring.vm_single.helm.release_name}-victoria-metrics-single-server.${_config.monitoring.namespace}.svc:8428"
                    isDefault = True
                    editable = True
                }]
            }
            "datasources-loki.yaml" = {
                apiVersion = 1
                datasources = [{
                    name = "loki"
                    type = "loki"
                    uid = "loki"
                    access = "proxy"
                    url = "http://${_config.observability.loki.helm.release_name}.${_config.observability.namespace}:3100"
                    editable = False
                }]
            }
            "datasources-tempo.yaml" = {
                apiVersion = 1
                datasources = [{
                    name = "tempo"
                    type = "tempo"
                    uid = "tempo"
                    #access = "proxy"
                    url = "http://${_config.observability.tempo.helm.release_name}.${_config.observability.namespace}:3200"
                    editable = True
                    jsonData = {
                        httpMethod = "GET"
                        serviceMap.datasourceUid = "vm"
                        tracesToLogsV2.datasourceUid = "loki"
                        tracesToMetrics.datasourceUid = "vm"
                        nodeGraph.enabled = True
                    }
                }]
            }
        }
    }, sync={})
    #streamingEnabled.search = False
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = "grafana-ingress"
            namespace = mon_cfg.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
            }
        }
        spec = {
            tls = [
                {
                    hosts = ["grafana." + _config.cert_manager.managed_domain]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = "grafana." + _config.cert_manager.managed_domain
                    http = {
                        paths = [
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = mon_cfg.grafana.helm.release_name
                                        port = {
                                            number = 80
                                        }
                                    }
                                }
                            }
                        ]
                    }
                }
            ]
        }
    }
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = "victoria-ingress"
            namespace = mon_cfg.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
            }
        }
        spec = {
            tls = [
                {
                    hosts = ["victoria." + _config.cert_manager.managed_domain]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = "victoria." + _config.cert_manager.managed_domain
                    http = {
                        paths = [
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = "${mon_cfg.vm_single.helm.release_name}-victoria-metrics-single-server"
                                        port = {
                                            number = 8428
                                        }
                                    }
                                }
                            }
                        ]
                    }
                }
            ]
        }
    }
    k8s.Secret {
        metadata = {
            name = mon_cfg.alertmanager.secret_name
            namespace = mon_cfg.namespace
        }
        stringData = {
            telegram_bot_token = mon_cfg.notifications.telegram.bot_token
            telegram_chat_id = mon_cfg.notifications.telegram.chat_id
        }
    }
    {
        "apiVersion" = "operator.victoriametrics.com/v1beta1"
        "kind" = "VMRule"
        "metadata" = {
            "name" = "vault-restart-alert"
            "namespace" = mon_cfg.namespace
        }
        "spec" = {
            "groups" = [{
                "name" = "vault-restart.rules"
                "rules" = [{
                    "alert" = "VaultPodRestarting"
                    "expr" = "increase(kube_pod_container_status_restarts_total{namespace=\"vault\"}[1h]) > 0"
                    "for" = "0m"
                    "labels" = {
                        "severity" = "critical"
                        "type" = "traceback"
                    }
                    "annotations" = {
                        "summary" = "Vault pod {{ $labels.exported_pod }} restarted"
                        "description" = "Pod {{ $labels.exported_pod }} (container: {{ $labels.exported_container }}) in namespace vault has restarted {{ $value }} time(s) in the last hour"
                    }
                }]
            }]
        }
    }
    # VMServiceScrape for kube-state-metrics with cluster label
    vm_service_scrape.VMServiceScrape {
        metadata = {
            name = "kube-state-metrics"
            namespace = mon_cfg.namespace
            labels = {
                "app.kubernetes.io/name" = "kube-state-metrics"
            }
        }
        spec = {
            selector = {
                matchLabels = {
                    "app.kubernetes.io/name" = "kube-state-metrics"
                }
            }
            endpoints = [{
                port = "http"
                interval = "15s"
                honorLabels = true
            }]
            relabelings = [{
                targetLabel = "cluster"
                replacement = "shitcluster"
            }]
        }
    }
]
