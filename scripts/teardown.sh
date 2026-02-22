#!/bin/bash
# =============================================================================
# Full teardown: VMs, network, iptables, restore Docker coturn
# Usage: ./scripts/teardown.sh [--keep-iptables] [--keep-vms]
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[TEARDOWN]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

KEEP_IPTABLES=false
KEEP_VMS=false

for arg in "$@"; do
  case $arg in
    --keep-iptables) KEEP_IPTABLES=true ;;
    --keep-vms) KEEP_VMS=true ;;
    --help|-h)
      echo "Usage: $0 [--keep-iptables] [--keep-vms]"
      exit 0
      ;;
  esac
done

# --- Restore Docker COTURN ---
log "Restoring Docker coturn container..."
docker start coturn 2>/dev/null && log "Docker coturn started" || warn "Docker coturn not found or already running"

# --- Remove K8s COTURN namespace ---
if command -v kubectl &>/dev/null && [ -f "$PROJECT_DIR/files/kubeconfig" ]; then
  log "Deleting COTURN K8s namespace..."
  KUBECONFIG="$PROJECT_DIR/files/kubeconfig" kubectl delete namespace coturn --timeout=60s 2>/dev/null || warn "coturn namespace not found"
fi

# --- Remove iptables rules ---
if [ "$KEEP_IPTABLES" = false ]; then
  log "Removing COTURN iptables rules..."

  # Remove DNAT chain
  iptables -t nat -D PREROUTING -j COTURN_DNAT 2>/dev/null || true
  iptables -t nat -F COTURN_DNAT 2>/dev/null || true
  iptables -t nat -X COTURN_DNAT 2>/dev/null || true

  # Remove SNAT chain
  iptables -t nat -D POSTROUTING -j COTURN_SNAT 2>/dev/null || true
  iptables -t nat -F COTURN_SNAT 2>/dev/null || true
  iptables -t nat -X COTURN_SNAT 2>/dev/null || true

  # Remove FORWARD rules
  iptables -D FORWARD -d 10.10.10.0/24 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -s 10.10.10.0/24 -j ACCEPT 2>/dev/null || true

  # Restore backup if exists
  if [ -f "$PROJECT_DIR/backup/iptables-backup.rules" ]; then
    log "Restoring iptables backup..."
    iptables-restore < "$PROJECT_DIR/backup/iptables-backup.rules"
  fi

  # Remove systemd service
  systemctl disable coturn-iptables 2>/dev/null || true
  rm -f /etc/systemd/system/coturn-iptables.service
  rm -f /etc/systemd/system/docker.service.d/coturn-iptables.conf
  systemctl daemon-reload

  log "iptables rules removed"
else
  warn "Keeping iptables rules (--keep-iptables)"
fi

# --- Destroy VMs ---
if [ "$KEEP_VMS" = false ]; then
  for VM in k8s-master k8s-worker1 k8s-worker2; do
    log "Destroying VM: $VM"
    virsh destroy "$VM" 2>/dev/null || warn "$VM not running"
    virsh undefine "$VM" --remove-all-storage 2>/dev/null || warn "$VM not defined"
  done

  # --- Remove libvirt network ---
  log "Removing k8s-net network..."
  virsh net-destroy k8s-net 2>/dev/null || warn "k8s-net not active"
  virsh net-undefine k8s-net 2>/dev/null || warn "k8s-net not defined"

  # --- Clean up cloud images ---
  log "Cleaning up cloud-init artifacts..."
  rm -f /var/lib/libvirt/images/k8s-*
  rm -rf /var/lib/libvirt/images/k8s-*-cloud-init

  log "VMs and network removed"
else
  warn "Keeping VMs (--keep-vms)"
fi

# --- Clean up local files ---
rm -f "$PROJECT_DIR/files/kubeconfig"

log "Teardown complete!"
log "Docker containers status:"
docker ps --format 'table {{.Names}}\t{{.Status}}'
