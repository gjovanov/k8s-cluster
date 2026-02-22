#!/bin/bash
# =============================================================================
# K8s Cluster Bootstrap Script
# Run this from an interactive terminal where sudo works
#
# Usage: ./bootstrap.sh [phase-number]
#   ./bootstrap.sh        # Run all phases
#   ./bootstrap.sh 1      # Run only phase 1
#   ./bootstrap.sh 3 7    # Run phases 3 through 7
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[BOOTSTRAP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
phase() { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}  Phase $1: $2${NC}"; echo -e "${CYAN}============================================${NC}\n"; }

# --- Pre-flight checks ---
log "Pre-flight checks..."

# Check sudo works
if ! sudo -n whoami &>/dev/null; then
    log "Setting up temporary NOPASSWD sudo..."
    sudo bash -c 'echo "gjovanov ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/gjovanov-temp && chmod 440 /etc/sudoers.d/gjovanov-temp'
    if ! sudo -n whoami &>/dev/null; then
        err "Failed to configure NOPASSWD sudo"
    fi
    log "NOPASSWD sudo configured (remember to remove /etc/sudoers.d/gjovanov-temp later)"
fi

# Check ansible
command -v ansible-playbook &>/dev/null || err "ansible-playbook not found"

# Determine which phases to run
START_PHASE=${1:-1}
END_PHASE=${2:-10}

log "Will run phases $START_PHASE through $END_PHASE"
echo ""

# --- Phase 1: Host Setup ---
if [ "$START_PHASE" -le 1 ] && [ "$END_PHASE" -ge 1 ]; then
    phase 1 "Host Setup (KVM/libvirt)"
    ansible-playbook playbooks/01-host-setup.yml -v
fi

# --- Phase 2: VM Provisioning ---
if [ "$START_PHASE" -le 2 ] && [ "$END_PHASE" -ge 2 ]; then
    phase 2 "VM Provisioning"
    ansible-playbook playbooks/02-vm-provision.yml -v
fi

# --- Phase 3: K8s Prerequisites ---
if [ "$START_PHASE" -le 3 ] && [ "$END_PHASE" -ge 3 ]; then
    phase 3 "K8s Prerequisites (all VMs)"
    ansible-playbook playbooks/03-k8s-common.yml -v
fi

# --- Phase 4: K8s Master Bootstrap ---
if [ "$START_PHASE" -le 4 ] && [ "$END_PHASE" -ge 4 ]; then
    phase 4 "K8s Master Bootstrap (kubeadm init + Cilium)"
    ansible-playbook playbooks/04-k8s-master.yml -v
fi

# --- Phase 5: K8s Workers Join ---
if [ "$START_PHASE" -le 5 ] && [ "$END_PHASE" -ge 5 ]; then
    phase 5 "K8s Workers Join"
    ansible-playbook playbooks/05-k8s-workers.yml -v
fi

# --- Phase 6: COTURN Deployment ---
if [ "$START_PHASE" -le 6 ] && [ "$END_PHASE" -ge 6 ]; then
    phase 6 "COTURN Deployment"
    ansible-playbook playbooks/06-coturn-deploy.yml -v
fi

# --- Phase 7: Host iptables ---
if [ "$START_PHASE" -le 7 ] && [ "$END_PHASE" -ge 7 ]; then
    phase 7 "Host iptables Port Forwarding"
    ansible-playbook playbooks/07-host-networking.yml -v
fi

# --- Phase 8: Install kubectl on host ---
if [ "$START_PHASE" -le 8 ] && [ "$END_PHASE" -ge 8 ]; then
    phase 8 "Install kubectl on host + configure kubeconfig"
    ansible-playbook playbooks/08-host-kubectl.yml -v
fi

# --- Phase 9: SNI Proxy (TURNS on 443) ---
if [ "$START_PHASE" -le 9 ] && [ "$END_PHASE" -ge 9 ]; then
    phase 9 "SNI Proxy (TURNS on port 443)"
    ansible-playbook playbooks/09-sni-proxy.yml -v
fi

# --- Phase 10: Monitoring Stack ---
if [ "$START_PHASE" -le 10 ] && [ "$END_PHASE" -ge 10 ]; then
    phase 10 "Monitoring Stack (Prometheus + Grafana + AlertManager)"
    ansible-playbook playbooks/10-monitoring.yml -v
fi

echo ""
log "==========================================="
log "  Bootstrap Complete!"
log "==========================================="
echo ""
log "Quick verification:"
echo ""
kubectl get nodes -o wide 2>/dev/null || warn "kubectl not working yet"
echo ""
kubectl get pods -A 2>/dev/null | head -20 || true
echo ""
kubectl get pods -n coturn -o wide 2>/dev/null || warn "coturn namespace not found"
echo ""
log "Run 'make verify' for full health check"
log "Run 'make status' for quick status"
echo ""
log "Don't forget to remove temp sudoers when done:"
log "  sudo rm /etc/sudoers.d/gjovanov-temp"
