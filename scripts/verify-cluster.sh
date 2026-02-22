#!/bin/bash
# =============================================================================
# Cluster health check and verification
# Usage: ./scripts/verify-cluster.sh
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG="$PROJECT_DIR/files/kubeconfig"
export KUBECONFIG

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
  local desc="$1"
  shift
  echo -n "  Checking: $desc... "
  if "$@" &>/dev/null; then
    echo -e "${GREEN}PASS${NC}"
    PASS=$((PASS+1))
  else
    echo -e "${RED}FAIL${NC}"
    FAIL=$((FAIL+1))
  fi
}

check_warn() {
  local desc="$1"
  shift
  echo -n "  Checking: $desc... "
  if "$@" &>/dev/null; then
    echo -e "${GREEN}PASS${NC}"
    PASS=$((PASS+1))
  else
    echo -e "${YELLOW}WARN${NC}"
    WARN=$((WARN+1))
  fi
}

echo "==========================================="
echo " K8s Cluster Verification"
echo "==========================================="
echo ""

# --- 1. VM Health ---
echo "1. VM Health"
for VM in k8s-master k8s-worker1 k8s-worker2; do
  check "$VM is running" bash -c "virsh domstate $VM | grep -q running"
done
echo ""

# --- 2. SSH Connectivity ---
echo "2. SSH Connectivity"
SSH_KEY="$PROJECT_DIR/files/ssh/k8s_ed25519"
for IP in 10.10.10.10 10.10.10.11 10.10.10.12; do
  check "SSH to $IP" ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$IP" echo ok
done
echo ""

# --- 3. Kubernetes Cluster ---
echo "3. Kubernetes Cluster"
check "kubectl can reach API server" kubectl cluster-info
check "3 nodes exist" test "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -eq 3
check "All nodes Ready" test "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -eq 3
echo ""

echo "  Node status:"
kubectl get nodes -o wide 2>/dev/null || echo "  (kubectl not available)"
echo ""

# --- 4. Cilium ---
echo "4. Cilium CNI"
check "Cilium agent pods running" bash -c "kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null | grep -q Running"
check "Cilium operator running" bash -c "kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-operator --no-headers 2>/dev/null | grep -q Running"
echo ""

# --- 5. COTURN Pods ---
echo "5. COTURN Deployment"
check "coturn namespace exists" kubectl get namespace coturn
check "coturn-worker1 pod running" bash -c "kubectl get pods -n coturn -l instance=coturn-worker1 --no-headers 2>/dev/null | grep -q Running"
check "coturn-worker2 pod running" bash -c "kubectl get pods -n coturn -l instance=coturn-worker2 --no-headers 2>/dev/null | grep -q Running"
echo ""

echo "  COTURN pods:"
kubectl get pods -n coturn -o wide 2>/dev/null || echo "  (no coturn pods)"
echo ""

# --- 6. iptables Rules ---
echo "6. iptables Rules"
check "COTURN_DNAT chain exists" iptables -t nat -L COTURN_DNAT -n
check "COTURN_SNAT chain exists" iptables -t nat -L COTURN_SNAT -n
check "FORWARD to 10.10.10.0/24" iptables -C FORWARD -d 10.10.10.0/24 -j ACCEPT
check "FORWARD from 10.10.10.0/24" iptables -C FORWARD -s 10.10.10.0/24 -j ACCEPT
echo ""

echo "  iptables NAT rules:"
iptables -t nat -L COTURN_DNAT -n -v 2>/dev/null || echo "  (COTURN_DNAT not found)"
echo ""

# --- 7. Port reachability ---
echo "7. Port Reachability (from host)"
for IP in 10.10.10.11 10.10.10.12; do
  check_warn "TURN port 3478/tcp on $IP" bash -c "echo | nc -w2 $IP 3478"
  check_warn "TURNS port 5349/tcp on $IP" bash -c "echo | nc -w2 $IP 5349"
done
check_warn "TURNS port 443/tcp on 10.10.10.11" bash -c "echo | nc -w2 10.10.10.11 443"
echo ""

# --- 7b. SNI Proxy ---
echo "7b. SNI Proxy (TURNS on port 443)"
check_warn "Host nginx running" systemctl is-active --quiet nginx
check_warn "SNI proxy listening on 127.0.0.1:4443" bash -c "ss -tlnp | grep -q 127.0.0.1:4443"
check_warn "Port 443 DNAT for IP1" bash -c "iptables -t nat -L COTURN_DNAT -n | grep -q '443.*127.0.0.1:4443'"
echo ""

# --- 8. Docker Containers ---
echo "8. Docker Containers (coexistence)"
for CTR in nginx nginx2 janus redis mongo; do
  check "$CTR is running" bash -c "docker inspect -f '{{.State.Running}}' $CTR 2>/dev/null | grep -q true"
done
check_warn "coturn container stopped (expected)" bash -c "! docker inspect -f '{{.State.Running}}' coturn 2>/dev/null | grep -q true"
echo ""

# --- 9. Monitoring Stack ---
echo "9. Monitoring Stack"
check_warn "monitoring namespace exists" kubectl get namespace monitoring
check_warn "Prometheus pod running" bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running"
check_warn "Grafana pod running" bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q Running"
check_warn "AlertManager pod running" bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -q Running"
check_warn "Grafana NodePort 30300" bash -c "kubectl get svc -n monitoring -o wide 2>/dev/null | grep -q 30300"
echo ""

echo "  Monitoring pods:"
kubectl get pods -n monitoring -o wide 2>/dev/null || echo "  (monitoring not deployed)"
echo ""

# --- 10. MAC Safety ---
echo "10. MAC Safety (Hetzner)"
echo "  Host MAC: 30:9c:23:02:78:65"
echo "  Run manually: tcpdump -i eth0 -e -c 100 | grep -v '30:9c:23:02:78:65'"
echo "  (Should produce no output -- all traffic uses host MAC)"
echo ""

# --- Summary ---
echo "==========================================="
echo -e " Results: ${GREEN}${PASS} PASS${NC}, ${RED}${FAIL} FAIL${NC}, ${YELLOW}${WARN} WARN${NC}"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
