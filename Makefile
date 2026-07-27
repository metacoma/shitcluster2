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
kubernetes: kubernetes_reset
	@echo "==> Running kubespray in ansible/"
	$(MAKE) -C ansible kubernetes 2>&1 | tee kubespray.log

LONGHORN_CHART_VERSION=1.11.3

.PHONY: longhorn
longhorn: update_kubeconfig longhorn_ansible longhorn_nad longhorn_helm

.PHONY: longhorn_ansible
longhorn_ansible:
	@echo "==> Running longhorn node preparation (apt, iSCSI) via ansible"
	$(MAKE) -C ansible longhorn 2>&1 | tee longhorn_ansible.log

.PHONY: longhorn_nad
longhorn_nad:
	@echo "==> Creating longhorn-system namespace and SAN NAD"
	kubectl create namespace $(LONGHORN_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f longhorn-san-nad.yaml

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

.PHONY: root_token
root_token:
	@$(VAULT_TOKEN_CMD); echo

.PHONY: argocd_prepare
argocd_prepare:
	$(TOFU_DOCKER) init
	$(TOFU_DOCKER) apply -auto-approve


argocd_uninstall:
	$(HELM_RUN) "\
		helm uninstall --namespace $(ARGOCD_NS) argocd --wait \
	"

argocd:
	$(HELM_RUN) "\
		helm repo add argocd https://argoproj.github.io/argo-helm && \
		helm repo update argocd && \
		helm upgrade --install --version $(ARGOCD_HELM_CHART_VERSION) --namespace argocd --create-namespace argocd argocd/argo-cd -f ./argocd/argocd_values.yml --wait --timeout $(ARGOCD_TIMEOUT) \
	"
	$(KUBECTL_RUN) '\
		kubectl apply -f ./argocd/kcl-cmp.yaml && \
		kubectl -n argocd patch deploy/argocd-repo-server -p "`cat ./argocd/patch-argocd-repo-server.yaml`" && \
		while :; do \
			kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-repo-server --field-selector=status.phase=Running | grep argocd-repo-server || { \
				echo -n .; \
				sleep 1; \
				continue; \
			}; \
			break; \
		done ; \
		kubectl wait --for=condition=ready pod -n argocd -l app.kubernetes.io/name=argocd-repo-server --timeout=600s \
	'

.PHONY: argocd_infra_app
argocd_infra_app:
	$(KUBECTL_RUN) 'cat argocd/infra.json | kubectl apply -f -'

.PHONY: argocd_workloads_app
argocd_workloads_app:
	$(KUBECTL_RUN) 'cat argocd/workloads.json | kubectl apply -f -'

.PHONY: argocd_password
argocd_password:
		$(eval ARGOCD_PASSWORD := $(shell $(KUBECTL_RUN) 'kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}"  |base64 -d;echo'))
			echo $(ARGOCD_PASSWORD)

.PHONY: update_kubeconfig
update_kubeconfig:
	ssh mcmp2.mgmt.mansion.shitcluster.io 'sudo cat /root/.kube/config' > ~/.kube/config
	ssh mcmp2.mgmt.mansion.shitcluster.io 'sudo cat /etc/kubernetes/pki/ca.crt' > /tmp/k8s-ca.crt
	python3 $(CURDIR)/patch_kubeconfig.py

.PHONY: vault vault_install
vault_install:
	helm repo add hashicorp https://helm.releases.hashicorp.com
	helm upgrade --install --namespace $(VAULT_NS) --create-namespace --install vault hashicorp/vault -f vault_values.yml

.ONESHELL: vault
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

flow: kubernetes update_kubeconfig argocd argocd_workloads_app
	echo DONE
