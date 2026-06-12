#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/bootstrap-externalsecrets.sh — Bootstrap ExternalSecrets operator and restore TLS secrets
#
# Usage: ENV_NAME=productie bash scripts/deploy/bootstrap-externalsecrets.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ENV=${ENV_NAME:?ENV_NAME required}
KB=~/.kube/config-platform-$ENV
# Variables exported from previous step
SERVICE_TOKEN="${ESO_SERVICE_TOKEN:-}"
OPENBAO_ADDR="${OPENBAO_CLUSTER_ADDR:-http://openbao.openbao.svc.cluster.local:8200}"
echo "==> Waiting for ESO deployment..."
for i in $(seq 1 30); do
  if kubectl --kubeconfig "$KB" get deployment external-secrets -n external-secrets >/dev/null 2>&1; then break; fi
  echo "  Waiting for ESO ($i/30)..."
  sleep 10
done
kubectl --kubeconfig "$KB" wait deployment/external-secrets \
  -n external-secrets --for=condition=available --timeout=120s 2>/dev/null || \
  echo "⚠ ESO not yet available"
for i in $(seq 1 30); do
  if kubectl --kubeconfig "$KB" get deployment external-secrets-webhook -n external-secrets >/dev/null 2>&1; then break; fi
  echo "  Waiting for ESO webhook ($i/30)..."
  sleep 10
done
kubectl --kubeconfig "$KB" wait deployment/external-secrets-webhook \
  -n external-secrets --for=condition=available --timeout=120s 2>/dev/null || \
  echo "⚠ ESO webhook not yet available"

