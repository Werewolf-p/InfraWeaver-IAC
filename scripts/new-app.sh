#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# new-app.sh — Scaffold a new Kubernetes app for ArgoCD auto-discovery
#
# USAGE:
#   bash scripts/new-app.sh <app-name> [options]
#
# OPTIONS:
#   --tier <tier>          Tier to place the app in (default: apps)
#                          Valid: apps | core | monitoring | platform
#   --helm <repo> <chart>  Helm chart mode: create application.yaml + values.yaml
#   --manifest-only        Skip bootstrap file creation
#   --auth                 Protect with Authentik (any logged-in user)
#   --auth-admin           Protect with Authentik (platform-admins group only)
#   --auth-sso             App uses native OIDC/SSO (generates config skeleton)
#   --public               No auth — world-accessible ⚠️
#
# AUTH MODES:
#   (default)    → Authentik forward-auth, platform-admins group required
#                  Label: infraweaver.io/auth=admin
#   --auth       → Authentik proxy (any logged-in Authentik user)
#                  Label: infraweaver.io/auth=proxy
#   --auth-admin → Authentik proxy + platform-admins group required
#                  Label: infraweaver.io/auth=admin
#   --auth-sso   → App speaks OIDC natively, generates oidc-config.yaml.example
#                  Label: infraweaver.io/auth=sso
#   --public     → No auth, world-accessible
#                  Label: infraweaver.io/auth=public
#
# View auth status for all apps:  kubectl get deploy -A -L infraweaver.io/auth
#
# EXAMPLES:
#   bash scripts/new-app.sh my-service
#   bash scripts/new-app.sh my-service --auth
#   bash scripts/new-app.sh my-service --auth-admin
#   bash scripts/new-app.sh my-service --public
#   bash scripts/new-app.sh my-service --helm https://charts.bitnami.com/bitnami redis
#   bash scripts/new-app.sh my-service --tier platform
#
# See: docs/MIDDLEWARES.md for all available Traefik middlewares
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="new-app"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
fail() { echo -e "${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $*${NC}"; }

