#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/bootstrap-storage.sh — Bootstrap local-path-provisioner and wait for storage readiness
#
# Usage: ENV_NAME=productie bash scripts/deploy/bootstrap-storage.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
KB=~/.kube/config-platform-${ENV_NAME:?ENV_NAME required}
LOCAL_PATH_VERSION="v0.0.30"

# Install local-path-provisioner (idempotent)
curl -sL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
  | kubectl --kubeconfig "$KB" apply -f -

# Allow hostPath volumes in local-path-storage namespace (required by provisioner helper pods)
kubectl --kubeconfig "$KB" label namespace local-path-storage \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite

# Allow monitoring namespace to run privileged initContainers (prometheus chown fix)
kubectl --kubeconfig "$KB" label namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite 2>/dev/null || true

# Allow apps-grafana namespace (initChownData requires CAP_CHOWN, needs baseline+)
kubectl --kubeconfig "$KB" create namespace apps-grafana 2>/dev/null || true
kubectl --kubeconfig "$KB" label namespace apps-grafana \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite 2>/dev/null || true

# Allow metallb-system namespace (speaker needs NET_RAW + hostNetwork + hostPorts)
kubectl --kubeconfig "$KB" create namespace metallb-system 2>/dev/null || true
kubectl --kubeconfig "$KB" label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite 2>/dev/null || true

# Allow longhorn-system namespace (manager needs hostPath + privileged + hostNetwork)
kubectl --kubeconfig "$KB" create namespace longhorn-system 2>/dev/null || true
kubectl --kubeconfig "$KB" label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite 2>/dev/null || true

# Set local-path as the default StorageClass
kubectl --kubeconfig "$KB" patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || true

echo "✅ local-path-provisioner bootstrapped"
kubectl --kubeconfig "$KB" get storageclass
kubectl --kubeconfig "$KB" get pods -n local-path-storage

# Apply grafana-eligible label to nodes that are safe for Grafana scheduling
# (cp1 is excluded due to Docker Hub connectivity issues)
for node in talos-prod-cp2 talos-prod-cp3; do
  kubectl --kubeconfig "$KB" label node "$node" grafana-eligible=true --overwrite 2>/dev/null || true
done
echo "✅ Node labels applied"

