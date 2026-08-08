import k8s.api.core.v1 as k8s
import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
mm = _config.mattermost

# DB connection string (vals resolves ref+vault:// at render time; `+` terminates the expression)
_db_dsn = "postgres://${mm.db.user}:${mm.db_password}+@${mm.db.service}:5432/${mm.db.name}?sslmode=disable&connect_timeout=10"

manifests = [
    # 1. Namespace
    k8s.Namespace {
        metadata.name = mm.namespace
    }
    # 2. PVC for local file storage (uploads, avatars, etc.)
    k8s.PersistentVolumeClaim {
        metadata = {
            name = "mattermost-data"
            namespace = mm.namespace
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            storageClassName = _config.storageClass
            resources = {
                requests = {
                    storage = mm.persistence.size
                }
            }
        }
    }
    # 3. DB password secret for CNPG managed role (kubernetes.io/basic-auth)
    k8s.Secret {
        metadata = {
            name = "mattermost-db-password"
            namespace = mm.namespace
        }
        type = "kubernetes.io/basic-auth"
        stringData = {
            username = mm.db.user
            password = mm.db_password
        }
    }
    # 4. DB connection string secret consumed by the Mattermost chart (MM_CONFIG / DB_CONNECTION_STRING)
    k8s.Secret {
        metadata = {
            name = "mattermost-db-secret"
            namespace = mm.namespace
        }
        type = "Opaque"
        stringData = {
            DB_CONNECTION_STRING = _db_dsn
        }
    }
    # 5. Nginx Ingress for HTTPS traffic (wildcard cert via reflector)
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = mm.helm.release_name + "-ingress"
            namespace = mm.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
                "nginx.ingress.kubernetes.io/proxy-body-size" = "0"
                "nginx.ingress.kubernetes.io/proxy-buffering" = "off"
            }
        }
        spec = {
            tls = [
                {
                    hosts = [mm.ingress_host]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = mm.ingress_host
                    http = {
                        paths = [
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = mm.helm.release_name
                                        port = {
                                            number = 8065
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
    # 6. ArgoCD Application — CloudNativePG operator (manages PostgreSQL)
    argoproj.Application {
        metadata = {
            name = mm.cnpg.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = mm.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = mm.cnpg.helm.chart_name
                repoURL = mm.cnpg.helm.repo
                targetRevision = mm.cnpg.helm.chart_version
                helm = {
                    values = yaml.encode({
                        nodeSelector = _config.nodeSelector.worker
                        resources = {
                            requests = {
                                cpu = "50m"
                                memory = "128Mi"
                            }
                            limits = {
                                cpu = "500m"
                                memory = "512Mi"
                            }
                        }
                    })
                }
            }
            syncPolicy = {
                automated = {
                    prune = True
                    selfHeal = True
                }
                # CRDs (clusters, poolers) exceed the 256KB annotation limit
                # with client-side apply — ServerSideApply required
                syncOptions = [
                    "ServerSideApply=true"
                ]
            }
        }
    }
    # 7. CNPG Cluster — PostgreSQL 16 managed by CloudNativePG (10Gi on Longhorn)
    {
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Cluster"
        metadata = {
            name = mm.db.cluster
            namespace = mm.namespace
        }
        spec = {
            instances = 1
            storage = {
                size = mm.db.size
                storageClass = _config.storageClass
            }
            bootstrap = {
                initdb = {
                    database = mm.db.name
                    owner = mm.db.user
                    dataChecksums = True
                }
            }
            managed = {
                roles = [
                    {
                        name = mm.db.user
                        ensure = "present"
                        login = True
                        superuser = True
                        passwordSecret = {
                            name = "mattermost-db-password"
                        }
                    }
                ]
            }
            # CNPG Cluster CR has no top-level nodeSelector — use affinity.nodeSelector
            affinity = {
                nodeSelector = _config.nodeSelector.worker
            }
        }
    }
    # 8. ArgoCD Application — Mattermost (official chart, external PostgreSQL)
    argoproj.Application {
        metadata = {
            name = mm.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = mm.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = mm.helm.chart_name
                repoURL = mm.helm.repo
                targetRevision = mm.helm.chart_version
                helm = {
                    values = yaml.encode({
                        global = {
                            siteUrl = "https://" + mm.ingress_host
                            features = {
                                database = {
                                    driver = "postgres"
                                    existingDatabaseSecret = {
                                        name = "mattermost-db-secret"
                                        key = "DB_CONNECTION_STRING"
                                    }
                                }
                                fileStore = {
                                    driver = "local"
                                }
                                jobserver = {
                                    enabled = False
                                }
                            }
                        }
                        mattermostApp = {
                            replicaCount = 1
                            image = {
                                repository = "mattermost/mattermost-enterprise-edition"
                                tag = mm.helm.app_version
                                pullPolicy = "IfNotPresent"
                            }
                            service = {
                                type = "ClusterIP"
                                externalPort = 8065
                                internalPort = 8065
                                metricsPort = 8067
                                metricsName = "mattermost-app-metrics"
                            }
                            ingress = {
                                enabled = False
                            }
                            dbReadinessCheck = {
                                enabled = True
                            }
                            # Local filestore on Longhorn PVC
                            extraVolumes = [{
                                name = "mattermost-data"
                                persistentVolumeClaim = {
                                    claimName = "mattermost-data"
                                }
                            }]
                            extraVolumeMounts = [{
                                name = "mattermost-data"
                                mountPath = "/mattermost/data"
                            }]
                            nodeSelector = _config.nodeSelector.worker
                            # Mattermost image runs as uid 2000; fsGroup gives the
                            # Longhorn PVC mount group write access
                            securityContext = {
                                fsGroup = 2000
                            }
                            resources = {
                                requests = mm.resources.requests
                                limits = mm.resources.limits
                            }
                        }
                    })
                }
            }
            syncPolicy = {
                automated = {
                    prune = True
                    selfHeal = True
                }
            }
        }
    }
    # 9. VMServiceScrape for VictoriaMetrics
    vm_service_scrape.VMServiceScrape {
        metadata = {
            name = mm.helm.release_name + "-metrics"
            namespace = mm.namespace
        }
        spec = {
            selector.matchLabels = {
                "app.kubernetes.io/name" = mm.helm.release_name
            }
            endpoints = [{
                port = "mattermost-app-metrics"
                interval = "30s"
            }]
        }
    }
]
