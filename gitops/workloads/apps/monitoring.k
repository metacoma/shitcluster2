import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
monitoring = _config.monitoring

monitoring_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
#monitoring_app = lambda helm : any, values : any, sync : any -> any {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = monitoring.namespace
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
    metadata.name = monitoring.namespace
  }
  monitoring_app(
    monitoring.kube_state_metrics.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      resources.requests = {
        cpu = "10m"
        memory = "32Mi"
      }
      resources.limits = {
        cpu = "10m"
        memory = "64Mi"
      }
    }
    sync = {}
  )

  monitoring_app(
    monitoring.node_exporter.helm, values = {
      service = {
        annotations = {
          "prometheus.io/port" = "9100"
        }
      }
    }, sync = {}

  )
  monitoring_app(
    monitoring.blackbox_exporter.helm, values = {
      nodeSelector = _config.nodeSelector.worker
    },
    sync = {}
  )

  monitoring_app(
    monitoring.alertmanager.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      extraArgs = {
        "log.level" = "debug"
      }
      extraSecretMounts = [{
        name = "secret-files"
        mountPath = "/etc/secrets"
        subPath = ""
        secretName = monitoring.alertmanager.secret_name
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
                      chat_id = monitoring.notifications.telegram.chat_id
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
    },
    sync = {}
  )

  monitoring_app(
    monitoring.vm_operator.helm, values = {
      nodeSelector = _config.nodeSelector.worker
    }
    sync = {
      syncOptions = [
        "RespectIgnoreDifferences=true"
      ]
    }
  ) | {
    spec.ignoreDifferences = [
      {
        group = ""
        kind = "Secret"
        name = "${monitoring.vm_operator.release_name}-validation"
        namespace = monitoring.namespace
        jsonPointers = ["/data"]
      }
      {
        group = "admissionregistration.k8s.io"
        kind = "ValidatingWebhookConfiguration"
        name = "${monitoring.vm_operator.release_name}-validation"
        namespace = monitoring.namespace
        jqPathExpressions = ['.webhooks[]?.clientConfig.caBundle']
      }

    ]
  }

  monitoring_app(
    monitoring.vm_agent.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      remoteWrite = [{
        url = "http://vm-single-victoria-metrics-single-server.monitoring:8428/api/v1/write"
      }]
    }, sync = {}
  )
  [
  vm_service_scrape.VMServiceScrape {
    metadata = {
      name = "${service_name}-exporter"
      namespace = _config.monitoring.namespace
    }
    spec = {
      selector.matchLabels = {
        "app.kubernetes.io/name" = service_name
      }
      namespaceSelector.matchNames = [_config.monitoring.namespace]
      endpoints = [{
        port = "metrics"
        interval = "30s"
      }]

    }
  }
  for service_name in ["prometheus-node-exporter", "kube-state-metrics", "prometheus-blackbox-exporter" ]
  ]

  monitoring_app(
    monitoring.grafana.helm, values = {
      nodeSelector = _config.nodeSelector.worker

      adminUser = "ref+vault://kv/grafana#adminUser"
      adminPassword = "ref+vault://kv/grafana#adminPassword"
      image.tag = monitoring.grafana.helm.app_version
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
              #streamingEnabled.search = False
            }
          }]
        }
      }
    },
    sync = {}
  )

  {
    apiVersion = "cert-manager.io/v1"
    kind = "Certificate"
    metadata = {
      name = "grafana-tls"
      namespace = monitoring.namespace
    }
    spec = {
      secretName = "grafana-tls"
      issuerRef = {
        name = _config.cert_manager.issuer_name
        kind = "ClusterIssuer"
      }
      dnsNames = ["grafana." + _config.cert_manager.managed_domain]
    }
  }

  {
    apiVersion = "networking.k8s.io/v1"
    kind = "Ingress"
    metadata = {
      name = "grafana-ingress"
      namespace = monitoring.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["grafana." + _config.cert_manager.managed_domain]
          secretName = "grafana-tls"
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
                    name = monitoring.grafana.helm.release_name
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

  k8s.Secret {
    metadata = {
      name = monitoring.alertmanager.secret_name
      namespace = monitoring.namespace
    }
    stringData = {
      telegram_bot_token = monitoring.notifications.telegram.bot_token
      telegram_chat_id = monitoring.notifications.telegram.chat_id
    }
  }

]
