-include .env


KUBECTL_RUN_OPTS := -i --rm -v ~/.kube:/kube -e KUBECONFIG=/kube/config --network=host -v`pwd`:/host -w /host -u root --entrypoint /bin/sh alpine/kubectl:$(KUBECTL_VERSION) -c
KUBECTL_RUN := docker run $(KUBECTL_RUN_OPTS)
KUBECTL_IT_RUN := docker run -it $(KUBECTL_RUN_OPTS)

HELM_RUN := docker run --rm -v ~/.kube:/root/.kube -e KUBECONFIG=/root/.kube/config --network=host -v`pwd`:/host -w /host --entrypoint /bin/sh alpine/helm:$(HELM_VERSION) -c

VAULT_TOKEN_CMD = kubectl -n $(VAULT_NS) get secret $(VAULT_BOOTSTRAP_CONFIGMAP) -o jsonpath='{.data.root_token}' | base64 -d

define TOFU_DOCKER
docker run --rm -it \
  -v $(CURDIR)/argocd/terraform:/work \
  -v $(HOME)/.kube/config:/root/.kube/config \
  -w /work \
  -e VAULT_ADDR=http://172.25.1.4:8200 \
  -e VAULT_TOKEN=$$( $(VAULT_TOKEN_CMD) ) \
  ghcr.io/opentofu/opentofu:latest
endef


.PHONY: kubespray_reset
kubernetes_reset:
	@echo "==> Running kubespray in ansible/"
	$(MAKE) -C ansible reset 2>&1 | tee kubespray_reset.log

.PHONY: kubespray
kubernetes:
	@echo "==> Running kubespray in ansible/"
	$(MAKE) -C ansible kubernetes 2>&1 | tee kubespray.log

LONGHORN_CHART_VERSION=1.11.3

.PHONY: longhorn
longhorn: update_kubeconfig longhorn_ansible longhorn_storage_network longhorn_helm

.PHONY: longhorn_ansible
longhorn_ansible:
	@echo "==> Running longhorn node preparation (apt, iSCSI) via ansible"
	$(MAKE) -C ansible longhorn 2>&1 | tee longhorn_ansible.log

.PHONY: longhorn_storage_network
longhorn_storage_network:
	@echo "==> Installing Whereabouts CNI and creating Longhorn SAN NAD"
	$(MAKE) -C ansible ansible_run ANSIBLE_ARGS="-vv --become --become-user=root longhorn_storage_network.yml" 2>&1 | tee longhorn_storage_network.log

.PHONY: longhorn_helm
longhorn_helm:
	@echo "==> Installing Longhorn $(LONGHORN_CHART_VERSION) via Helm"
	helm repo add longhorn https://charts.longhorn.io
	helm repo update longhorn
	helm upgrade --install --version $(LONGHORN_CHART_VERSION) --create-namespace longhorn longhorn/longhorn --namespace $(LONGHORN_NS) --values=longhorn_values.yml --wait
	kubectl apply -f longhorn-backuptarget.yaml

longhorn_confirm_disable:
	kubectl -n $(LONGHORN_NS) patch settings.longhorn.io deleting-confirmation-flag   --type='json'   -p='[{"op":"replace","path":"/value","value":"true"}]'

longhorn_uninstall: longhorn_confirm_disable
	helm uninstall longhorn -n $(LONGHORN_NS)

.PHONY: argocd argocd_uninstall

VAULT_CHART_VERSION=0.34.0
VAULT_CHART_COMMIT=8e4887ccec5dec2bf7168a229aaf5dc06e708ab6

.PHONY: root_token
root_token:
	@$(VAULT_TOKEN_CMD); echo

VAULT_ADDR = http://172.25.1.4:8200
SOPS_AGE_KEY_FILE = ~/.config/sops/age/keys.txt

.PHONY: argocd_prepare
argocd_prepare:
	@echo "==> Creating argocd namespace"
	@kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Setting up Vault for ArgoCD"
	@export VAULT_ADDR=$(VAULT_ADDR) && \
	export VAULT_TOKEN="$$( $(VAULT_TOKEN_CMD) )" && \
	export SOPS_PUBLIC_KEY="$(SOPS_PUBLIC_KEY)" && \
	export SOPS_AGE_SECRET_KEY="$(SOPS_AGE_SECRET_KEY)" && \
	. ansible/.venv/bin/activate && \
	ansible-playbook -i ansible/inventory.yml ansible/argocd-vault-setup.yml \
		-e sops_public_key="$$SOPS_PUBLIC_KEY" \
		-e sops_age_secret_key="$$SOPS_AGE_SECRET_KEY"

