#!/bin/bash
# =============================================================================
# Full rebuild: tear down cluster and recreate from scratch
# Logs duration of each step
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAYBOOKS_DIR="$PROJECT_DIR/playbooks"
LOG_FILE="$PROJECT_DIR/rebuild.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source .env and export all vars
set -a
source "$PROJECT_DIR/.env"
set +a

TOTAL_START=$(date +%s)

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK${NC} $*" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${NC} $*" | tee -a "$LOG_FILE"; }

run_phase() {
  local phase_num=$1
  local playbook=$2
  local desc=$3

  log "=========================================="
  log "Phase $phase_num: $desc"
  log "=========================================="

  local start=$(date +%s)

  if cd "$PROJECT_DIR" && ansible-playbook "$PLAYBOOKS_DIR/$playbook" -v 2>&1 | tee -a "$LOG_FILE"; then
    local end=$(date +%s)
    local dur=$((end - start))
    ok "Phase $phase_num completed in ${dur}s"
    echo "Phase $phase_num: $desc — ${dur}s" >> "$PROJECT_DIR/rebuild-summary.log"
  else
    local end=$(date +%s)
    local dur=$((end - start))
    err "Phase $phase_num FAILED after ${dur}s"
    echo "Phase $phase_num: $desc — FAILED after ${dur}s" >> "$PROJECT_DIR/rebuild-summary.log"
    exit 1
  fi
}

# Clear logs
> "$LOG_FILE"
> "$PROJECT_DIR/rebuild-summary.log"

log "Starting full rebuild..."
log "Environment: CF_Token=${CF_Token:+set} CF_Zone_ID=${CF_Zone_ID:+set} COTURN_AUTH_SECRET=${COTURN_AUTH_SECRET:+set} GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:+set} ALERTMANAGER_SMTP_PASSWORD=${ALERTMANAGER_SMTP_PASSWORD:+set}"

# ============================================
# TEARDOWN
# ============================================
log "=========================================="
log "TEARDOWN"
log "=========================================="
TEAR_START=$(date +%s)
sudo bash "$SCRIPT_DIR/teardown.sh" 2>&1 | tee -a "$LOG_FILE" || true
TEAR_END=$(date +%s)
TEAR_DUR=$((TEAR_END - TEAR_START))
ok "Teardown completed in ${TEAR_DUR}s"
echo "Teardown — ${TEAR_DUR}s" >> "$PROJECT_DIR/rebuild-summary.log"

# ============================================
# COLLECTIONS
# ============================================
log "=========================================="
log "Installing Ansible collections"
log "=========================================="
COLL_START=$(date +%s)
ansible-galaxy collection install community.libvirt kubernetes.core --force 2>&1 | tee -a "$LOG_FILE"
COLL_END=$(date +%s)
COLL_DUR=$((COLL_END - COLL_START))
ok "Collections installed in ${COLL_DUR}s"
echo "Collections — ${COLL_DUR}s" >> "$PROJECT_DIR/rebuild-summary.log"

# ============================================
# PHASES 1-10
# ============================================
run_phase 1  "01-host-setup.yml"       "Host setup (KVM/libvirt)"
run_phase 2  "02-vm-provision.yml"     "VM provisioning"

log "Waiting 30s for VMs to finish cloud-init..."
sleep 30

run_phase 3  "03-k8s-common.yml"       "K8s prerequisites"
run_phase 4  "04-k8s-master.yml"       "K8s master bootstrap"
run_phase 5  "05-k8s-workers.yml"      "K8s workers join"
run_phase 6  "06-coturn-deploy.yml"    "COTURN deployment"
run_phase 7  "07-host-networking.yml"  "Host iptables port forwarding"
run_phase 8  "08-host-kubectl.yml"     "Install kubectl on host"
run_phase 9  "09-sni-proxy.yml"        "SNI proxy"
run_phase 10 "10-monitoring.yml"       "Monitoring stack"

# ============================================
# VERIFICATION
# ============================================
log "=========================================="
log "VERIFICATION"
log "=========================================="
VER_START=$(date +%s)
sudo bash "$SCRIPT_DIR/verify-cluster.sh" 2>&1 | tee -a "$LOG_FILE" || true
VER_END=$(date +%s)
VER_DUR=$((VER_END - VER_START))
echo "Verification — ${VER_DUR}s" >> "$PROJECT_DIR/rebuild-summary.log"

