import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg

_config = cfg.config
fj_runner = _config.forgejo_runner

manifests = [
    # ArgoCD Application — Helm chart (OCI)
    argoproj.Application {
        metadata = {
            name = fj_runner.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = fj_runner.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = fj_runner.helm.chart_name
                repoURL = fj_runner.helm.repo
                targetRevision = fj_runner.helm.chart_version
                helm = {
                    values = yaml.encode({
                        # --- Image ---
                        image = {
                            registry = fj_runner.image.registry
                            repository = fj_runner.image.repository
                            tag = fj_runner.image.tag
                            pullPolicy = "IfNotPresent"
                        }
                        # --- Runner config ---
                        runner = {
                            config = {
                                create = True
                                instance = fj_runner.runner.instance
                                name = fj_runner.runner.name
                                token = fj_runner.runner.token
                                file = {
                                    runner = {
                                        capacity = fj_runner.runner.capacity
                                        labels = fj_runner.runner.labels
                                        insecure = False
                                        timeout = "3h"
                                        fetch_interval = "2s"
                                        fetch_timeout = "5s"
                                        envs = {
                                            HOME = "/home/runner"
                                        }
                                    }
                                    log = {
                                        level = "info"
                                        job_level = "info"
                                    }
                                    cache = {
                                        enabled = True
                                    }
                                    container = {
                                        docker_host = "-"
                                        network = ""
                                        privileged = False
                                        force_pull = True
                                    }
                                }
                            }
                        }
                        # --- Security (privileged required for DIND) ---
                        securityContext = {
                            privileged = True
                        }
                        podSecurityContext = {
                            fsGroup = 1000
                        }
                        # --- Resources ---
                        resources = {
                            limits = {
                                cpu = fj_runner.resources.limits.cpu
                                memory = fj_runner.resources.limits.memory
                            }
                            requests = {
                                cpu = fj_runner.resources.requests.cpu
                                memory = fj_runner.resources.requests.memory
                            }
                        }
                        # --- DIND resources ---
                        dind = {
                            resources = {
                                limits = {
                                    cpu = fj_runner.dind_resources.limits.cpu
                                    memory = fj_runner.dind_resources.limits.memory
                                }
                                requests = {
                                    cpu = fj_runner.dind_resources.requests.cpu
                                    memory = fj_runner.dind_resources.requests.memory
                                }
                            }
                        }
                        # --- Scheduling ---
                        nodeSelector = _config.nodeSelector.worker
                        tolerations = [
                            {
                                key = "node-role.kubernetes.io/worker"
                                operator = "Exists"
                                effect = "NoSchedule"
                            }
                        ]
                        # --- Misc ---
                        replicaCount = 1
                        knownLastVersion = True
                        serviceAccount = {
                            create = True
                            automount = True
                        }
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
