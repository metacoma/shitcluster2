import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
nats = _config.nats

manifests = [
  k8s.Namespace {
    metadata.name = nats.namespace
  }
  argoproj.Application {
    metadata = {
        name = nats.helm.release_name
        namespace = "argocd"
    }
    spec = {
        destination = {
            namespace = nats.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = nats.helm.chart
            repoURL = nats.helm.repo
            targetRevision = nats.helm.version
            helm = {
                values = yaml.encode({
                  podTemplate.merge.spec.nodeSelector = _config.nodeSelector.worker
                  config = {
                    cluster = {
                        merge = {
                            name = "nats-cluster"
                            replicas = 2 # msut be 2 or highr when jetstream is enabled
                        }
                    }
                    jetstream = {
                        enabled = True
                        fileStore.pvc.size = "2Gi"
                    }
                    merge = {
                        accounts = {
                            "$SYS" = {
                                users = [
                                    {
                                        user = nats.users.sys.username
                                        password = nats.users.sys.password
                                    }
                                ]
                            }
                            root = {
                                jetstream = "enable"
                                users = [
                                    {
                                        user = nats.users.root.username
                                        password = nats.users.root.password
                                    }
                                ]
                            }
                        }
                    }
                  }
                })
                releaseName = nats.helm.release_name
            }
        }
        syncPolicy = {
            automated = {
                selfHeal = True
            }
        }
    }
  }
]
