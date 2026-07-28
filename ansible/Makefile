VENV_DIR := .venv
ACTIVATE := . $(VENV_DIR)/bin/activate
ANSIBLE_PLAY_CMD := ansible-playbook -i inventory.yml $(_ANSIBLE_ARGS)

.ONESHELL: python_requirements ansible_requirements venv ansible_ping

venv2:
	python3 -m venv $(VENV_DIR)

python_requirements: venv2
	$(ACTIVATE)
	pip3 install -r requirements.txt

ansible_requirements: python_requirements
	$(ACTIVATE)
	ansible-galaxy install -r requirements.yml

ansible_lint:
	ansible-lint .

ansible_run: ansible_requirements
	$(ACTIVATE)
	$(ANSIBLE_PLAY_CMD) $(ANSIBLE_ARGS)

ansible_ping: python_requirements
	$(ACTIVATE)
	ansible -m ping -i inventory.yml $(_ANSIBLE_ARGS) kube_node

network:
	make ansible_run ANSIBLE_ARGS=network.yml

disable_cloud_init_network:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root disable_cloud_init_network.yml"

kubespray:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root kubernetes.yml"

longhorn:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root longhorn.yml"

macvlan_dhcp:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root macvlan_dhcp.yml"

kubernetes:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root flow.yml"

fix_dns:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root fix_dns.yml"

reset:
	make ansible_run ANSIBLE_ARGS="-vv --become --become-user=root kubernetes_reset.yml"

argocd_setup: ansible_requirements
	$(ACTIVATE)
	$(ANSIBLE_PLAY_CMD) argocd-vault-setup.yml


terminate_ns:
	kubectl get ns $(NS) -o json | jq 'del(.spec.finalizers)' | kubectl replace --raw "/api/v1/namespaces/longhorn-system/finalize" -f -

