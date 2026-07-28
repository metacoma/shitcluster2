[package]
name = "shitcluster2"
edition = "v0.11.1"
version = "0.0.1"

[dependencies]
argoproj = { oci = "oci://ghcr.io/kcl-lang/argoproj", tag = "3.0.12" }
k8s = { oci = "oci://ghcr.io/kcl-lang/k8s", tag = "1.31.2", version = "1.31.2" }
kubevirt = { oci = "oci://ghcr.io/kcl-lang/kubevirt", tag = "0.3.0", version = "0.3.0" }
json_merge_patch = { oci = "oci://ghcr.io/kcl-lang/json_merge_patch", tag = "0.1.1" }

[profile]
entries = ["main.k"]