.PHONY: sops_to_vault
sops_to_vault:
	@echo "==> Importing SOPS secrets into Vault"
	@export VAULT_ADDR=$(VAULT_ADDR) && \
	export VAULT_TOKEN="$$( $(VAULT_TOKEN_CMD) )" && \
	export SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) && \
	cd ansible/sops-to-vault && \
	. ../.venv/bin/activate && \
	ansible-playbook sops_to_vault.yml \
		-e vault_addr="$$VAULT_ADDR" \
		-e vault_token="$$VAULT_TOKEN" \
		-e sops_file="$(CURDIR)/secrets/vault_data.sops.yaml" \
		-e strip_prefix=vault_data

argocd_uninstall:
	$(HELM_RUN) "\
		helm uninstall --namespace $(ARGOCD_NS) argocd --wait \
	"

argocd:
	@echo "==> Creating cmp-plugin configmap"
	@kubectl -n argocd create configmap cmp-plugin --from-file=avp.yaml=./argocd/cmp-plugin-avp.yaml --dry-run=client -o yaml | kubectl apply -f -
	$(HELM_RUN) "\
		helm repo add argocd https://argoproj.github.io/argo-helm && \
		helm repo update argocd && \
		helm upgrade --install --version $(ARGOCD_HELM_CHART_VERSION) --namespace argocd --create-namespace argocd argocd/argo-cd -f ./argocd/argocd_values.yml --wait --timeout $(ARGOCD_TIMEOUT) \
	"
	$(KUBECTL_RUN) '\
		kubectl apply -f ./argocd/kcl-cmp.yaml && \
		kubectl -n argocd patch deploy/argocd-repo-server -p "`cat ./argocd/patch-argocd-repo-server.yaml`" && \
		kubectl -n argocd rollout restart deploy/argocd-repo-server && \
		kubectl wait --for=condition=ready pod -n argocd -l app.kubernetes.io/name=argocd-repo-server --timeout=600s \
	'

.PHONY: argocd_infra_app
argocd_infra_app:
	$(KUBECTL_RUN) 'cat argocd/infra.json | kubectl apply -f -'
	@echo "==> Enabling auto-sync for infra"
	@kubectl -n argocd patch application infra --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":true}}}}'
	@echo "==> Refreshing infra application"
	@kubectl -n argocd annotate application infra argocd.argoproj.io/refresh=hard --overwrite

.PHONY: argocd_workloads_app
argocd_workloads_app:
	$(KUBECTL_RUN) 'cat argocd/workloads.json | kubectl apply -f -'
	@echo "==> Enabling auto-sync for workloads"
	@kubectl -n argocd patch application workloads --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":true}}}}'
	@echo "==> Refreshing workloads application"
	@kubectl -n argocd annotate application workloads argocd.argoproj.io/refresh=hard --overwrite

.PHONY: argocd_wait_infra
argocd_wait_infra:
	@echo "==> Waiting for infra to sync..."
	@while true; do \
		STATUS=$$(kubectl -n argocd get application infra -o jsonpath='{.status.sync.status}' 2>/dev/null); \
		HEALTH=$$(kubectl -n argocd get application infra -o jsonpath='{.status.health.status}' 2>/dev/null); \
		echo "  infra: $$STATUS / $$HEALTH"; \
		if [ "$$STATUS" = "Synced" ] && [ "$$HEALTH" = "Healthy" ]; then \
			echo "  infra synced and healthy"; \
			break; \
		fi; \
		sleep 10; \
	done

