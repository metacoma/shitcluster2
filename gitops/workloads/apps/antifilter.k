import k8s.api.core.v1 as k8s
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
af = _config.antifilter

manifests = [
  k8s.Namespace {
    metadata.name = af.namespace
  }
]
]
