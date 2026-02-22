# =============================================================================
# K8s Cluster for COTURN on Hetzner Bare Metal
# =============================================================================

ANSIBLE_DIR := $(shell pwd)
PLAYBOOKS_DIR := $(ANSIBLE_DIR)/playbooks
SCRIPTS_DIR := $(ANSIBLE_DIR)/scripts
KUBECONFIG := $(ANSIBLE_DIR)/files/kubeconfig

.PHONY: help setup phase1 phase2 phase3 phase4 phase5 phase6 phase7 phase8 \
        phase9 phase10 verify teardown status ssh-master ssh-worker1 ssh-worker2 \
        preflight collections bootstrap grafana-tunnel

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Pre-flight ---

preflight: ## Check prerequisites
	@echo "=== Pre-flight Checks ==="
	@command -v ansible-playbook >/dev/null && echo "  ansible: OK" || echo "  ansible: MISSING"
	@command -v virsh >/dev/null && echo "  virsh: OK" || echo "  virsh: NOT INSTALLED (Phase 1 will install)"
	@command -v docker >/dev/null && echo "  docker: OK" || echo "  docker: MISSING"
	@echo "  Disk free: $$(df -h / | tail -1 | awk '{print $$4}')"
	@echo "  RAM free: $$(free -h | grep Mem | awk '{print $$7}')"
	@docker ps --format '{{.Names}}' | head -10 | sed 's/^/  Docker: /'

collections: ## Install required Ansible collections
	ansible-galaxy collection install community.libvirt kubernetes.core --force

# --- Full Setup ---

setup: collections ## Run all phases (full cluster setup)
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/site.yml -v

bootstrap: collections ## Full bootstrap (all phases + host kubectl) - run from interactive terminal
	cd $(ANSIBLE_DIR) && bash bootstrap.sh

# --- Individual Phases ---

phase1: ## Phase 1: Host setup (KVM/libvirt)
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/01-host-setup.yml -v

phase2: ## Phase 2: VM provisioning
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/02-vm-provision.yml -v

phase3: ## Phase 3: K8s prerequisites (all VMs)
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/03-k8s-common.yml -v

phase4: ## Phase 4: K8s master bootstrap
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/04-k8s-master.yml -v

phase5: ## Phase 5: K8s workers join
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/05-k8s-workers.yml -v

phase6: ## Phase 6: COTURN deployment
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/06-coturn-deploy.yml -v

phase7: ## Phase 7: Host iptables port forwarding
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/07-host-networking.yml -v

phase8: ## Phase 8: Install kubectl on host + kubeconfig
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/08-host-kubectl.yml -v

phase9: ## Phase 9: SNI proxy (TURNS on port 443)
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/09-sni-proxy.yml -v

phase10: ## Phase 10: Monitoring stack (Prometheus + Grafana)
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOKS_DIR)/10-monitoring.yml -v

# --- Operations ---

verify: ## Run cluster verification checks
	sudo bash $(SCRIPTS_DIR)/verify-cluster.sh

teardown: ## Full teardown (VMs, network, iptables)
	sudo bash $(SCRIPTS_DIR)/teardown.sh

teardown-keep-vms: ## Teardown iptables only, keep VMs
	sudo bash $(SCRIPTS_DIR)/teardown.sh --keep-vms

status: ## Show cluster status
	@echo "=== VMs ==="
	@virsh list --all 2>/dev/null || echo "  libvirt not installed"
	@echo ""
	@echo "=== K8s Nodes ==="
	@KUBECONFIG=$(KUBECONFIG) kubectl get nodes -o wide 2>/dev/null || echo "  kubeconfig not available"
	@echo ""
	@echo "=== K8s Pods ==="
	@KUBECONFIG=$(KUBECONFIG) kubectl get pods -A -o wide 2>/dev/null || echo "  kubeconfig not available"
	@echo ""
	@echo "=== COTURN ==="
	@KUBECONFIG=$(KUBECONFIG) kubectl get pods -n coturn -o wide 2>/dev/null || echo "  coturn namespace not found"
	@echo ""
	@echo "=== Docker ==="
	@docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo "  docker not available"

# --- SSH shortcuts ---

ssh-master: ## SSH into k8s-master
	ssh -i files/ssh/k8s_ed25519 -o StrictHostKeyChecking=no ubuntu@10.10.10.10

ssh-worker1: ## SSH into k8s-worker1
	ssh -i files/ssh/k8s_ed25519 -o StrictHostKeyChecking=no ubuntu@10.10.10.11

ssh-worker2: ## SSH into k8s-worker2
	ssh -i files/ssh/k8s_ed25519 -o StrictHostKeyChecking=no ubuntu@10.10.10.12

# --- kubectl shortcut ---

kubectl: ## Run kubectl with cluster kubeconfig (usage: make kubectl ARGS="get pods -A")
	KUBECONFIG=$(KUBECONFIG) kubectl $(ARGS)

# --- Tunnels ---

grafana-tunnel: ## SSH tunnel to Grafana (browse http://localhost:3000)
	@echo "Grafana tunnel: http://localhost:3000"
	ssh -L 3000:10.10.10.10:30300 -i files/ssh/k8s_ed25519 -o StrictHostKeyChecking=no -N ubuntu@10.10.10.10
