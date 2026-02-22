#!/bin/bash
# =============================================================================
# acme.sh renewal hook — deploys new cert to all services
# Called automatically by acme.sh after successful renewal
# Usage: acme.sh --install-cert ... --reloadcmd "/path/to/this/script"
# =============================================================================

set -euo pipefail

CERT_SRC="/root/.acme.sh/roomler.live_ecc"
KUBECONFIG="/home/gjovanov/k8s-cluster/files/kubeconfig"
export KUBECONFIG

echo "[acme-deploy] Deploying renewed cert..."

# 1. Copy to ~/cert/ (used by Ansible for K8s secret)
cp "$CERT_SRC/fullchain.cer" /home/gjovanov/cert/roomler.live.fullchain.pem
cp "$CERT_SRC/roomler.live.key" /home/gjovanov/cert/roomler.live.key.pem
cp "$CERT_SRC/fullchain.cer" /home/gjovanov/cert/roomler.live.pem
cp "$CERT_SRC/roomler.live.key" /home/gjovanov/cert/roomler.live.key
chown gjovanov:gjovanov /home/gjovanov/cert/roomler.live.{fullchain.pem,key.pem,pem,key}
echo "[acme-deploy] Updated /home/gjovanov/cert/"

# 2. Copy to Docker nginx cert dir (mounted by both nginx and nginx2)
cp "$CERT_SRC/fullchain.cer" /gjovanov/nginx/cert/roomler.live.pem
cp "$CERT_SRC/roomler.live.key" /gjovanov/nginx/cert/roomler.live.key
echo "[acme-deploy] Updated /gjovanov/nginx/cert/"

# 3. Reload Docker nginx and nginx2
docker exec nginx nginx -s reload 2>/dev/null && echo "[acme-deploy] nginx reloaded" || echo "[acme-deploy] WARN: nginx reload failed"
docker exec nginx2 nginx -s reload 2>/dev/null && echo "[acme-deploy] nginx2 reloaded" || echo "[acme-deploy] WARN: nginx2 reload failed"

# 4. Recreate K8s COTURN TLS secret
kubectl delete secret coturn-tls -n coturn 2>/dev/null || true
kubectl create secret tls coturn-tls \
  --cert=/home/gjovanov/cert/roomler.live.fullchain.pem \
  --key=/home/gjovanov/cert/roomler.live.key.pem \
  -n coturn
echo "[acme-deploy] K8s secret coturn-tls recreated"

# 5. Restart COTURN pods to pick up new cert
kubectl rollout restart deployment coturn-worker1 coturn-worker2 -n coturn
kubectl rollout status deployment coturn-worker1 coturn-worker2 -n coturn --timeout=60s
echo "[acme-deploy] COTURN pods restarted"

echo "[acme-deploy] Done!"