# ── Helper: generate auth-protected IngressRoute ──────────────────────────────
_generate_auth_ingressroute() {
  local app="$1"
  local dir="$2"
  local middleware="$3"
  local auth_label="$4"

  cat > "${dir}/manifests/ingressroute-auth.yaml" << EOF
---
# Auth-protected IngressRoute for ${app}
# Middleware: ${middleware}
# Auth label: infraweaver.io/auth=${auth_label}
# View all auth labels: kubectl get deploy -A -L infraweaver.io/auth
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ${app}-auth
  namespace: apps-${app}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`${app}.${BASE_DOMAIN}\`)
      kind: Rule
      middlewares:
        - name: secure-headers
          namespace: traefik
        - name: ${middleware}
          namespace: traefik
      services:
        - name: ${app}
          port: 80
  tls:
    secretName: ${app}-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${app}-tls
  namespace: apps-${app}
spec:
  secretName: ${app}-tls
  issuerRef:
    name: letsencrypt-dns
    kind: ClusterIssuer
  dnsNames:
    - ${app}.${BASE_DOMAIN}
EOF
}

# ── Helper: generate OIDC config skeleton for SSO apps ───────────────────────
_generate_sso_config() {
  local app="$1"
  local dir="$2"

  cat > "${dir}/manifests/oidc-config.yaml.example" << EOF
# OIDC / SSO Configuration for ${app}
#
# This app uses infraweaver.io/auth=sso — it speaks OIDC natively.
# Configure your app with the following Authentik OIDC provider settings:
#
# Authentik setup:
#   1. Applications → Providers → Create → OAuth2/OpenID Connect Provider
#   2. Set:
#        Name:          ${app}
#        Client type:   Confidential
#        Redirect URIs: https://${app}.${BASE_DOMAIN}/callback
#        Signing Key:   authentik Self-signed Certificate
#   3. Create an Application linked to this Provider
#   4. Copy Client ID + Client Secret into your app's config/secret
#
# Authentik OIDC endpoints:
#   Discovery:  https://auth.${BASE_DOMAIN}/application/o/${app}/.well-known/openid-configuration
#   Auth:       https://auth.${BASE_DOMAIN}/application/o/authorize/
#   Token:      https://auth.${BASE_DOMAIN}/application/o/token/
#   UserInfo:   https://auth.${BASE_DOMAIN}/application/o/userinfo/
#
# Store credentials in OpenBao:
#   secret/platform/apps/${app}  →  oidc-client-id, oidc-client-secret
# Then reference via ExternalSecret (see docs/templates/app/externalsecret.yaml.example)
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
APP_NAME=${1:-}
TIER="apps"
MODE="manifest"   # manifest | helm | manifest-only
AUTH_MODE="admin" # admin | proxy | sso | public
CHART_REPO=""
CHART_NAME=""

if [ -z "$APP_NAME" ]; then
  echo -e "${BOLD}USAGE:${NC} bash scripts/new-app.sh <app-name> [--tier <tier>] [--auth|--auth-admin|--auth-sso|--public] [--helm <repo> <chart>] [--manifest-only]"
  exit 1
fi

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      TIER="${2:-apps}"; shift 2 ;;
    --helm)
      MODE="helm"
      CHART_REPO="${2:-https://charts.example.com}"
      CHART_NAME="${3:-$APP_NAME}"
      shift 3 ;;
    --manifest-only)
      MODE="manifest-only"; shift ;;
    --auth)
      AUTH_MODE="proxy"; shift ;;
    --auth-admin)
      AUTH_MODE="admin"; shift ;;
    --auth-sso)
      AUTH_MODE="sso"; shift ;;
    --public)
      AUTH_MODE="public"; shift ;;
    *)
      fail "Unknown option: $1" ;;
  esac
done

# Validate tier
case "$TIER" in
  apps|core|monitoring|platform) ;;
  *) fail "Invalid tier '${TIER}'. Must be: apps | core | monitoring | platform" ;;
esac

# Resolve auth label and description
case "$AUTH_MODE" in
  proxy)  AUTH_LABEL="proxy";  AUTH_DESC="Authentik proxy (any logged-in user)" ;;
  admin)  AUTH_LABEL="admin";  AUTH_DESC="Authentik proxy (platform-admins group only)" ;;
  sso)    AUTH_LABEL="sso";    AUTH_DESC="Native OIDC/SSO (app handles auth natively)" ;;
  public) AUTH_LABEL="public"; AUTH_DESC="No auth — world-accessible ⚠️" ;;
esac

TEMPLATE_DIR="docs/templates/app"
TARGET_DIR="kubernetes/${TIER}/${APP_NAME}"
BOOTSTRAP_FILE="kubernetes/bootstrap/app-${APP_NAME}.yaml"

if [ ! -d "$TEMPLATE_DIR" ]; then
  fail "Template directory not found: ${TEMPLATE_DIR} — run this script from the repo root"
fi

if [ -d "$TARGET_DIR" ]; then
  fail "Directory ${TARGET_DIR} already exists — app '${APP_NAME}' already scaffolded"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   InfraWeaver — Scaffolding New App                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "App name : ${APP_NAME}"
info "Tier     : ${TIER}"
info "Mode     : ${MODE}"
info "Auth     : ${AUTH_DESC}"
info "Target   : ${TARGET_DIR}/"
echo ""

# ── Copy manifests from template ─────────────────────────────────────────────
mkdir -p "${TARGET_DIR}/manifests"

for tmpl_file in "${TEMPLATE_DIR}/manifests/"*; do
  filename=$(basename "$tmpl_file")
  dest="${TARGET_DIR}/manifests/${filename}"
  sed "s/APP_NAME/${APP_NAME}/g" "$tmpl_file" > "$dest"
  ok "Created ${dest}"
done

# ── Patch deployment.yaml with auth label ────────────────────────────────────
DEPLOY_FILE="${TARGET_DIR}/manifests/deployment.yaml"
if [ -f "$DEPLOY_FILE" ]; then
  # Add infraweaver.io/auth label alongside the existing app label (both locations)
  sed -i "s/^    app: ${APP_NAME}$/    app: ${APP_NAME}\n    infraweaver.io\/auth: ${AUTH_LABEL}/" "$DEPLOY_FILE"
  ok "Patched deployment.yaml — added label infraweaver.io/auth=${AUTH_LABEL}"
fi

# ── Generate IngressRoute based on auth mode ─────────────────────────────────
case "$AUTH_MODE" in
  proxy)
    _generate_auth_ingressroute "$APP_NAME" "$TARGET_DIR" "forward-auth" "proxy"
    ok "Generated ingressroute-auth.yaml (Authentik proxy: any logged-in user)"
    ;;
  admin)
    _generate_auth_ingressroute "$APP_NAME" "$TARGET_DIR" "forward-auth-admin" "admin"
    ok "Generated ingressroute-auth.yaml (Authentik proxy: platform-admins only)"
    ;;
  sso)
    if [ -f "${TARGET_DIR}/manifests/ingressroute-internal.yaml.example" ]; then
      mv "${TARGET_DIR}/manifests/ingressroute-internal.yaml.example" \
         "${TARGET_DIR}/manifests/ingressroute-internal.yaml"
    fi
    _generate_sso_config "$APP_NAME" "$TARGET_DIR"
    ok "Activated ingressroute-internal.yaml + generated oidc-config.yaml.example"
    ;;
  public)
    if [ -f "${TARGET_DIR}/manifests/ingressroute-public.yaml.example" ]; then
      mv "${TARGET_DIR}/manifests/ingressroute-public.yaml.example" \
         "${TARGET_DIR}/manifests/ingressroute-public.yaml"
      ok "Activated ingressroute-public.yaml (⚠️  no auth — world-accessible)"
    fi
    ;;
esac

# ── Helm chart files ──────────────────────────────────────────────────────────
if [[ "$MODE" == "helm" ]]; then
  sed \
    -e "s|APP_NAME|${APP_NAME}|g" \
    -e "s|https://charts.example.com|${CHART_REPO}|g" \
    -e "s|chart: APP_NAME|chart: ${CHART_NAME}|g" \
    "${TEMPLATE_DIR}/application.yaml.tmpl" > "${TARGET_DIR}/application.yaml"
  ok "Created ${TARGET_DIR}/application.yaml"

  sed "s/APP_NAME/${APP_NAME}/g" "${TEMPLATE_DIR}/values.yaml.tmpl" > "${TARGET_DIR}/values.yaml"
  ok "Created ${TARGET_DIR}/values.yaml"

  echo ""
  info "Helm app: auto-discovered by ArgoCD ApplicationSet (no bootstrap file needed)"

else
  # ── Bootstrap Application for manifest-only apps ──────────────────────────
  # ArgoCD doesn't auto-discover manifest-only apps without a registered Application.
  # This bootstrap file is applied automatically by apply-changes.yml on push to main.
  # Deleting this file removes the app from ArgoCD (its resources will be pruned).
  APP_NS="apps-${APP_NAME}"
  if [[ "$TIER" != "apps" ]]; then
    APP_NS="${APP_NAME}"
  fi

  if [[ "$MODE" != "manifest-only" ]]; then
    cat > "${BOOTSTRAP_FILE}" << EOF
---
# ArgoCD Application for ${APP_NAME} — auto-generated by scripts/new-app.sh
# Applied automatically by apply-changes.yml when pushed to main.
# To remove: delete this file and the kubernetes/${TIER}/${APP_NAME}/ directory.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${TIER}-${APP_NAME}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${GIT_REPO_URL:-https://github.com/your-org/your-repo}.git
    targetRevision: HEAD
    path: ${TARGET_DIR}/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  # ignoreDifferences: suppress controller-managed fields that cause false OutOfSync.
  # Include this block for apps that use webhooks (cert-manager injection) or PodDisruptionBudgets.
  # See: kubernetes/core/argocd/values.yaml globalIgnoreDifferences for cluster-wide patterns.
  ignoreDifferences:
    # ExternalSecret: controller fills in these fields at runtime — ignore to prevent drift.
    - group: external-secrets.io
      kind: ExternalSecret
      jsonPointers:
        - /spec/data
      jqPathExpressions:
        - .spec.data[].remoteRef.conversionStrategy
        - .spec.data[].remoteRef.decodingStrategy
        - .spec.data[].remoteRef.metadataPolicy
EOF
    ok "Created ${BOOTSTRAP_FILE}"
    info "Bootstrap Application created — applied automatically on push to main"
  fi
fi

# ── Print summary ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "${GREEN}✅ App '${APP_NAME}' scaffolded at ${TARGET_DIR}/${NC}"
echo ""
echo -e "  ${BOLD}Security defaults already baked in:${NC}"
echo "    ✅ NetworkPolicy: default-deny + allow only from Traefik"
echo "    ✅ Dedicated ServiceAccount (no auto-mount)"
echo "    ✅ Pod Security Admission: restricted"
echo "    ✅ Secure pod template (non-root, read-only fs, drop ALL caps)"
echo "    ✅ ResourceQuota on namespace"
echo "    ✅ Auth label: infraweaver.io/auth=${AUTH_LABEL} (${AUTH_DESC})"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo ""
echo "    1. Update the image in ${TARGET_DIR}/manifests/deployment.yaml"
echo "       - Set 'image' to your actual container image"
echo "       - Set 'containerPort' to match your app's listening port"
echo ""

case "$AUTH_MODE" in
  vpn)
    echo "    2. Access mode: VPN-only"
    echo "       URL: https://${APP_NAME}.int.${BASE_DOMAIN}"
    ;;
  proxy|admin)
    echo "    2. Access mode: ${AUTH_DESC}"
    echo "       URL: https://${APP_NAME}.${BASE_DOMAIN} (Authentik login required)"
    if [[ "$AUTH_MODE" == "admin" ]]; then
      echo ""
      echo "       ⚙️  To enforce admin-only in Authentik:"
      echo "       - Create an Authentik Application + Proxy Provider for ${APP_NAME}.${BASE_DOMAIN}"
      echo "       - Add Policy Binding: ak_is_group_member(request.user, name=\"platform-admins\")"
      echo "       See: docs/MIDDLEWARES.md#admin-auth"
    fi
    ;;
  sso)
    echo "    2. Access mode: Native OIDC/SSO"
    echo "       See ${TARGET_DIR}/manifests/oidc-config.yaml.example for Authentik setup"
    ;;
  public)
    echo "    2. Access mode: ⚠️  PUBLIC — no authentication"
    echo "       URL: https://${APP_NAME}.${BASE_DOMAIN}"
    echo "       Consider --auth flag if this needs protecting"
    ;;
esac

echo ""
if [[ "$MODE" == "helm" ]]; then
  echo "    3. Pin the chart version in ${TARGET_DIR}/application.yaml"
  echo ""
fi
if [[ "$MODE" != "helm" ]]; then
  echo "    3. Push to git:"
  echo "       git add ${TARGET_DIR}/ ${BOOTSTRAP_FILE}"
else
  echo "    3. Push to git:"
  echo "       git add ${TARGET_DIR}/"
fi
echo "       git commit -m 'feat: add ${APP_NAME} app'"
echo "       git push"
echo ""
echo "    4. ArgoCD auto-deploys within ~60 seconds"
echo "       https://argocd.int.${BASE_DOMAIN}"
echo ""
echo "    5. View auth status across all apps:"
echo "       kubectl get deploy -A -L infraweaver.io/auth"
echo ""
warn "Replace all APP_NAME placeholders before pushing!"
warn "Review resource limits in deployment.yaml and resourcequota.yaml"