# ============================================
# COTURN CONNECTIVITY TESTS
# ============================================
log "=========================================="
log "COTURN CONNECTIVITY TESTS"
log "=========================================="
TEST_START=$(date +%s)

KUBECONFIG="$PROJECT_DIR/files/kubeconfig"

log "Checking COTURN pods..."
KUBECONFIG="$KUBECONFIG" kubectl get pods -n coturn -o wide 2>&1 | tee -a "$LOG_FILE"

log ""
log "--- Test 1: TURN via public IP1 (94.130.141.98:3478 UDP) ---"
if timeout 5 bash -c 'echo -ne "\x00\x01\x00\x00\x21\x12\xa4\x42$(head -c 12 /dev/urandom)" | nc -u -w2 94.130.141.98 3478 | head -c1' 2>/dev/null | grep -q .; then
  ok "TURN UDP 94.130.141.98:3478 — reachable"
else
  # Fallback: just test TCP connect
  if timeout 5 bash -c 'echo "" | nc -w2 94.130.141.98 3478' 2>/dev/null; then
    ok "TURN TCP 94.130.141.98:3478 — reachable"
  else
    err "TURN 94.130.141.98:3478 — NOT reachable"
  fi
fi

log "--- Test 2: TURN via public IP2 (94.130.141.74:3478 UDP) ---"
if timeout 5 bash -c 'echo -ne "\x00\x01\x00\x00\x21\x12\xa4\x42$(head -c 12 /dev/urandom)" | nc -u -w2 94.130.141.74 3478 | head -c1' 2>/dev/null | grep -q .; then
  ok "TURN UDP 94.130.141.74:3478 — reachable"
else
  if timeout 5 bash -c 'echo "" | nc -w2 94.130.141.74 3478' 2>/dev/null; then
    ok "TURN TCP 94.130.141.74:3478 — reachable"
  else
    err "TURN 94.130.141.74:3478 — NOT reachable"
  fi
fi

log "--- Test 3: TURNS via coturn.roomler.live:5349 (TLS) ---"
if echo | timeout 10 openssl s_client -connect coturn.roomler.live:5349 -servername coturn.roomler.live 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null; then
  ok "TURNS coturn.roomler.live:5349 — TLS OK"
else
  err "TURNS coturn.roomler.live:5349 — TLS FAILED"
fi

log "--- Test 4: TURNS via coturn.roomler.live:443 (SNI proxy) ---"
if echo | timeout 10 openssl s_client -connect coturn.roomler.live:443 -servername coturn.roomler.live 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null; then
  ok "TURNS coturn.roomler.live:443 — TLS OK (SNI proxy working)"
else
  err "TURNS coturn.roomler.live:443 — TLS FAILED"
fi

log "--- Test 5: DNS resolution ---"
host -t A coturn.roomler.live 2>&1 | tee -a "$LOG_FILE" || true

TEST_END=$(date +%s)
TEST_DUR=$((TEST_END - TEST_START))
echo "COTURN tests — ${TEST_DUR}s" >> "$PROJECT_DIR/rebuild-summary.log"

# ============================================
# SUMMARY
# ============================================
TOTAL_END=$(date +%s)
TOTAL_DUR=$((TOTAL_END - TOTAL_START))
TOTAL_MIN=$((TOTAL_DUR / 60))
TOTAL_SEC=$((TOTAL_DUR % 60))

echo "" >> "$PROJECT_DIR/rebuild-summary.log"
echo "TOTAL — ${TOTAL_DUR}s (${TOTAL_MIN}m ${TOTAL_SEC}s)" >> "$PROJECT_DIR/rebuild-summary.log"

log ""
log "=========================================="
log "REBUILD SUMMARY"
log "=========================================="
cat "$PROJECT_DIR/rebuild-summary.log" | tee -a "$LOG_FILE"
log ""
log "Total rebuild time: ${TOTAL_MIN}m ${TOTAL_SEC}s"
log "Full log: $LOG_FILE"
