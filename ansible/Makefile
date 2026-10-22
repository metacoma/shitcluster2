VENV_DIR := .venv
ACTIVATE := . $(VENV_DIR)/bin/activate
ANSIBLE_PLAY_CMD := ansible-playbook -i inventory.yml $(_ANSIBLE_ARGS)

# Edge (non-cluster) hosts. Must run from the REPOSITORY ROOT so Ansible's
# host_group_vars plugin does not pick up ansible/group_vars (the kubespray set)
# — see ansible/edge/inventory.yml for the verified variable-count trap.
ANSIBLE_INVENTORY := ansible/edge/inventory.yml
EDGE_PLAYBOOK ?= ansible/edge/vless_server.yml
VAULT_NS ?= vault
VAULT_BOOTSTRAP_CONFIGMAP ?= vault-bootstrap
VAULT_ADDR ?= http://172.25.1.4:8200


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

# Converge the VLESS/Xray edge server. Single recipe line = one shell so `cd ..`
# (to the repo root) holds for the run. venv activation does NOT carry into a
# recipe line, so the venv's ansible-playbook binary is invoked by path.
# VAULT_TOKEN is taken from the environment if already set, else fetched from the
# in-cluster vault-bootstrap secret (same source as `make root_token`).
#   make -C ansible ansible_edge_run ANSIBLE_ARGS="--check"
#   make -C ansible ansible_edge_run                       # real converge
ansible_edge_run: ansible_requirements
	cd .. && VAULT_ADDR="$${VAULT_ADDR:-$(VAULT_ADDR)}" VAULT_TOKEN="$${VAULT_TOKEN:-$$(kubectl -n $(VAULT_NS) get secret $(VAULT_BOOTSTRAP_CONFIGMAP) -o jsonpath='{.data.root_token}' | base64 -d)}" ANSIBLE_ROLES_PATH=ansible/roles ansible/.venv/bin/ansible-playbook -i $(ANSIBLE_INVENTORY) $(EDGE_PLAYBOOK) $(ANSIBLE_ARGS)

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

