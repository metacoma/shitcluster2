infra = {
    ns = "infra"
    sops = {
        secret = "sops"
        public_key = "ref+vault://kv/sops/gitops#public_key"
        age_key = "ref+vault://kv/sops/gitops#age_secret_key"
    }
    vault = {
        ns = "vault"
        service = "vault"
        port = 8200
        scheme = "http"
    }
}

mcp = {
    namespace = "mcp"
    ddgs = {
        image = "docker.io/library/ddgs-mcp-ddgs-mcp:latest"
        port = 8096
    }
}
