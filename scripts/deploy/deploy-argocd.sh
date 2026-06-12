#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/deploy-argocd.sh — Deploy ArgoCD and apply bootstrap ApplicationSets
#
# Usage: ENV_NAME=productie bash scripts/deploy/deploy-argocd.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ENV=${ENV_NAME:?ENV_NAME required}
KB=~/.kube/config-platform-$ENV

if [ ! -s "$KB" ]; then
  cd terraform
  tofu output -raw kubeconfig > "$KB" 2>/dev/null || true
  chmod 600 "$KB"
  cd ..
fi

kubectl --kubeconfig "$KB" create namespace argocd --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB" apply -f -

# Apply PriorityClasses early to prevent chicken-and-egg with ArgoCD application-controller
# (ArgoCD manifests reference platform-critical, but that class is deployed via ArgoCD)
PRIORITY_MANIFEST="${BASH_SOURCE[0]%/scripts/*}/kubernetes/core/priority-classes/manifests/priority-classes.yaml"
if [[ -f "$PRIORITY_MANIFEST" ]]; then
  kubectl --kubeconfig "$KB" apply -f "$PRIORITY_MANIFEST" 2>/dev/null || true
fi

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

# Patch any pre-existing ArgoCD resources for Helm ownership
for rtype in serviceaccount role rolebinding clusterrole clusterrolebinding \
    configmap secret service networkpolicy deployment statefulset; do
  for item in $(kubectl --kubeconfig "$KB" get $rtype -n argocd \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^argocd" || true); do
    kubectl --kubeconfig "$KB" annotate $rtype/$item -n argocd \
      "meta.helm.sh/release-name=argocd" \
      "meta.helm.sh/release-namespace=argocd" --overwrite 2>/dev/null || true
    kubectl --kubeconfig "$KB" label $rtype/$item -n argocd \
      "app.kubernetes.io/managed-by=Helm" --overwrite 2>/dev/null || true
  done
done
for rtype in clusterrole clusterrolebinding; do
  for item in $(kubectl --kubeconfig "$KB" get $rtype \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^argocd" || true); do
    kubectl --kubeconfig "$KB" annotate $rtype/$item \
      "meta.helm.sh/release-name=argocd" \
      "meta.helm.sh/release-namespace=argocd" --overwrite 2>/dev/null || true
    kubectl --kubeconfig "$KB" label $rtype/$item \
      "app.kubernetes.io/managed-by=Helm" --overwrite 2>/dev/null || true
  done
done

helm --kubeconfig "$KB" upgrade --install argocd argo/argo-cd \
  --namespace argocd --skip-crds --timeout 10m --no-hooks \
  -f kubernetes/core/argocd/values.yaml

kubectl --kubeconfig "$KB" patch svc argocd-repo-server -n argocd \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8081}]' 2>/dev/null || true
kubectl --kubeconfig "$KB" patch svc argocd-dex-server -n argocd \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":5556},{"op":"replace","path":"/spec/ports/1/targetPort","value":5557}]' 2>/dev/null || true
kubectl --kubeconfig "$KB" patch svc argocd-applicationset-controller -n argocd \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":7000}]' 2>/dev/null || true
kubectl --kubeconfig "$KB" patch svc argocd-redis -n argocd \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":6379}]' 2>/dev/null || true

REPO_TOKEN="${ARGOCD_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "$REPO_TOKEN" ]]; then
  kubectl --kubeconfig "$KB" create secret generic repo-creds-github \
    --namespace argocd \
    --from-literal=url="https://github.com/${GITHUB_ORG:-your-org}/" \
    --from-literal=username="x-access-token" \
    --from-literal=password="${REPO_TOKEN}" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KB" apply -f -
  kubectl --kubeconfig "$KB" label secret repo-creds-github --namespace argocd \
    "argocd.argoproj.io/secret-type=repo-creds" --overwrite
else
  echo "⚠️  No GITHUB_TOKEN / ARGOCD_GITHUB_TOKEN set — skipping repo-creds-github secret (ArgoCD will use public/SSH access)"
fi

# Apply bootstrap manifests with env-specific revision so ArgoCD tracks the correct branch
GIT_REVISION="$( [ "${ENV_NAME}" = "productie" ] && echo "main" || echo "ontwikkel" )"
for f in kubernetes/bootstrap/*.yaml; do
  sed "s|targetRevision: HEAD|targetRevision: ${GIT_REVISION}|g" "$f" \
    | kubectl --kubeconfig "$KB" apply --server-side --force-conflicts -f -
done

kubectl --kubeconfig "$KB" wait --for=condition=available \
  deployment/argocd-server -n argocd --timeout=180s || true

# Restart argocd-repo-server in case it started before CoreDNS was ready
kubectl --kubeconfig "$KB" rollout restart deployment/argocd-repo-server -n argocd 2>/dev/null || true
kubectl --kubeconfig "$KB" rollout status deployment/argocd-repo-server -n argocd --timeout=120s 2>/dev/null || true

echo "✅ ArgoCD deployed & bootstrapped"
kubectl --kubeconfig "$KB" get pods -n argocd
kubectl --kubeconfig "$KB" get applicationsets,appprojects -n argocd 2>/dev/null || true

# Clean up any stale public ArgoCD ingress (not tracked by ArgoCD, may survive redeploy)
kubectl --kubeconfig "$KB" delete ingress argocd-server-platform -n argocd 2>/dev/null \
  && echo "🧹 Removed stale argocd-server-platform ingress" \
  || echo "  argocd-server-platform ingress not present (expected)"

