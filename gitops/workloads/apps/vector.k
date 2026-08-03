import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import file

_config = cfg.config
vector = _config.vector


vector_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = vector.namespace
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
    metadata.name = vector.namespace
  }

  [
    k8s.ConfigMap {
      metadata = {
        name = configmap_name
        namespace = vector.namespace
      }

      data = {
         file_name = file.read(file_path)
         for file_name, file_path in configmap
      }
  }
  for configmap_name, configmap in vector.configMapFiles]

  vector_app(
    vector.vector.helm | { release_name = "aggregator" }
    {
      role = "Aggregator"
      nodeSelector = _config.nodeSelector.worker
      customConfig = {
        data_dir = "/vector-data-dir"
        api = {
            enabled = True
            address = "127.0.0.1:8686"
            playground = False
        }
        sources = {
            datadog_agent = {
                address = "0.0.0.0:8282"
                $type = "datadog_agent"
            }
            fluent = {
                address = "0.0.0.0:24224"
                $type = "fluent"
            }
            internal_metrics = {
                $type = "internal_metrics"
            }
            logstash = {
                address = "0.0.0.0:5044"
                $type = "logstash"
            }
            splunk_hec = {
                address = "0.0.0.0:8080"
                $type = "splunk_hec"
            }
            statsd = {
                address = "0.0.0.0:8125"
                mode = "tcp"
                $type = "statsd"
            }
            syslog = {
                address = "0.0.0.0:9000"
                mode = "tcp"
                $type = "syslog"
            }
            vector = {
                address = "0.0.0.0:6000"
                $type = "vector"
                version = "2"
            }
        }
        transforms = {
            container_logs = {
                $type = "remap"
                inputs = [
                    "vector"
                ]
                source = r""".namespace = .kubernetes.pod_namespace
.pod_name = .kubernetes.pod_name
.container_name = .kubernetes.container_name
.hostname = .kubernetes.node_labels."kubernetes.io/hostname"
del(.file)
del(.kubernetes)
del(.source_type)
del(.stream)
    """
          }

          traceback_aggregate = {
              $type = "lua"
              inputs = [
                  "vector"
              ]
              version = "2"
              search_dirs = [
                  "."
                  "/etc/vector"
                  "/etc/verctor/parsers"
              ]
              hooks = {
                  process = "return require('parsers/parser')"
              }
          }
          alertmanager_payload = {
              $type = "remap"
              inputs = [
                  "traceback_aggregate"
              ]
              source = r"""# pick kubernetes object (namespaced .log.kubernetes preferred)
k8s = {}
if exists(.log.kubernetes) { k8s = .log.kubernetes }
if !exists(.log.kubernetes) && exists(.kubernetes) { k8s = .kubernetes }

# pick message (namespaced preferred)
msg = ""
if exists(.log.message) { msg = .log.message }
if !exists(.log.message) && exists(.message) { msg = .message }

# optional language
lang = null
if exists(.log.language) { lang = .log.language }
if !exists(.log.language) && exists(.language) { lang = .language }

# namespace fallback chain
ns = ""
if exists(k8s.namespace) { ns = k8s.namespace }
if !exists(k8s.namespace) && exists(k8s.pod_namespace) { ns = k8s.pod_namespace }

pod = ""
if exists(k8s.pod_name) { pod = k8s.pod_name }

ctr = ""
if exists(k8s.container_name) { ctr = k8s.container_name }

host = ""
if exists(k8s.node_labels) && is_object(k8s.node_labels) && exists(k8s.node_labels."kubernetes.io/hostname") {
  host = k8s.node_labels."kubernetes.io/hostname"
} else {
  if exists(k8s.node_name) { host = k8s.node_name }
}

# alertname (dynamic if language is present)
alertname = "TracebackDetected"
if lang != null && is_string(lang) && lang != "" {
  alertname = string!(lang) + "TracebackDetected"
}

alert = {
  "labels": {
    "type": "traceback",
    "alertname": alertname,
    "pod_name":  to_string(pod) ?? "",
    "namespace": to_string(ns) ?? "",
    "container_name": to_string(ctr) ?? "",
    "hostname": to_string(host) ?? "",
    "severity": "critical"
  },
  "annotations": {
    "summary": "Traceback detected",
    "description": to_string(msg) ?? ""
  },
  "startsAt": format_timestamp!(now(), format: "%+"),
}

. = [alert]
"""
            }

        }
        sinks = {
            to_loki = {
              $type = "loki"
              inputs = [ "container_logs" ]
              endpoint = "http://loki.observability:3100"
              encoding.codec = "text"
              labels = {
                namespace = '{{ "{{" }} namespace {{ "}}" }}'
                pod       = '{{ "{{" }} pod_name {{ "}}" }}'
                container = '{{ "{{" }} container_name {{ "}}" }}'
                node = '{{ "{{" }} hostname {{ "}}" }}'
              }
              remove_label_fields = True
            }
            to_alertmanager = {
                $type = "http"
                inputs = [
                    "alertmanager_payload"
                ]
                method = "post"
                uri = "http://alertmanager.monitoring.svc:9093/api/v2/alerts"
                headers = {
                    "Content-Type" = "application/json"
                }
                encoding.codec = "json"
                batch = {
                    max_events = 1
                    timeout_secs = 1
                }
            }
            prom_exporter = {
                $type = "prometheus_exporter"
                inputs = [
                    "internal_metrics"
                ]
                address = "0.0.0.0:9090"
            }
            stdout = {
                $type = "console"
                inputs = [
                  "alertmanager_payload"
                ]
                encoding = {
                    codec = "text"
                    #text.field = "body"
                }
            }
        }
      }
      extraVolumes = [{
        name = "vector-exceptions"
        configMap.name = "vector-exceptions"
      }]
      extraVolumeMounts = [{
        name = "vector-exceptions"
        mountPath = "/etc/vector/parsers"
        readOnly = True
      }]
    }
    sync = {}
  )


  vector_app(
    vector.vector.helm, {
      role = "Agent"
      tolerations = [
          {
              key = "node-role.kubernetes.io/control-plane"
              operator = "Exists"
              effect = "NoSchedule"
          }
          {
              key = "node.longhorn.io/storage"
              operator = "Exists"
              effect = "NoSchedule"
          }
      ]
      customConfig = {
        data_dir = "/vector-data-dir"
        api = {
            enabled = True
            address = "127.0.0.1:8686"
            playground = False
        }
        sources = {
            kubernetes_logs = {
                $type = "kubernetes_logs"
            }
            host_metrics = {
                filesystem = {
                    devices = {
                        excludes = [
                            "binfmt_misc"
                        ]
                    }
                    filesystems = {
                        excludes = [
                            "binfmt_misc"
                        ]
                    }
                    mountpoints = {
                        excludes = [
                            "*/proc/sys/fs/binfmt_misc"
                        ]
                    }
                }
                $type = "host_metrics"
            }
            internal_metrics = {
                $type = "internal_metrics"
            }
        }
        sinks = {
            prom_exporter = {
                $type = "prometheus_exporter"
                inputs = [
                    "host_metrics"
                    "internal_metrics"
                ]
                address = "0.0.0.0:9090"
            }
            logs_to_aggregator = {
                $type = "vector"
                inputs = [ "kubernetes_logs" ]
                address = "aggregator-vector:6000"
            }
            stdout = {
                $type = "console"
                inputs = [
                    "kubernetes_logs"
                ]
                encoding = {
                    codec = "json"
                }
            }
        }
      }
    }
    sync = {}
  )


]
