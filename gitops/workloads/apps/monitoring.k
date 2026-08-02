import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
mon_cfg = _config.monitoring

monitoring_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
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
  monitoring_app(
    mon_cfg.kube_state_metrics.helm, values = {
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
    mon_cfg.node_exporter.helm, values = {
      service = {
        annotations = {
          "prometheus.io/port" = "9100"
        }
      }
    }, sync = {}

  )
  monitoring_app(
    mon_cfg.blackbox_exporter.helm, values = {
      nodeSelector = _config.nodeSelector.worker
    },
    sync = {}
  )

  monitoring_app(
    mon_cfg.alertmanager.helm, values = {
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
    },
    sync = {}
  )

  monitoring_app(
    mon_cfg.vm_operator.helm, values = {
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

  monitoring_app(
    mon_cfg.vm_single.helm, values = {
      server = {
        nodeSelector = _config.nodeSelector.worker
        persistentVolume = {
          enabled = True
          storageClassName = _config.storageClass
        }
      }
    }, sync = {}
  )

  monitoring_app(
    mon_cfg.vm_agent.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      remoteWrite = [{
        url = "http://vm-single-victoria-metrics-single-server:8428/api/v1/write"
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
    mon_cfg.grafana.helm, values = {
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

  # Shared Wildcard Certificate (Reflected from cert-manager namespace)
  k8s.Secret {
    metadata = {
      name = "mansion-net-tls"
      namespace = mon_cfg.namespace
      annotations = {
        "reflector.v1.k8s.emberstack.com/reflects" = "cert-manager/mansion-net-tls"
      }
    }
  }

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

]
