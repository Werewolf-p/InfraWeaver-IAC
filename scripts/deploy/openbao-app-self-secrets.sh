#!/usr/bin/env bash
# openbao-app-self-secrets.sh — give an app read/write access to its OWN bucket in
# OpenBao, and only its own.
#
# ─────────────────────────────────────────────────────────────────────────────
# The pattern
# ─────────────────────────────────────────────────────────────────────────────
# Apps authenticate to OpenBao with their pod's Kubernetes ServiceAccount (no
# static token to leak). A single *templated* policy scopes every authenticated
# app to a path keyed by its own ServiceAccount namespace:
#
#     secret/private/<namespace>            (+ /* beneath it)
#
# Because the path is derived from the caller's identity by OpenBao itself, an app
# physically cannot read or write another app's bucket — isolation is enforced
# server-side, not by trusting the client. tradesphere, in namespace "tradesphere",
# gets secret/private/tradesphere — exactly where its ESO ExternalSecrets already
# read the anthropic + binance keys from.
#
# This script is idempotent and reusable. Run it once with no args to install the
# shared auth method + policy, then once per app to register that app's role:
#
#     scripts/deploy/openbao-app-self-secrets.sh                       # base only
#     scripts/deploy/openbao-app-self-secrets.sh tradesphere tradesphere-api
#     scripts/deploy/openbao-app-self-secrets.sh <namespace> <service-account> [role]
#
# It talks to OpenBao over a short-lived local port-forward, with the root token
# pulled from the openbao-unseal Secret. The token stays in this process's memory
# (never argv, never a file).
#
# Prereq: the openbao ServiceAccount must hold system:auth-delegator so OpenBao can
# call the TokenReview API. That ClusterRoleBinding lives in
# kubernetes/core/openbao/manifests/rbac.yaml.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-platform-productie}"
export KUBECONFIG
OPENBAO_NS="${OPENBAO_NS:-openbao}"
POLICY_NAME="app-self-secrets"
AUTH_PATH="kubernetes"

APP_NS="${1:-}"
APP_SA="${2:-}"
ROLE="${3:-${APP_NS}}"

log() { printf '\033[36m[openbao-self]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[openbao-self] %s\033[0m\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "missing tool: $1"; exit 1; }; }
need kubectl; need python3; need curl

ROOT_TOKEN="$(kubectl -n "$OPENBAO_NS" get secret openbao-unseal -o jsonpath='{.data.root_token}' | base64 -d)"
[ -n "$ROOT_TOKEN" ] || { err "could not read OpenBao root token from openbao-unseal secret"; exit 1; }

# Short-lived local port-forward to OpenBao (the pod image has no curl).
PF_PORT="${PF_PORT:-18200}"
kubectl -n "$OPENBAO_NS" port-forward svc/openbao "${PF_PORT}:8200" >/tmp/obao-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:${PF_PORT}/v1/sys/health" && break || sleep 0.5
done
BASE="http://127.0.0.1:${PF_PORT}/v1"

# obao METHOD PATH  — body (if any) on stdin; prints response body.
obao() {
  local method="$1" path="$2"
  if [ "$method" = GET ]; then
    curl -s -H "X-Vault-Token: $ROOT_TOKEN" "${BASE}/${path}"
  else
    curl -s -X "$method" -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" --data @- "${BASE}/${path}"
  fi
}

# ── 1. enable kubernetes auth (idempotent) ───────────────────────────────────
log "ensuring kubernetes auth method is enabled…"
printf '{"type":"kubernetes"}' | obao POST "sys/auth/${AUTH_PATH}" >/dev/null 2>&1 || true

# ── 2. configure it to use the in-cluster API + OpenBao's own SA as reviewer ──
# kubernetes_host is the in-cluster API; with disable_local_ca_jwt=false (default)
# OpenBao uses its own mounted CA + SA token to call TokenReview.
log "configuring kubernetes auth (host=https://kubernetes.default.svc)…"
printf '{"kubernetes_host":"https://kubernetes.default.svc"}' \
  | obao POST "auth/${AUTH_PATH}/config" >/dev/null

# ── 3. discover the auth mount accessor (templated policy keys off it) ────────
ACCESSOR=$(obao GET "sys/auth" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['${AUTH_PATH}/']['accessor'])")
[ -n "$ACCESSOR" ] || { err "could not resolve ${AUTH_PATH}/ auth accessor"; exit 1; }
log "auth accessor: $ACCESSOR"

# ── 4. install the templated self-scoping policy ─────────────────────────────
# {{...service_account_namespace}} resolves, per request, to the caller's own
# namespace — so every app is confined to secret/private/<its-namespace>.
NS_TMPL="{{identity.entity.aliases.${ACCESSOR}.metadata.service_account_namespace}}"
read -r -d '' POLICY_HCL <<EOF || true
path "secret/data/private/${NS_TMPL}" {
  capabilities = ["create", "read", "update", "patch"]
}
path "secret/data/private/${NS_TMPL}/*" {
  capabilities = ["create", "read", "update", "patch"]
}
path "secret/metadata/private/${NS_TMPL}" {
  capabilities = ["read", "list"]
}
path "secret/metadata/private/${NS_TMPL}/*" {
  capabilities = ["read", "list"]
}
EOF
log "writing templated policy '${POLICY_NAME}'…"
python3 -c 'import json,sys;print(json.dumps({"policy":sys.stdin.read()}))' <<<"$POLICY_HCL" \
  | obao PUT "sys/policies/acl/${POLICY_NAME}" >/dev/null

# ── 5. register the app role (only when an app was named) ─────────────────────
if [ -z "$APP_NS" ] || [ -z "$APP_SA" ]; then
  log "base auth + policy installed. Re-run with <namespace> <service-account> to register an app."
  exit 0
fi
log "registering role '${ROLE}' → SA ${APP_NS}/${APP_SA} bound to '${POLICY_NAME}'…"
python3 - "$APP_SA" "$APP_NS" "$POLICY_NAME" <<'PY' | obao POST "auth/${AUTH_PATH}/role/${ROLE}" >/dev/null
import json, sys
sa, ns, pol = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "bound_service_account_names": [sa],
    "bound_service_account_namespaces": [ns],
    "token_policies": [pol],
    "token_ttl": "20m",
    "token_max_ttl": "1h",
}))
PY
log "done. ${APP_NS}/${APP_SA} may now read+write secret/private/${APP_NS} (and nothing else)."
