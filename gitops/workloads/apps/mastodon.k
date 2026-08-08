import k8s.api.core.v1 as k8s
import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg

_config = cfg.config
m = _config.mastodon

manifests = [
    # 1. Namespace
    k8s.Namespace {
        metadata.name = m.namespace
    }
    # 2. Nginx Ingress (web + streaming backends, TLS via reflected wildcard cert)
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = m.helm.release_name + "-ingress"
            namespace = m.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
                "nginx.ingress.kubernetes.io/proxy-body-size" = "40m"
            }
        }
        spec = {
            tls = [
                {
                    hosts = [m.ingress_host]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = m.ingress_host
                    http = {
                        paths = [
                            {
                                # Streaming API must be routed to the streaming service
                                path = "/api/v1/streaming"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = m.helm.release_name + "-streaming"
                                        port = {
                                            number = 4000
                                        }
                                    }
                                }
                            }
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = m.helm.release_name + "-web"
                                        port = {
                                            number = 3000
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
    # 3. PostgreSQL — native manifests, official image (non-FIPS)
    k8s.Secret {
        metadata = {
            name = m.postgresql.service_name
            namespace = m.namespace
        }
        stringData = {
            username = m.postgresql.username
            password = m.postgresql.password
        }
    }
    {
        apiVersion = "apps/v1"
        kind = "StatefulSet"
        metadata = {
            name = m.postgresql.service_name
            namespace = m.namespace
        }
        spec = {
            serviceName = m.postgresql.service_name
            replicas = 1
            selector = {
                matchLabels = {
                    app = m.postgresql.service_name
                }
            }
            template = {
                metadata = {
                    labels = {
                        app = m.postgresql.service_name
                    }
                }
                spec = {
                    nodeSelector = _config.nodeSelector.worker
                    securityContext = {
                        # Official postgres image entrypoint must run as root
                        # (it chowns the data dir and re-execs as postgres)
                        fsGroup = 999
                    }
                    containers = [
                        {
                            name = "postgresql"
                            image = m.postgresql.image
                            ports = [
                                {
                                    containerPort = 5432
                                }
                            ]
                            env = [
                                {
                                    name = "POSTGRES_USER"
                                    valueFrom = {
                                        secretKeyRef = {
                                            name = m.postgresql.service_name
                                            key = "username"
                                        }
                                    }
                                }
                                {
                                    name = "POSTGRES_PASSWORD"
                                    valueFrom = {
                                        secretKeyRef = {
                                            name = m.postgresql.service_name
                                            key = "password"
                                        }
                                    }
                                }
                                {
                                    name = "POSTGRES_DB"
                                    value = m.postgresql.database
                                }
                            ]
                            volumeMounts = [
                                {
                                    name = "data"
                                    mountPath = "/var/lib/postgresql/data"
                                }
                            ]
                            resources = {
                                requests = {
                                    cpu = "250m"
                                    memory = "512Mi"
                                }
                                limits = {
                                    cpu = "1000m"
                                    memory = "2Gi"
                                }
                            }
                            readinessProbe = {
                                exec = {
                                    command = [
                                        "pg_isready"
                                        "-U"
                                        m.postgresql.username
                                    ]
                                }
                                initialDelaySeconds = 10
                                periodSeconds = 10
                            }
                        }
                    ]
                    volumes = [
                        {
                            name = "data"
                            persistentVolumeClaim = {
                                claimName = m.postgresql.service_name
                            }
                        }
                    ]
                }
            }
            volumeClaimTemplates = [
                {
                    metadata = {
                        name = "data"
                    }
                    spec = {
                        accessModes = ["ReadWriteOnce"]
                        storageClassName = _config.storageClass
                        resources = {
                            requests = {
                                storage = m.postgresql.persistence
                            }
                        }
                    }
                }
            ]
        }
    }
    {
        apiVersion = "v1"
        kind = "Service"
        metadata = {
            name = m.postgresql.service_name
            namespace = m.namespace
        }
        spec = {
            selector = {
                app = m.postgresql.service_name
            }
            ports = [
                {
                    port = 5432
                    targetPort = 5432
                }
            ]
        }
    }
    # 4. ArgoCD Application — Redis (bitnami) for Mastodon
    argoproj.Application {
        metadata = {
            name = m.redis.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = m.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = m.redis.helm.chart_name
                repoURL = m.redis.helm.repo
                targetRevision = m.redis.helm.chart_version
                helm = {
                    values = yaml.encode({
                        auth = {
                            enabled = True
                            password = m.redis.password
                        }
                        replica = {
                            replicaCount = 0
                        }
                        master = {
                            persistence = {
                                storageClass = _config.storageClass
                                size = m.redis.persistence
                            }
                            resources = {
                                requests = {
                                    cpu = "100m"
                                    memory = "256Mi"
                                }
                                limits = {
                                    cpu = "500m"
                                    memory = "512Mi"
                                }
                            }
                        }
                        nodeSelector = _config.nodeSelector.worker
                    })
                }
            }
            syncPolicy = {
                automated = {
                    selfHeal = True
                }
            }
        }
    }
    # 5. ArgoCD Application — Mastodon (official chart)
    argoproj.Application {
        metadata = {
            name = m.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = m.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = m.helm.chart_name
                repoURL = m.helm.repo
                targetRevision = m.helm.chart_version
                helm = {
                    values = yaml.encode({
                        image = {
                            tag = m.helm.app_version
                        }
                        mastodon = {
                            localDomain = m.local_domain
                            # MVP: personal instance, registrations disabled,
                            # front page redirects to the owner profile
                            singleUserMode = True
                            secrets = {
                                secretKeyBase = m.secrets.secret_key_base
                                vapidPrivateKey = m.secrets.vapid_private_key
                                vapidPublicKey = m.secrets.vapid_public_key
                                arePrimaryKey = m.secrets.are_primary_key
                                areDeterministicKey = m.secrets.are_deterministic_key
                                areKeyDerivationSalt = m.secrets.are_derivation_salt
                            }
                            # Disabled for ArgoCD: hooks would not run in GitOps order.
                            # DB schema + migrations are run manually after first sync.
                            hooks = {
                                dbPrepare = {
                                    enabled = False
                                }
                                dbMigrate = {
                                    enabled = False
                                }
                            }
                            web = {
                                replicas = 1
                                resources = {
                                    requests = {
                                        cpu = m.resources.web.requests.cpu
                                        memory = m.resources.web.requests.memory
                                    }
                                    limits = {
                                        cpu = m.resources.web.limits.cpu
                                        memory = m.resources.web.limits.memory
                                    }
                                }
                                nodeSelector = _config.nodeSelector.worker
                            }
                            sidekiq = {
                                workers = [
                                    {
                                        name = "all-queues"
                                        replicas = 1
                                        queues = [
                                            "default,8"
                                            "push,6"
                                            "ingress,4"
                                            "mailers,2"
                                            "pull"
                                            "scheduler"
                                            "fasp"
                                        ]
                                        concurrency = 25
                                        resources = {
                                            requests = {
                                                cpu = m.resources.sidekiq.requests.cpu
                                                memory = m.resources.sidekiq.requests.memory
                                            }
                                            limits = {
                                                cpu = m.resources.sidekiq.limits.cpu
                                                memory = m.resources.sidekiq.limits.memory
                                            }
                                        }
                                        nodeSelector = _config.nodeSelector.worker
                                    }
                                ]
                            }
                            streaming = {
                                replicas = 1
                                resources = {
                                    requests = {
                                        cpu = m.resources.streaming.requests.cpu
                                        memory = m.resources.streaming.requests.memory
                                    }
                                    limits = {
                                        cpu = m.resources.streaming.limits.cpu
                                        memory = m.resources.streaming.limits.memory
                                    }
                                }
                                nodeSelector = _config.nodeSelector.worker
                            }
                            # No S3/MinIO for MVP — use Longhorn RWX PVCs
                            s3 = {
                                enabled = False
                            }
                            pvc = {
                                enabled = True
                                assets = {
                                    accessMode = "ReadWriteMany"
                                    resources = {
                                        requests = {
                                            storage = m.persistence.assets
                                        }
                                    }
                                }
                                system = {
                                    accessMode = "ReadWriteMany"
                                    resources = {
                                        requests = {
                                            storage = m.persistence.system
                                        }
                                    }
                                }
                            }
                            smtp = {
                                # Chart requires SMTP username/password unconditionally.
                                # Dummy creds from Vault: no real mail server for MVP,
                                # single-user instance is managed via CLI.
                                username = m.secrets.smtp_username
                                password = m.secrets.smtp_password
                            }
                        }
                        postgresql = {
                            hostname = m.postgresql.service_name
                            port = 5432
                            database = m.postgresql.database
                            # Auth from our native Secret (keys: username/password)
                            existingSecret = m.postgresql.service_name
                        }
                        redis = {
                            hostname = m.redis.service_name
                            port = 6379
                            password = m.redis.password
                        }
                        # Full-text search (Elasticsearch) disabled for MVP
                        elasticsearch = {
                            enabled = False
                        }
                        # Chart-managed ingress disabled — we use our own Ingress above
                        ingress = {
                            enabled = False
                        }
                        # Gateway API default disabled — we use nginx Ingress
                        httproute = {
                            enabled = False
                        }
                        metrics = {
                            prometheus = {
                                enabled = False
                            }
                        }
                        nodeSelector = _config.nodeSelector.worker
                    })
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
