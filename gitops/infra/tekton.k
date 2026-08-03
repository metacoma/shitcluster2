import yaml
import file
import json_merge_patch as json_patch

needNodeSelector = ["ReplicaSet", "Pod", "Deployment"]

manifests = [
    [[
        if resource:
            if resource.kind in needNodeSelector:
                if resource.kind in ["Deployment", "ReplicaSet"]:
                    json_patch.merge(resource, {
                        spec.template.spec.nodeSelector = {
                            "node-role.kubernetes.io/worker" = ""
                        }
                    })
                else:
                    json_patch.merge(resource, {
                        metadata.nodeSelector = {
                            "node-role.kubernetes.io/worker" = ""
                        }
                    })
            else:
                resource
    ] for resource in yaml.decode_all(file.read("tekton-pipelines.yml"))]
]
