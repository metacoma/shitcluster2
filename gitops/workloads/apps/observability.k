import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml


_config = cfg.config
observability = _config.observability

observability_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = observability.namespace
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
    metadata.name = observability.namespace
  }
  observability_app(
    observability.loki.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      gateway.enabled = False
      lokiCanary.enabled = False
      test.enabled = False
      resultsCache.nodeSelector = _config.nodeSelector.worker
      chunksCache.nodeSelector = _config.nodeSelector.worker
      deploymentMode = "SingleBinary"
      loki = {
        auth_enabled = False
        commonConfig.replication_factor = 1
        storage.type = "filesystem"
        schemaConfig.configs = [{
          from ="2025-01-01"
          store = "tsdb"
          object_store = "filesystem"
          schema = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]

      }
      singleBinary = {
        nodeSelector = _config.nodeSelector.worker
        replicas = 1
        persistence = {
          enabled = True
          size = "20Gi"
          storageClass = _config.storageClass
          accessModes = [ "ReadWriteOnce" ]
        }
      }
      read.replicas = 0
      write.replicas = 0
      backend.replicas = 0
    }
    sync = {}
  )

  observability_app(
    observability.tempo.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      tempo = {
        structuredConfig = {
          stream_over_http_enabled = True
        }
      }
      persistence = {
        enalbed = True
        size = "10Gi"
        storageClass = _config.storageClass
        mountPath = "/var/tempo"
      }
    }
    sync = {}
  )

  observability_app(
    observability.otlp.helm, values = {
      nodeSelector = _config.nodeSelector.worker
      mode = "deployment"
      image = {
        repository = "otel/opentelemetry-collector-contrib"
        digest = ""
      }
      config = {
        receivers = {
          otlp.protocols = {
              grpc.endpoint = "0.0.0.0:4317"
              http = {
                endpoint = "0.0.0.0:4318"
                cors.allowed_origins = [ "http://*", "https://*" ]
              }
          }
        }
        exporters = {
          #debug.verbosity = "detailed"
          "otlp/tempo" = {
            endpoint = "${observability.tempo.helm.release_name}:4317"
            tls.insecure = True
          }
          "otlphttp/victoriametrics" = {
            endpoint = "http://${_config.monitoring.vm_single.helm.release_name}-victoria-metrics-single-server.${_config.monitoring.namespace}.svc:8428/opentelemetry"
            tls.insecure = True
          }
          # otlphttp appends /v1/logs automatically for logs pipeline
          otlphttp.endpoint = "http://${observability.loki.helm.release_name}:3100/otlp"

        }

        service = {
          #telemetry.logs.level = "debug"
          pipelines = {
            logs = {
              receivers = ["otlp"]
              processors = ["memory_limiter", "batch"]
              exporters = ["otlphttp"]
            }
            traces = {
              receivers = ["otlp"]
              processors = ["memory_limiter", "batch"]
              exporters = ["otlp/tempo"]
            }
            metrics = {
              receivers = ["otlp"]
              processors = ["memory_limiter", "batch"]
              exporters = ["otlphttp/victoriametrics"]
            }
          }
        }
      }
      #ports.metrics.enabled = True
      #serviceMonitor.enabled = True
      #podMonitor.enabled = True
    }
    sync = {}
  )

  {
    apiVersion = "networking.k8s.io/v1"
    kind = "Ingress"
    metadata = {
      name = "otlp-ingress"
      namespace = observability.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = [observability.otlp.ingress_host]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = observability.otlp.ingress_host
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "${observability.otlp.helm.release_name}-opentelemetry-collector"
                    port = {
                      number = 4318
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
]
