infra = {
  ns = "infra"
  sops = {
    secret = "sops"
    public_key = "ref+vault://kv/sops/gitops#public_key"
    age_key = "ref+vault://kv/sops/gitops#age_secret_key"
  }
}
