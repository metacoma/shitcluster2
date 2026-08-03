import k8s.api.core.v1 as k8s
import config

manifests = [
    k8s.Namespace {
        metadata.name = config.mcp.namespace
    }
]
