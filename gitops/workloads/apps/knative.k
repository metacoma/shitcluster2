import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import knative_operator.v1beta1 as kn


_config = cfg.config
knative = _config.knative

operator = knative.operator
eventing = knative.eventing
serving = knative.serving
istio = _config.istio

_observability = _config.observability

manifests = [

  k8s.Namespace {
    metadata.name = operator.namespace
  }

  k8s.Namespace {
    metadata = {
      name = serving.namespace
      labels = {
        "istio-injection" = "enabled"
      }
    }
  }

  k8s.Namespace {
    metadata.name = eventing.namespace
  }


  argoproj.Application {
    metadata = {
        name = knative.operator.helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = operator.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = operator.helm.chart
            repoURL = operator.helm.repo
            targetRevision = operator.helm.version
            helm = {
                values = yaml.encode({
                  knative_operator = {
                    knative_operator.affinity.nodeAffinity = _config.nodeAffinity
                    operator_webhook.affinity.nodeAffinity = _config.nodeAffinity
                  }
                })
                releaseName = knative.operator.helm.release_name
            }
        }
        syncPolicy = {
            automated = {
                selfHeal = True
            }
        }
    }
  }
  kn.KnativeServing {
      metadata.name = "knative-serving"
      metadata.namespace = _config.knative.serving.namespace
      metadata.annotations = {
          "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true"
      }
      spec.version = _config.knative.serving.version
      spec.config = {
          domain = {
            "${knative.domain}" = ""
          }
          tracing = {
              backend = "zipkin"
              "zipkin-endpoint" = "http://${_observability.tempo.helm.release_name}.${_observability.namespace}:9411/api/v2/spans"
              "sample-rate" = "1"
              debug = "true"
          }
          observability = {
              "metrics-protocol" = "http/protobuf"
              "metrics-endpoint" = "http://${_observability.otlp.helm.release_name}-opentelemtry-collector.${_config.observability.namespace}:4318"
              "tracing-protocol" = "http/protobuf"
              "tracing-endpoint" = "http://${_observability.tempo.helm.release_name}.${_observability.namespace}:4318/v1/traces"
              "tracing-sampling-rate" = "1"
          }
          features = {
            "kubernetes.podspec-nodeselector": "enabled"
            "kubernetes.podspec-volumes-emptydir": "enabled"
            "kubernetes.podspec-persistent-volume-claim": "enabled"
            "kubernetes.podspec-affinity": "enabled"
            "kubernetes.podspec-hostaliases": "enabled"
            "kubernetes.podspec-tolerations": "enabled"
            "kubernetes.podspec-runtimeclassname": "enabled"
            "kubernetes.podspec-securitycontext": "enabled"
            "kubernetes.containerspec-addcapabilities": "enabled"
            "kubernetes.podspec-init-containers": "enabled"
            "kubernetes.podspec-hostnetwork": "enabled"
          }
          #deployment = {
          #    "registries-skipping-tag-resolving" = "zot-int.zot.svc.cluster.local:5000,zot-int.zot:5000,127.0.0.1:30001"
          #}
          istio = {
            "external-gateways" = yaml.encode([{
              name = "knative-ingress-gateway"
              namespace = serving.namespace
              service = "istio-ingressgateway.${istio.namespace}.svc"
            }])
            "local-gateways" = yaml.encode([{
              name = "knative-local-gateway"
              namespace = serving.namespace
              service = "knative-local-gateway.${istio.namespace}.svc.${_config.k8s_domain}"
            }])
          }

      }
      spec.workloads = [
        {
          name = workload
          nodeSelector = _config.nodeSelector.worker
        }
      for workload in ["activator" "autoscaler" "autoscaler-hpa" "controller" "net-istio-controller" "net-istio-webhook" "webhook"]
      ]
  }


  kn.KnativeEventing {
      metadata.name = "knative-eventing"
      metadata.namespace = _config.knative.eventing.namespace
      metadata.annotations = {
          "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true"
      }
      spec.version = _config.knative.eventing.version
      spec.config.tracing = {
          backend = "zipkin"
          "zipkin-endpoint" = "http://${_observability.tempo.helm.release_name}.${_observability.namespace}:9411/api/v2/spans"
          "sample-rate" = "1"
          debug = "true"
      }
      spec.config.observability = {
          "metrics-protocol" = "http/protobuf"
          "metrics-endpoint" = "http://${_observability.otlp.helm.release_name}-opentelemtry-collector.${_config.observability.namespace}:4318"
          "tracing-protocol" = "http/protobuf"
          "tracing-endpoint" = "http://${_observability.tempo.helm.release_name}.${_observability.namespace}:4318/v1/traces"
          "tracing-sampling-rate" = "1"
      }
      spec.workloads = [
        {
          name = workload
          nodeSelector = _config.nodeSelector.worker
        }
      for workload in ["eventing-controller" "eventing-webhook" "imc-controller" "imc-dispatcher" "job-sink" "mt-broker-controller" "mt-broker-filter" "mt-broker-ingress" "pingsource-mt-adapter"]
      ]
  }

  k8s.ConfigMap {
    metadata = {
      name = "config-nats"
      namespace = _config.knative.eventing.namespace
    }
    data = {
      "eventing-nats" = yaml.encode({
          url = "nats://${_config.nats.users.root.username}:${_config.nats.users.root.password}@${_config.nats.helm.release_name}.${_config.nats.namespace}:4222"
          connOpts = {
              retryOnFailedConnect = True
              maxReconnects = 50
              reconnectWait = 2000
              reconnectJitterMilliseconds = 100
              reconnectJitterTLSMilliseconds = 1000
          }
      })
    }
  }

  k8s.ConfigMap {
    metadata = {
      name = "config-br-default-channel"
      namespace = _config.knative.eventing.namespace
    }
    data = {
      "channel-template-spec" = yaml.encode({
        apiVersion = "messaging.knative.dev/v1"
        kind = "InMemoryChannel"
      })
    }
  }


]
