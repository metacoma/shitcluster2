import argoproj.v1alpha1 as argoproj
import yaml
import json
import file
import manifests
import json_merge_patch as json_patch
import tekton
import vault_unseal
import k8s.api.core.v1 as k8s
import config

manifests.yaml_stream([

  k8s.Namespace {
    metadata.name = config.infra.ns
  }

  k8s.Secret {
    metadata = {
      name = config.infra.sops.secret
      namespace = config.infra.ns
    }
    stringData = {
      public_key = config.infra.sops.public_key
      age_key = config.infra.sops.age_key
    }
  }

  tekton.manifests

  vault_unseal.manifests
])
