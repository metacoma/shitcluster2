[package]
name = "shitcluster2"
edition = "v0.11.1"
version = "0.0.1"

[dependencies]
argoproj = { oci = "oci://ghcr.io/kcl-lang/argoproj", tag = "3.0.12" }
k8s = { oci = "oci://ghcr.io/kcl-lang/k8s", tag = "1.31.2", version = "1.31.2" }
knative = { oci = "oci://ghcr.io/kcl-lang/knative", tag = "0.2.0" }
knative-operator = { oci = "oci://ghcr.io/kcl-lang/knative-operator", tag = "0.3.0" }
kubevirt = { oci = "oci://ghcr.io/kcl-lang/kubevirt", tag = "0.3.0", version = "0.3.0" }
victoria-metrics-operator = { oci = "oci://ghcr.io/kcl-lang/victoria-metrics-operator", tag = "0.45.3", version = "0.45.3" }