.PHONY: argocd_wait_workloads
argocd_wait_workloads:
	@echo "==> Waiting for workloads to sync..."
	@while true; do \
		STATUS=$$(kubectl -n argocd get application workloads -o jsonpath='{.status.sync.status}' 2>/dev/null); \
		HEALTH=$$(kubectl -n argocd get application workloads -o jsonpath='{.status.health.status}' 2>/dev/null); \
		echo "  workloads: $$STATUS / $$HEALTH"; \
		if [ "$$STATUS" = "Synced" ] && [ "$$HEALTH" = "Healthy" ]; then \
			echo "  workloads synced and healthy"; \
			break; \
		fi; \
		sleep 10; \
	done

.PHONY: argocd_password
argocd_password:
		$(eval ARGOCD_PASSWORD := $(shell $(KUBECTL_RUN) 'kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}"  |base64 -d;echo'))
			echo $(ARGOCD_PASSWORD)

.PHONY: update_kubeconfig
update_kubeconfig:
	ssh mcmp2.mgmt.mansion.shitcluster.io 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config

.PHONY: vault vault_install
vault_install:
	git clone --depth 1 --branch v$(VAULT_CHART_VERSION) https://github.com/hashicorp/vault-helm.git /tmp/vault-helm
	helm upgrade --install --namespace $(VAULT_NS) --create-namespace vault /tmp/vault-helm -f vault_values.yml


vault_secrets:
	ROOT_TOKEN=$$(kubectl exec -n $(VAULT_NS) vault-0 -- sh -c "grep 'Initial Root Token:' /tmp/init.txt | awk '{print \$$4}'")
	UNSEAL_KEY=$$(kubectl exec -n $(VAULT_NS) vault-0 -- sh -c "grep 'Unseal Key 1:' /tmp/init.txt | awk '{print \$$4}'")
	echo "ROOT_TOKEN=$$ROOT_TOKEN"
	echo "UNSEAL_KEY=$$UNSEAL_KEY"
	kubectl -n $(VAULT_NS) create secret generic $(VAULT_BOOTSTRAP_CONFIGMAP) \
	  --from-literal=root_token="$$ROOT_TOKEN" \
	  --from-literal=unseal_key="$$UNSEAL_KEY"


.ONESHELL: vault
.SHELLFLAGS := -ec
vault: vault_install
	echo "Waiting for /tmp/init.txt to appear in vault-0..."
	while ! kubectl exec -n $(VAULT_NS) vault-0 -- test -f /tmp/init.txt 2>/dev/null; do
		sleep 2
	done

	ROOT_TOKEN=$$(kubectl exec -n $(VAULT_NS) vault-0 -- sh -c "grep 'Initial Root Token:' /tmp/init.txt | awk '{print \$$4}'")
	UNSEAL_KEY=$$(kubectl exec -n $(VAULT_NS) vault-0 -- sh -c "grep 'Unseal Key 1:' /tmp/init.txt | awk '{print \$$4}'")

	kubectl exec -n $(VAULT_NS) vault-0 -- rm -f /tmp/init.txt

	echo "ROOT_TOKEN=$$ROOT_TOKEN"
	echo "UNSEAL_KEY=$$UNSEAL_KEY"
	kubectl -n $(VAULT_NS) create secret generic $(VAULT_BOOTSTRAP_CONFIGMAP) \
	  --from-literal=root_token="$$ROOT_TOKEN" \
	  --from-literal=unseal_key="$$UNSEAL_KEY"


vault-unseal:
	@echo "🔐 Unsealing Vault in namespace $(VAULT_NS)..."
	@UNSEAL_KEY=$$(kubectl -n $(VAULT_NS) get secret vault-bootstrap \
		-o jsonpath='{.data.unseal_key}' | base64 -d) ; \
	POD=$$(kubectl -n $(VAULT_NS) get pod \
		-l app.kubernetes.io/name=vault \
		-o jsonpath='{.items[0].metadata.name}') ; \
	echo "→ Using pod: $$POD" ; \
	kubectl -n $(VAULT_NS) exec -ti $$POD -- vault operator unseal $$UNSEAL_KEY

vault_uninstall:
	kubectl -n $(VAULT_NS) delete secret $(VAULT_BOOTSTRAP_CONFIGMAP)
	helm uninstall --namespace $(VAULT_NS) vault --wait
	kubectl -n $(VAULT_NS) delete pvc --all

flow: kubernetes update_kubeconfig longhorn vault sops_to_vault argocd_prepare argocd argocd_infra_app argocd_workloads_app
	@echo DONE
