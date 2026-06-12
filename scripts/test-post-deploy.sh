#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/test-post-deploy.sh — InfraWeaver Platform Post-Deploy Test Suite
#
# Runs after a full redeploy to verify all critical services are healthy.
# Usage: bash scripts/test-post-deploy.sh [KUBECONFIG_PATH] [ENV_NAME]
#
# Returns exit code 0 if all mandatory tests pass, 1 if any fail.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_NAME="test-post-deploy"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -uo pipefail  # restore: test suite intentionally allows non-zero exits

KB="${1:-$HOME/.kube/config-platform-productie}"
ENV="${2:-productie}"
BASE_DOMAIN="${BASE_DOMAIN:-yourdomain.com}"
PUBLIC_TLS_SECRET="${BASE_DOMAIN//./-}-wildcard-tls"
INTERNAL_TLS_SECRET="int-${BASE_DOMAIN//./-}-tls"

PASS=0
FAIL=0
WARN=0
RESULTS=()

ok()   { PASS=$((PASS+1));  RESULTS+=("✅ PASS  $1"); echo "✅ PASS  $1"; }
fail() { FAIL=$((FAIL+1));  RESULTS+=("❌ FAIL  $1"); echo "❌ FAIL  $1"; }
warn() { WARN=$((WARN+1));  RESULTS+=("⚠️  WARN  $1"); echo "⚠️  WARN  $1"; }

# HTTP check — accepts any 2xx/3xx as pass
http_check() {
  local name="$1" url="$2"
  local actual
  actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$url" 2>/dev/null)
  if [[ "$actual" =~ ^[23] ]]; then
    ok "$name ($url → HTTP $actual)"
  else
    fail "$name ($url → HTTP $actual)"
  fi
}

# HTTP must NOT be reachable (expects 000 = connection refused / no route)
http_must_not_reach() {
  local name="$1" url="$2"
  local actual
  actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  if [ "$actual" = "000" ]; then
    ok "$name — not publicly reachable (as expected)"
  else
    warn "$name returned HTTP $actual from public internet — check VPN restriction"
  fi
}

