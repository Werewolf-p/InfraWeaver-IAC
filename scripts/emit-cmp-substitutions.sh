#!/usr/bin/env bash
# emit-cmp-substitutions.sh — render the argocd-cmp-substitutions ConfigMap from
# .env using an EXPLICIT config-key allowlist, and apply it (design §4a, §5.2).
#
# Why an allowlist (not "everything in .env"): the CMP sidecar substitutes these
# values into manifests at sync time. A secret key accidentally present in .env
# must NEVER reach this ConfigMap, so we copy ONLY the names listed below. Secrets
# keep flowing through OpenBao + ESO. Run at the DR rebuild, before app-of-apps.
#
#   scripts/emit-cmp-substitutions.sh           # print the ConfigMap to stdout
#   scripts/emit-cmp-substitutions.sh --apply   # kubectl apply it to the cluster
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env}"

# Config-class keys ONLY. Adding a key here means "safe to expose in manifests".
ALLOWED_KEYS=(
  BASE_DOMAIN DEPLOY_REPO_URL ONEDEV_URL
  METALLB_TRAEFIK_VIP METALLB_COREDNS_VIP METALLB_VLAN3_POOL_RANGE PUBLIC_INGRESS_IP
  MGMT_SUBNET_CIDR NODE_SUBNET_CIDR
  GITHUB_REPO ADMIN_EMAIL TRUENAS_HOST TARGET_REPLICAS
)
# Defence in depth: refuse to emit any key whose name looks secret-class.
DENY_RE='PASSWORD|TOKEN|SECRET|KEY|LOGIN|CREDENTIAL'

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE" >&2; exit 1; }

declare -A ENV
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
  k="${line%%=*}"; v="${line#*=}"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  ENV["$k"]="$v"
done < "$ENV_FILE"

{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: argocd-cmp-substitutions"
  echo "  namespace: argocd"
  echo "  labels:"
  echo "    app.kubernetes.io/part-of: argocd"
  echo "data:"
  for k in "${ALLOWED_KEYS[@]}"; do
    if [[ "$k" =~ $DENY_RE ]]; then
      echo "refusing to emit secret-class key: $k" >&2; exit 1
    fi
    printf '  %s: "%s"\n' "$k" "${ENV[$k]:-}"
  done
} > /tmp/argocd-cmp-substitutions.yaml

if [[ "${1:-}" == "--apply" ]]; then
  kubectl apply -f /tmp/argocd-cmp-substitutions.yaml
else
  cat /tmp/argocd-cmp-substitutions.yaml
fi