# Wait until the webhook is actually accepting connections (cert provisioning delay)
echo "==> Waiting for ESO webhook to accept connections..."
for i in $(seq 1 30); do
  WEBHOOK_EP=$(kubectl --kubeconfig "$KB" get endpoints external-secrets-webhook \
    -n external-secrets -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
  if [ -n "$WEBHOOK_EP" ]; then
    echo "  ESO webhook endpoint ready: $WEBHOOK_EP"
    break
  fi
  echo "  Waiting for webhook endpoint ($i/30)..."
  sleep 10
done
# Extra buffer for TLS cert to propagate to the webhook pod
sleep 15

# Helper: retry kubectl apply from a file up to 5 times
kube_apply_retry() {
  local KB="$1"; local FILE="$2"
  for attempt in 1 2 3 4 5; do
    if kubectl --kubeconfig "$KB" apply -f "$FILE"; then return 0; fi
    echo "  attempt $attempt failed, retrying in 15s..."
    sleep 15
  done
  echo "⚠ apply failed after 5 attempts, continuing..."
  return 0
}

TMP1=$(mktemp); TMP2=$(mktemp); TMP3=$(mktemp); TMP4=$(mktemp)

# Create external-secrets namespace + openbao-token secret for ESO
kubectl --kubeconfig "$KB" create namespace external-secrets \
  --dry-run=client -o yaml > "$TMP1"
kube_apply_retry "$KB" "$TMP1"

kubectl --kubeconfig "$KB" create secret generic openbao-token \
  --namespace external-secrets \
  --from-literal=token="$SERVICE_TOKEN" \
  --dry-run=client -o yaml > "$TMP2"
kube_apply_retry "$KB" "$TMP2"

# Apply ClusterSecretStore pointing at in-cluster OpenBao
sed "s|OPENBAO_ADDR_PLACEHOLDER|$OPENBAO_ADDR|g; s|PLACEHOLDER_REPLACED_BY_TOFU|$SERVICE_TOKEN|g" \
  kubernetes/core/external-secrets/manifests/cluster-secret-store.yaml > "$TMP3"
kube_apply_retry "$KB" "$TMP3"

# Create apps-grafana namespace
kubectl --kubeconfig "$KB" create namespace apps-grafana \
  --dry-run=client -o yaml > "$TMP4"
kube_apply_retry "$KB" "$TMP4"
rm -f "$TMP1" "$TMP2" "$TMP3" "$TMP4"

# Create authentik namespace (smtp-secret is now managed by ESO from OpenBao)
kubectl --kubeconfig "$KB" create namespace authentik \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KB" apply -f - 2>/dev/null || true

# Apply ExternalSecret for Grafana (apps-grafana namespace)
TMP_ES=$(mktemp)
cat > "$TMP_ES" << 'ESEOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin-secret
  namespace: apps-grafana
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: grafana-admin-secret
    creationPolicy: Owner
  data:
    - secretKey: admin-password
      remoteRef:
        key: secret/platform/grafana
        property: admin-password
    - secretKey: admin-user
      remoteRef:
        key: secret/platform/grafana
        property: admin-user
ESEOF
kube_apply_retry "$KB" "$TMP_ES"
rm -f "$TMP_ES"

# ExternalSecret for monitoring namespace (kube-prometheus-stack grafana)
kubectl --kubeconfig "$KB" apply \
  -f kubernetes/core/external-secrets/manifests/grafana-externalsecret.yaml \
  2>/dev/null || true

# ClusterIssuer for cert-manager (if CRD is ready)
if kubectl --kubeconfig "$KB" get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  kubectl --kubeconfig "$KB" apply \
    -f kubernetes/core/cert-manager/manifests/cluster-issuer.yaml 2>/dev/null || true
  kubectl --kubeconfig "$KB" apply \
    -f kubernetes/core/cert-manager/manifests/external-secret-dns.yaml 2>/dev/null || true
fi

# Restore backed-up TLS secrets so cert-manager doesn't need to re-issue certs
# (avoids Let's Encrypt rate limits on full redeployments).
# The traefik namespace is created by ArgoCD deploying core-traefik; wait briefly.
BACKUP_DIR=/opt/platform-tls-backup
echo "==> Restoring TLS secrets from $BACKUP_DIR (if available)..."
for i in $(seq 1 12); do
  if kubectl --kubeconfig "$KB" get namespace traefik >/dev/null 2>&1; then break; fi
  echo "  Waiting for traefik namespace... ($i/12)"
  sleep 10
done
for secret_file in "$BACKUP_DIR"/*.yaml; do
  [ -f "$secret_file" ] || continue
  [ -s "$secret_file" ] || { echo "  ⚠ Skipping empty backup: $(basename $secret_file)"; continue; }
  SECRET_NAME=$(basename "$secret_file" .yaml)
  # Strip resource version and uid so kubectl apply doesn't conflict
  # Use python3+yaml (not jq) because backup files are YAML, not JSON
  # Script is base64-encoded to avoid YAML block-scalar indentation issues
  STRIP_PY=$(echo 'aW1wb3J0IHN5cywgeWFtbAp3aXRoIG9wZW4oc3lzLmFyZ3ZbMV0pIGFzIGY6CiAgICBkYXRhID0geWFtbC5zYWZlX2xvYWQoZikKZm9yIGtleSBpbiBbInJlc291cmNlVmVyc2lvbiIsICJ1aWQiLCAiY3JlYXRpb25UaW1lc3RhbXAiLCAibWFuYWdlZEZpZWxkcyJdOgogICAgZGF0YVsibWV0YWRhdGEiXS5wb3Aoa2V5LCBOb25lKQppZiAiYW5ub3RhdGlvbnMiIGluIGRhdGEuZ2V0KCJtZXRhZGF0YSIsIHt9KToKICAgIGRhdGFbIm1ldGFkYXRhIl1bImFubm90YXRpb25zIl0ucG9wKCJrdWJlY3RsLmt1YmVybmV0ZXMuaW8vbGFzdC1hcHBsaWVkLWNvbmZpZ3VyYXRpb24iLCBOb25lKQpwcmludCh5YW1sLmR1bXAoZGF0YSwgZGVmYXVsdF9mbG93X3N0eWxlPUZhbHNlKSkK' | base64 -d)
  python3 - "$secret_file" <<< "$STRIP_PY" | kubectl --kubeconfig "$KB" apply -f - 2>/dev/null && \
    echo "  ✅ Restored: $SECRET_NAME" || \
    echo "  ⚠ Could not restore $SECRET_NAME (cert-manager will issue fresh cert)"
done

echo "✅ OpenBao secrets bootstrapped"
kubectl --kubeconfig "$KB" get clustersecretstore openbao 2>/dev/null || \
  echo "  (ClusterSecretStore not yet synced)"