# ArgoCD app health check
argocd_app() {
  local name="$1" appname="$2"
  local health sync
  health=$(kubectl --kubeconfig "$KB" get application "$appname" -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
  sync=$(kubectl --kubeconfig "$KB" get application "$appname" -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
  if [ "$health" = "Healthy" ]; then
    ok "$name (ArgoCD: $appname health=$health sync=$sync)"
  elif [ "$health" = "NotFound" ]; then
    fail "$name (ArgoCD app $appname not found)"
  else
    warn "$name (ArgoCD: $appname health=$health sync=$sync)"
  fi
}

# K8s deployment readiness
deployment_ready() {
  local name="$1" ns="$2" deploy="$3"
  local ready
  ready=$(kubectl --kubeconfig "$KB" get deployment "$deploy" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${ready:-0}" -ge 1 ]; then
    ok "$name (deployment $deploy in $ns: $ready ready)"
  else
    fail "$name (deployment $deploy in $ns: readyReplicas=${ready:-0})"
  fi
}

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  InfraWeaver Post-Deploy Test Suite — env: $ENV"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 1. Kubernetes Cluster ────────────────────────────────────────────────────
echo "── Cluster ──────────────────────────────────────────────────"
NODE_COUNT=$(kubectl --kubeconfig "$KB" get nodes --no-headers 2>/dev/null | wc -l || echo 0)
READY_COUNT=$(kubectl --kubeconfig "$KB" get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
if [ "${READY_COUNT:-0}" -ge "${NODE_COUNT:-1}" ]; then
  ok "Cluster nodes ($READY_COUNT/$NODE_COUNT Ready)"
else
  fail "Cluster nodes ($READY_COUNT/$NODE_COUNT Ready)"
fi

# ── 2. Core Services ─────────────────────────────────────────────────────────
echo "── Core Services ────────────────────────────────────────────"
deployment_ready "ExternalSecrets operator" "external-secrets" "external-secrets"
deployment_ready "Traefik running"        "traefik"          "traefik"
deployment_ready "Authentik server"       "authentik"        "authentik-server"
deployment_ready "Authentik worker"       "authentik"        "authentik-worker"
deployment_ready "ArgoCD server"          "argocd"           "argocd-server"

# OpenBao is a StatefulSet — check pod readiness directly
OPENBAO_READY=$(kubectl --kubeconfig "$KB" get pod openbao-0 -n openbao \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
[ "$OPENBAO_READY" = "True" ] && ok "OpenBao pod ready" || fail "OpenBao pod not ready (status=$OPENBAO_READY)"
BAO_STATUS=$(kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null | \
  python3 -c "import sys,json; s=json.load(sys.stdin); print('sealed' if s.get('sealed') else 'unsealed')" 2>/dev/null || echo "unreachable")
if [ "$BAO_STATUS" = "unsealed" ]; then
  ok "OpenBao status (unsealed)"
elif [ "$BAO_STATUS" = "sealed" ]; then
  fail "OpenBao status (sealed — secrets unavailable)"
else
  fail "OpenBao status ($BAO_STATUS)"
fi

# ── 3. ArgoCD Application Health ─────────────────────────────────────────────
echo "── ArgoCD Application Health ────────────────────────────────"
argocd_app "core-openbao"       "core-openbao"
argocd_app "core-cert-manager"  "core-cert-manager"
argocd_app "core-traefik"       "core-traefik"
argocd_app "core-argocd"        "core-argocd"
argocd_app "apps-authentik"     "apps-authentik-manifests"
argocd_app "external-routes"    "external-routes"
argocd_app "apps-dns"           "apps-dns"
# apps-homepage is optional — only warn if missing
  health_hp=$(kubectl --kubeconfig "$KB" get application apps-homepage -n argocd -o jsonpath="{.status.health.status}" 2>/dev/null || echo "NotFound")
  if [ "$health_hp" = "NotFound" ]; then warn "apps-homepage (not deployed — optional)"; elif [ "$health_hp" = "Healthy" ]; then ok "apps-homepage (ArgoCD: Healthy)"; else warn "apps-homepage (ArgoCD: $health_hp)"; fi

# ── 4. Public URLs ────────────────────────────────────────────────────────────
echo "── Public URLs ──────────────────────────────────────────────"
http_check "Authentik login page"     "https://auth.${BASE_DOMAIN}/"
http_check "Authentik admin page"     "https://auth.${BASE_DOMAIN}/if/admin/"
http_check "Recovery flow endpoint"   "https://auth.${BASE_DOMAIN}/if/flow/default-recovery-flow/"


# ── 5. OIDC Discovery (public — required for SSO) ────────────────────────────
echo "── OIDC Discovery Endpoints ─────────────────────────────────"
ARGOCD_ISSUER=$(curl -s --max-time 15 \
  "https://auth.${BASE_DOMAIN}/application/o/argocd/.well-known/openid-configuration" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer','MISSING'))" 2>/dev/null || echo "UNREACHABLE")
if echo "$ARGOCD_ISSUER" | grep -q "argocd"; then
  ok "ArgoCD OIDC discovery (issuer: $ARGOCD_ISSUER)"
else
  fail "ArgoCD OIDC discovery ($ARGOCD_ISSUER)"
fi

OPENBAO_ISSUER=$(curl -s --max-time 15 \
  "https://auth.${BASE_DOMAIN}/application/o/openbao/.well-known/openid-configuration" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer','MISSING'))" 2>/dev/null || echo "UNREACHABLE")
if echo "$OPENBAO_ISSUER" | grep -q "openbao"; then
  ok "OpenBao OIDC discovery (issuer: $OPENBAO_ISSUER)"
else
  fail "OpenBao OIDC discovery ($OPENBAO_ISSUER)"
fi

# ── 6. SSO Configuration ─────────────────────────────────────────────────────
echo "── SSO Configuration ────────────────────────────────────────"
ARGOCD_OIDC_LEN=$(kubectl --kubeconfig "$KB" get secret argocd-secret -n argocd \
  -o jsonpath='{.data.oidc\.authentik\.clientSecret}' 2>/dev/null | base64 -d | wc -c || echo 0)
if [ "${ARGOCD_OIDC_LEN:-0}" -gt 10 ]; then
  ok "ArgoCD OIDC client_secret set (${ARGOCD_OIDC_LEN} chars)"
else
  fail "ArgoCD OIDC client_secret missing"
fi

ROOT_TOKEN=$(kubectl --kubeconfig "$KB" get secret openbao-unseal -n openbao \
  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
if [ -n "$ROOT_TOKEN" ]; then
  OIDC_AUTH=$(kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" \
    bao auth list -format=json 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); print('ok' if 'oidc/' in a else 'missing')" 2>/dev/null || echo "error")
  [ "$OIDC_AUTH" = "ok" ] && ok "OpenBao OIDC auth method enabled" || fail "OpenBao OIDC auth method ($OIDC_AUTH)"

  OIDC_CLAIM=$(kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" \
    bao read auth/oidc/role/default -format=json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('user_claim','missing'))" 2>/dev/null || echo "missing")
  [ "$OIDC_CLAIM" = "preferred_username" ] && ok "OpenBao OIDC role configured (user_claim: $OIDC_CLAIM)" || fail "OpenBao OIDC role misconfigured (user_claim: $OIDC_CLAIM)"
else
  warn "OpenBao root token unavailable — skipping OIDC verification"
fi

# ── 7. TLS Secrets (check secrets, not cert objects — certs may be rate-limited) ──
echo "── TLS Secrets ──────────────────────────────────────────────"
for secret in "$PUBLIC_TLS_SECRET" "$INTERNAL_TLS_SECRET"; do
  SECRET_TYPE=$(kubectl --kubeconfig "$KB" get secret "$secret" -n traefik \
    -o jsonpath='{.type}' 2>/dev/null || echo "missing")
  if [ "$SECRET_TYPE" = "kubernetes.io/tls" ]; then
    EXPIRY=$(kubectl --kubeconfig "$KB" get secret "$secret" -n traefik \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | \
      openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
    ok "TLS secret $secret exists (expires: $EXPIRY)"
  elif [ "$SECRET_TYPE" = "missing" ]; then
    # Check cert object status for better error message
    CERT_STATUS=$(kubectl --kubeconfig "$KB" get certificate "$secret" -n traefik \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "cert not found")
    if echo "$CERT_STATUS" | grep -qi "rate\|limit\|429"; then
      warn "TLS secret $secret missing (rate-limited by Let's Encrypt — will resolve automatically)"
    else
      warn "TLS secret $secret missing ($CERT_STATUS)"
    fi
  fi
done

# ── 8. Security: VPN-Only Access Enforcement ─────────────────────────────────
echo "── Security: VPN-Only Enforcement ──────────────────────────"
http_must_not_reach "argocd.int.${BASE_DOMAIN}" "https://argocd.int.${BASE_DOMAIN}/"
http_must_not_reach "argocd.${BASE_DOMAIN} (public)" "https://argocd.${BASE_DOMAIN}/"
http_must_not_reach "openbao.int.${BASE_DOMAIN}" "https://openbao.int.${BASE_DOMAIN}/"

# ── 9. ArgoCD OIDC redirect URI matches int domain ───────────────────────────
echo "── ArgoCD OIDC Config ───────────────────────────────────────"
# ArgoCD global.domain drives the OIDC callback URL — should be argocd.int.${BASE_DOMAIN}
ARGOCD_DOMAIN=$(kubectl --kubeconfig "$KB" get configmap argocd-cm -n argocd \
  -o jsonpath='{.data.url}' 2>/dev/null || echo "")
if [ -z "$ARGOCD_DOMAIN" ]; then
  # Fall back: check if OIDC config is present at all
  ARGOCD_CM_OIDC=$(kubectl --kubeconfig "$KB" get configmap argocd-cm -n argocd \
    -o jsonpath='{.data.oidc\.config}' 2>/dev/null || echo "")
  if echo "$ARGOCD_CM_OIDC" | grep -q "argocd"; then
    ok "ArgoCD OIDC config present (issuer configured)"
  else
    fail "ArgoCD OIDC config not found in argocd-cm"
  fi
elif echo "$ARGOCD_DOMAIN" | grep -q "argocd.int.${BASE_DOMAIN}"; then
  ok "ArgoCD url configured: $ARGOCD_DOMAIN"
else
  warn "ArgoCD url is '$ARGOCD_DOMAIN' (expected argocd.int.${BASE_DOMAIN})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: ✅ $PASS passed  ❌ $FAIL failed  ⚠️  $WARN warnings"
echo "═══════════════════════════════════════════════════════════"
echo ""
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "❌ Test suite FAILED ($FAIL failures)"
  exit 1
else
  echo "✅ Test suite PASSED ($PASS passed, $WARN warnings)"
  exit 0
fi
