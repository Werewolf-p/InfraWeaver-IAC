#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/bootstrap-openbao.sh — Initialize and unseal OpenBao, seed all platform secrets
#
# Usage: ENV_NAME=productie bash scripts/deploy/bootstrap-openbao.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Cleanup on exit
PF_PID=""
cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT
ENV=${ENV_NAME:?ENV_NAME required}
KB=~/.kube/config-platform-$ENV
LOCAL_OPENBAO="http://127.0.0.1:8200"

# Apply RBAC so the autounseal sidecar can read the openbao-unseal secret
kubectl --kubeconfig "$KB" apply -f kubernetes/core/openbao/manifests/rbac.yaml 2>/dev/null || true

# Pre-create openbao-unseal secret with placeholder values so the autounseal
# sidecar volume mount doesn't block the pod from starting. Real values are
# written below after OpenBao is initialised.
# IMPORTANT: Only create with placeholders if no real values exist yet —
# re-running this script must NOT overwrite real tokens with placeholders.
kubectl --kubeconfig "$KB" create namespace openbao --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB" apply -f -
_EXISTING_RT=$(kubectl --kubeconfig "$KB" get secret openbao-unseal \
  -n openbao -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
if [ -z "$_EXISTING_RT" ] || [ "$_EXISTING_RT" = "placeholder" ]; then
  kubectl --kubeconfig "$KB" create secret generic openbao-unseal \
    -n openbao \
    --from-literal=unseal_key="placeholder" \
    --from-literal=root_token="placeholder" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KB" apply -f -
  echo "==> openbao-unseal placeholder secret created"
else
  echo "==> openbao-unseal already has real values — preserving"
fi

# Wait for Longhorn to be ready (OpenBao PVC needs Longhorn storage)
echo "==> Waiting for Longhorn manager to be Running..."
for i in $(seq 1 30); do
  LHCOUNT=$(kubectl --kubeconfig "$KB" get pods -n longhorn-system \
    --no-headers 2>/dev/null | grep "longhorn-manager" | grep -c "Running" 2>/dev/null || true)
  LHCOUNT="${LHCOUNT:-0}"
  if [ "${LHCOUNT}" -gt "0" ] 2>/dev/null; then
    echo "  Longhorn manager running (${LHCOUNT} pod(s))"
    break
  fi
  echo "  Waiting for Longhorn ($i/30)..."
  sleep 10
done

# Wait for ArgoCD to discover and create the core-openbao Application
# Skip this wait if OpenBao is already deployed and running (local deploy scenario)
if kubectl --kubeconfig "$KB" get pods -n openbao \
    -l app.kubernetes.io/name=openbao --no-headers 2>/dev/null | grep -q "Running"; then
  echo "==> OpenBao already running — skipping ArgoCD sync wait"
else
  echo "==> Waiting for ArgoCD to discover core-openbao Application..."
  BAO_APP=""
  for i in $(seq 1 30); do
    BAO_APP=$(kubectl --kubeconfig "$KB" get applications -n argocd \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | \
      grep -i "openbao" | head -1 || echo "")
    if [ -n "$BAO_APP" ]; then
      echo "  ArgoCD Application '$BAO_APP' found"
      break
    fi
    echo "  Waiting for ArgoCD to discover openbao ($i/30)..."
    sleep 10
  done

  if [ -n "$BAO_APP" ]; then
    echo "==> Waiting for ArgoCD Application '$BAO_APP' to sync..."
    for i in $(seq 1 18); do
      SYNC=$(kubectl --kubeconfig "$KB" get application "$BAO_APP" -n argocd \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
      echo "  [$i/18] sync=$SYNC"
      if [ "$SYNC" = "Synced" ]; then break; fi
      sleep 10
    done
  fi
fi

# Wait for OpenBao pod to be Running (not necessarily Ready — readiness requires unsealed)
echo "==> Waiting for OpenBao pod to be Running (up to 10 min)..."
for i in $(seq 1 60); do
  RUNNING=$(kubectl --kubeconfig "$KB" get pods -n openbao \
    -l app.kubernetes.io/name=openbao --no-headers 2>/dev/null | \
    grep -c "Running" 2>/dev/null || true)
  RUNNING="${RUNNING:-0}"
  if [ "${RUNNING}" -gt "0" ] 2>/dev/null; then
    echo "  OpenBao pod Running"
    break
  fi
  echo "  Waiting for OpenBao pod ($i/60)..."
  if [ $(( i % 15 )) -eq 0 ]; then
    echo "  --- Diagnostics at iteration $i ---"
    kubectl --kubeconfig "$KB" get pods -n openbao 2>/dev/null || echo "  (openbao namespace not found)"
    BAO_APP_NOW=$(kubectl --kubeconfig "$KB" get applications -n argocd \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -i "openbao" || echo "")
    if [ -n "$BAO_APP_NOW" ]; then
      kubectl --kubeconfig "$KB" get application "$BAO_APP_NOW" -n argocd \
        -o jsonpath='  sync={.status.sync.status} health={.status.health.status}\n' 2>/dev/null || true
    fi
  fi
  sleep 10
done

# Port-forward directly to the pod (avoids endpoint readiness gate)
BAO_POD=$(kubectl --kubeconfig "$KB" get pod -n openbao \
  -l app.kubernetes.io/name=openbao --no-headers \
  -o custom-columns=":metadata.name" 2>/dev/null | head -1)
if [ -z "$BAO_POD" ]; then
  echo "ERROR: OpenBao pod not found after waiting — cannot proceed"
  exit 1
fi
echo "Using OpenBao pod: $BAO_POD"
kubectl --kubeconfig "$KB" port-forward -n openbao "pod/${BAO_POD}" 8200:8200 &
PF_PID=$!
sleep 5

# Check initialisation status
INIT_STATUS=$(curl -s "${LOCAL_OPENBAO}/v1/sys/init" | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized', False))" \
  2>/dev/null || echo "False")

if [ "$INIT_STATUS" != "True" ]; then
  echo "==> Initializing OpenBao (first deploy)..."
  INIT_OUTPUT=$(curl -s -X POST "${LOCAL_OPENBAO}/v1/sys/init" \
    -H "Content-Type: application/json" \
    -d '{"secret_shares": 1, "secret_threshold": 1}' || echo "")

  UNSEAL_KEY=$(echo "$INIT_OUTPUT" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['keys_base64'][0])" \
    2>/dev/null || echo "")
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['root_token'])" \
    2>/dev/null || echo "")

  if [ -z "$UNSEAL_KEY" ] || [ -z "$ROOT_TOKEN" ]; then
    echo "ERROR: Init output missing keys:"
    echo "$INIT_OUTPUT"
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi

  # Store unseal key + root token as k8s Secret (RBAC-protected)
  kubectl --kubeconfig "$KB" create namespace openbao \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KB" apply -f -
  kubectl --kubeconfig "$KB" create secret generic openbao-unseal \
    -n openbao \
    --from-literal=unseal_key="$UNSEAL_KEY" \
    --from-literal=root_token="$ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KB" apply -f -

  # Unseal via the API
  curl -s -X POST "${LOCAL_OPENBAO}/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null || true
  echo "==> OpenBao initialized and unsealed"

  # Wait for pod to become Ready after unseal (up to 3 min)
  echo "==> Waiting for OpenBao pod to become Ready after unseal..."
  kubectl --kubeconfig "$KB" wait pod -n openbao \
    -l app.kubernetes.io/name=openbao \
    --for=condition=Ready --timeout=180s 2>/dev/null && \
    echo "  OpenBao pod Ready" || echo "  (pod not yet Ready — continuing anyway)"
else
  echo "==> OpenBao already initialized — checking seal status..."
  UNSEAL_KEY=$(kubectl --kubeconfig "$KB" get secret openbao-unseal \
    -n openbao -o jsonpath='{.data.unseal_key}' 2>/dev/null | base64 -d || echo "")
  ROOT_TOKEN=$(kubectl --kubeconfig "$KB" get secret openbao-unseal \
    -n openbao -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  SEALED=$(curl -s "${LOCAL_OPENBAO}/v1/sys/seal-status" | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed', True))" \
    2>/dev/null || echo "True")
  if [ "$SEALED" != "False" ] && [ -n "$UNSEAL_KEY" ]; then
    curl -s -X POST "${LOCAL_OPENBAO}/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null || true
    echo "==> Unsealed"
  fi
fi

if [ -z "$ROOT_TOKEN" ]; then
  echo "⚠ No root token available — skipping OpenBao configuration"
  kill $PF_PID 2>/dev/null || true
  exit 0
fi

# Enable KV v2 at path "secret" (idempotent — 400 if already mounted is OK)
curl -s -X POST "${LOCAL_OPENBAO}/v1/sys/mounts/secret" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "kv", "options": {"version": "2"}}' > /dev/null 2>&1 || true

# Wait for KV v2 upgrade to complete (OpenBao briefly enters "upgrading" state)
echo "==> Waiting for KV v2 backend to be ready..."
for i in $(seq 1 20); do
  PROBE=$(curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/_ready_probe" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"data":{"ok":"1"}}')
  PROBE_ERR=$(echo "$PROBE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('errors',[''])[0])" 2>/dev/null || echo "parse_err")
  if echo "$PROBE_ERR" | grep -qi "upgrading"; then
    echo "  KV upgrading... ($i/20)"
    sleep 2
  else
    echo "  KV backend ready"
    # Clean up probe key (best-effort)
    curl -s -X DELETE "${LOCAL_OPENBAO}/v1/secret/metadata/_ready_probe" \
      -H "X-Vault-Token: $ROOT_TOKEN" > /dev/null 2>&1 || true
    break
  fi
done

# Write Grafana secret — only on first deploy (do not overwrite existing password)
EXISTING_GRAFANA=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/grafana" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('admin-password',''))" \
  2>/dev/null || echo "")
if [ -z "$EXISTING_GRAFANA" ]; then
  GRAFANA_PASS=$(openssl rand -base64 20 | tr -d '=+/')
  GRAFANA_WRITE=$(curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/grafana" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"admin-user\": \"admin\", \"admin-password\": \"$GRAFANA_PASS\"}}")
  GRAFANA_VERSION=$(echo "$GRAFANA_WRITE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('version',''))" 2>/dev/null || echo "")
  if [ -n "$GRAFANA_VERSION" ]; then
    echo "==> Grafana secret written (randomly generated, version=$GRAFANA_VERSION)"
  else
    echo "⚠ Grafana write failed: $GRAFANA_WRITE"
    exit 1
  fi
else
  echo "==> Grafana secret already exists — preserving existing password"
fi

# ── Catalog app secrets — dynamic seeding via seed-catalog-secrets.sh ────────
#
# OLD APPROACH (removed): each catalog app had its own hardcoded block here
# (wiki, gitea, forgejo, vaultwarden). This was error-prone and required manual
# updates when apps were added or removed.
#
# NEW APPROACH: each catalog app declares its secret requirements in catalog.yaml
# under a `secrets:` section. seed-catalog-secrets.sh reads those declarations
# and idempotently seeds the required secrets into OpenBao.
#
# To add secrets for a new catalog app:
#   1. Add a `secrets:` section to kubernetes/catalog/<app>/catalog.yaml
#   2. Enable the app in platform.yaml
#   3. The next deploy will automatically seed the secrets
#
# The script is idempotent: existing values are NEVER overwritten.
echo ""
echo "==> Seeding catalog app secrets dynamically..."
OPENBAO_ADDR="${LOCAL_OPENBAO}" \
  VAULT_TOKEN="$ROOT_TOKEN" \
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" \
  bash "$(dirname "${BASH_SOURCE[0]}")/../seed-catalog-secrets.sh"
echo "==> Catalog secrets seeding complete"
echo ""

ARGOCD_ADMIN_PASS=$(kubectl --kubeconfig "$KB" get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [ -n "$ARGOCD_ADMIN_PASS" ]; then
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/argocd" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"admin-user\": \"admin\", \"admin-password\": \"$ARGOCD_ADMIN_PASS\"}}" > /dev/null
  echo "==> ArgoCD admin password stored in OpenBao (auto-generated by ArgoCD)"
else
  echo "==> argocd-initial-admin-secret not found — ArgoCD already configured"
fi

# ArgoCD admin: generate random password, apply bcrypt hash to argocd-secret, store in OpenBao
python3 -c "import bcrypt" 2>/dev/null || pip3 install --quiet bcrypt 2>/dev/null || sudo apt-get install -y python3-bcrypt -q 2>/dev/null || true
ADMIN_PASS=$(openssl rand -base64 20 | tr -d '=+/')
ADMIN_PASS_FILE=$(mktemp)
ADMIN_PATCH_FILE=$(mktemp)
printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE"
python3 - "$ADMIN_PASS_FILE" "$ADMIN_PATCH_FILE" 2>/dev/null << 'ADMIN_PYEOF' || true
import bcrypt, json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    p = f.read().strip().encode()
h = bcrypt.hashpw(p, bcrypt.gensalt(10)).decode()
mtime = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'stringData': {'accounts.${ADMIN_USERNAME:-admin}.password': h, 'accounts.${ADMIN_USERNAME:-admin}.passwordMtime': mtime}}, open(sys.argv[2], 'w'))
ADMIN_PYEOF
if [ -s "$ADMIN_PATCH_FILE" ]; then
  kubectl --kubeconfig "$KB" patch secret argocd-secret -n argocd \
    --patch-file "$ADMIN_PATCH_FILE" 2>/dev/null || true
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/argocd-admin" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"user\": \"${ADMIN_USERNAME:-admin}\", \"password\": \"$ADMIN_PASS\"}}" > /dev/null
  echo "==> ArgoCD admin password randomized and stored in OpenBao"
else
  echo "==> WARNING: bcrypt unavailable — admin password not set"
fi
rm -f "$ADMIN_PASS_FILE" "$ADMIN_PATCH_FILE"


# Authentik: seed secret (script handles first-deploy and admin-password patch)
bash scripts/deploy/seed-openbao-authentik.sh "$LOCAL_OPENBAO" "$ROOT_TOKEN"

# Authentik SMTP: always update OpenBao with real credentials from GitHub secrets
# (ESO ExternalSecret manages authentik-smtp-secret from these values)
if [ -n "${SMTP_PASSWORD}" ]; then
  EXISTING_DATA=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
    "${LOCAL_OPENBAO}/v1/secret/data/platform/authentik" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(__import__('json').dumps(d.get('data',{}).get('data',{})))" \
    2>/dev/null || echo "{}")
  SMTP_PATCHED=$(python3 -c \
    "import json,sys; d=json.loads(sys.argv[1]); d.update({'smtp-username':sys.argv[2],'smtp-password':sys.argv[3],'smtp-from':sys.argv[2]}); print(json.dumps({'data':d}))" \
    "$EXISTING_DATA" \
    "${SMTP_USERNAME}" \
    "${SMTP_PASSWORD}" \
    2>/dev/null || echo "")
  if [ -n "$SMTP_PATCHED" ]; then
    curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/authentik" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$SMTP_PATCHED" > /dev/null
    echo "==> Authentik SMTP credentials updated in OpenBao"
  fi
else
  echo "⚠ SMTP_PASSWORD not set — authentik-smtp-secret will use placeholder"
fi

# GitHub PAT: optional — for console pipeline listing, pelican eggs, workflow dispatch.
# Does NOT overwrite an existing non-empty token (preserves manually rotated PATs).
if [ -n "${PLATFORM_GITHUB_PAT:-}" ]; then
  EXISTING_GH=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
    "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('github-token',''))" \
    2>/dev/null || echo "")
  if [ -z "$EXISTING_GH" ]; then
    # Read-modify-write to preserve all other keys
    EXISTING_DATA=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
      "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('data',{}).get('data',{})))" \
      2>/dev/null || echo "{}")
    PATCHED=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1]); d['github-token']=sys.argv[2]
print(json.dumps({'data':d}))
" "$EXISTING_DATA" "$PLATFORM_GITHUB_PAT")
    curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PATCHED" > /dev/null
    echo "==> GitHub token stored in OpenBao (platform/infraweaver-console[github-token])"
  else
    echo "==> GitHub token already exists in OpenBao — preserving existing value"
  fi
else
  echo "==> GITHUB_PAT not set — console pipeline/pelican features will be unavailable (optional; set GITHUB_PAT secret in repo settings)"
fi

# ── Authentik API token for InfraWeaver console ─────────────────────────────
echo "==> Seeding Authentik API token for InfraWeaver console..."
EXISTING_AUTH_TOKEN=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('authentik-token',''))" \
  2>/dev/null || echo "")

if [ -z "$EXISTING_AUTH_TOKEN" ]; then
  AUTHENTIK_URL="${LOCAL_AUTHENTIK:-http://authentik-server.authentik.svc.cluster.local}"
  BOOTSTRAP_TOKEN=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
    "${LOCAL_OPENBAO}/v1/secret/data/platform/authentik" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('bootstrap-token',''))" \
    2>/dev/null || echo "")

  if [ -n "$BOOTSTRAP_TOKEN" ]; then
    # NOTE: AUTHENTIK_URL is an in-cluster Service DNS name that is typically NOT
    # resolvable/routable from the deployment runner. Every curl here is therefore
    # best-effort and MUST be guarded with --max-time + "|| true"/"|| echo" so a
    # connection/resolution failure (curl exit 6/7/28) can never abort the deploy
    # under "set -euo pipefail". Authentik token wiring is finalised later by the
    # in-cluster console/Authentik configuration, not from the runner.
    AUTH_TOKEN_KEY=$(curl -s --max-time 10 -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
      "${AUTHENTIK_URL}/api/v3/core/tokens/infraweaver-console-api/view_key/" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('key',''))" 2>/dev/null || echo "")
    if [ -z "$AUTH_TOKEN_KEY" ]; then
      ADMIN_PK=$(curl -s --max-time 10 -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
        "${AUTHENTIK_URL}/api/v3/core/users/?username=akadmin" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['pk']) if d['results'] else print(4)" \
        2>/dev/null || echo "4")
      curl -s --max-time 10 -X POST "${AUTHENTIK_URL}/api/v3/core/tokens/" \
        -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"identifier\":\"infraweaver-console-api\",\"intent\":\"api\",\"user\":${ADMIN_PK},\"description\":\"InfraWeaver Console API Token\",\"expiring\":false}" \
        > /dev/null 2>&1 || true
      AUTH_TOKEN_KEY=$(curl -s --max-time 10 -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
        "${AUTHENTIK_URL}/api/v3/core/tokens/infraweaver-console-api/view_key/" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('key',''))" 2>/dev/null || echo "")
    fi
    if [ -n "$AUTH_TOKEN_KEY" ]; then
      EXISTING_DATA=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
        "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('data',{}).get('data',{})))" \
        2>/dev/null || echo "{}")
      PATCHED=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['authentik-token']=sys.argv[2]; print(json.dumps({'data':d}))" "$EXISTING_DATA" "$AUTH_TOKEN_KEY")
      curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" \
        -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" -d "$PATCHED" > /dev/null
      echo "==> Authentik API token stored in OpenBao (platform/infraweaver-console[authentik-token])"
    else
      echo "==> Could not get Authentik API token — console Authentik features may be limited"
    fi
  else
    echo "==> Authentik bootstrap-token not found — skipping authentik-token seeding"
  fi
else
  echo "==> Authentik API token already exists in OpenBao — preserving"
fi

# ── DNS Provider credentials ────────────────────────────────────────────────
DNS_PROV="${DNS_PROVIDER:-cloudflare}"
echo "==> Seeding DNS provider credentials (provider: ${DNS_PROV})"

DNS_SECRETS_JSON=$(DNS_PROV="$DNS_PROV" \
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" \
  AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
  AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
  AWS_HOSTED_ZONE_ID="${AWS_HOSTED_ZONE_ID:-}" \
  AWS_REGION="${AWS_REGION:-us-east-1}" \
  AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}" \
  AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}" \
  AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}" \
  AZURE_TENANT_ID="${AZURE_TENANT_ID:-}" \
  AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}" \
  DIGITALOCEAN_TOKEN="${DIGITALOCEAN_TOKEN:-}" \
  HETZNER_DNS_API_KEY="${HETZNER_DNS_API_KEY:-}" \
  python3 - <<'PYEOF'
import json
import os

provider = os.environ.get("DNS_PROV", "cloudflare")
blank = {
    "cloudflare-api-token": "",
    "aws-access-key-id": "",
    "aws-secret-access-key": "",
    "aws-hosted-zone-id": "",
    "aws-region": "",
    "azure-client-id": "",
    "azure-client-secret": "",
    "azure-subscription-id": "",
    "azure-tenant-id": "",
    "azure-resource-group": "",
    "do-token": "",
    "hetzner-api-key": "",
}
provider_values = {
    "cloudflare": {"cloudflare-api-token": os.environ.get("CLOUDFLARE_API_TOKEN", "")},
    "route53": {
        "aws-access-key-id": os.environ.get("AWS_ACCESS_KEY_ID", ""),
        "aws-secret-access-key": os.environ.get("AWS_SECRET_ACCESS_KEY", ""),
        "aws-hosted-zone-id": os.environ.get("AWS_HOSTED_ZONE_ID", ""),
        "aws-region": os.environ.get("AWS_REGION", "us-east-1"),
    },
    "azure": {
        "azure-client-id": os.environ.get("AZURE_CLIENT_ID", ""),
        "azure-client-secret": os.environ.get("AZURE_CLIENT_SECRET", ""),
        "azure-subscription-id": os.environ.get("AZURE_SUBSCRIPTION_ID", ""),
        "azure-tenant-id": os.environ.get("AZURE_TENANT_ID", ""),
        "azure-resource-group": os.environ.get("AZURE_RESOURCE_GROUP", ""),
    },
    "digitalocean": {"do-token": os.environ.get("DIGITALOCEAN_TOKEN", "")},
    "hetzner": {"hetzner-api-key": os.environ.get("HETZNER_DNS_API_KEY", "")},
    "none": {},
}
provider = provider if provider in provider_values else "none"
payload = {"provider": provider, **blank, **provider_values[provider]}
print(json.dumps({"data": payload}))
PYEOF
)

curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/dns-provider" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$DNS_SECRETS_JSON" > /dev/null
echo "==> DNS provider credentials stored in OpenBao (platform/dns-provider)"

if [ "$DNS_PROV" = "cloudflare" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/cloudflare" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"CF_API_TOKEN\": \"${CLOUDFLARE_API_TOKEN}\", \"CF_EMAIL\": \"${ADMIN_EMAIL:-$SMTP_USERNAME}\"}}" > /dev/null
  echo "==> Cloudflare token stored in OpenBao (platform/cloudflare)"
fi

# ── Discord webhook (optional) ────────────────────────────────────────────────
EXISTING_DISCORD=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/discord" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('webhook_url',''))" 2>/dev/null || echo "")
if [ -z "$EXISTING_DISCORD" ]; then
  WEBHOOK="${DISCORD_WEBHOOK_URL:-placeholder-discord-webhook}"
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/discord" \
    -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"data\": {\"webhook_url\": \"${WEBHOOK}\"}}" > /dev/null
  [ "${WEBHOOK}" = "placeholder-discord-webhook" ] && \
    echo "⚠ DISCORD_WEBHOOK_URL not set — alerting will not work until updated" || \
    echo "==> Discord webhook stored in OpenBao (platform/discord)"
fi

# ── Minio/Velero S3 credentials ────────────────────────────────────────────────
EXISTING_MINIO=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/minio-velero" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('access_key',''))" 2>/dev/null || echo "")
if [ -z "$EXISTING_MINIO" ]; then
  # Generate random credentials for in-cluster Minio
  MINIO_ACCESS="${MINIO_VELERO_ACCESS_KEY:-velero-$(openssl rand -hex 8)}"
  MINIO_SECRET="${MINIO_VELERO_SECRET_KEY:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)}"
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/minio-velero" \
    -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"data\": {\"access_key\": \"${MINIO_ACCESS}\", \"secret_key\": \"${MINIO_SECRET}\"}}" > /dev/null
  echo "==> Minio Velero credentials generated and stored in OpenBao (platform/minio-velero)"
fi

# ── NAS credentials (optional, placeholders if not set) ──────────────────────
EXISTING_NAS=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/nas/synology" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('user',''))" 2>/dev/null || echo "")
if [ -z "$EXISTING_NAS" ]; then
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/nas/synology" \
    -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"data\": {\"user\": \"${SYNOLOGY_USER:-placeholder}\", \"password\": \"${SYNOLOGY_PASSWORD:-placeholder}\", \"host\": \"${SYNOLOGY_HOST:-placeholder}\"}}" > /dev/null
  echo "==> NAS/Synology credentials seeded (platform/nas/synology)"
fi

EXISTING_TRUENAS=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/nas/truenas" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('api-key',''))" 2>/dev/null || echo "")
if [ -z "$EXISTING_TRUENAS" ]; then
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/nas/truenas" \
    -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"data\": {\"api-key\": \"${TRUENAS_API_KEY:-placeholder}\", \"host\": \"${TRUENAS_HOST:-placeholder}\"}}" > /dev/null
  echo "==> NAS/TrueNAS credentials seeded (platform/nas/truenas)"
fi

# NOTE: the legacy OneDev pull secret (platform/onedev-pull-secret, pointing at the
# now-dead onedev.int registry) was removed 2026-06-14 — OneDev is decommissioned and
# no workload references it. Images are pulled via the GHCR secret (below) and the
# self-hosted Zot registry-pull-secret. See externalsecret-registry.yaml.

# ── GHCR pull secret (for infraweaver-console and infraweaver-system namespaces) ──
# Seeded into OpenBao (secret/platform/ghcr-pull-secret); the ghcr-pull-secret
# ExternalSecrets in the console + node catalog bases project it into both
# namespaces. No plaintext dockerconfigjson is applied to the cluster here.
# Use a read-only token (classic PAT, `read:packages` scope only).
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GHCR_USER="${GITHUB_ACTOR:-${GITHUB_ORG:-your-org}}" \
  GHCR_TOKEN="${GITHUB_TOKEN}" \
    bash "$(dirname "${BASH_SOURCE[0]}")/seed-ghcr-pull-secret.sh" \
      "$LOCAL_OPENBAO" "$ROOT_TOKEN" --force
  echo "==> GHCR pull credential seeded into OpenBao; ESO will project ghcr-pull-secret"
fi

# ── InfraWeaver Console additional secrets ───────────────────────────────────
# Patch infraweaver-console with DNS provider metadata (and Cloudflare fields when applicable)
EXISTING_IW=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('data',{}).get('data',{})))" 2>/dev/null || echo "{}")
CF_ZONE_ID=""
CF_TOKEN_VAL=""
if [ "$DNS_PROV" = "cloudflare" ]; then
  CF_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
  CF_TOKEN_VAL="${CLOUDFLARE_API_TOKEN:-}"
fi
PATCHED=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['dns-provider'] = sys.argv[2]
d['cloudflare-api-token'] = sys.argv[3]
d['cf-zone-id'] = sys.argv[4]
print(json.dumps({'data': d}))
" "$EXISTING_IW" "$DNS_PROV" "$CF_TOKEN_VAL" "$CF_ZONE_ID" 2>/dev/null || echo "")
if [ -n "$PATCHED" ]; then
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/infraweaver-console" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PATCHED" > /dev/null
  echo "==> dns-provider metadata added to infraweaver-console"
fi

# ── Infraweaver API console secret ───────────────────────────────────────────
EXISTING_API=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
  "${LOCAL_OPENBAO}/v1/secret/data/infraweaver/api/console-secret" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('value',''))" 2>/dev/null || echo "")
if [ -z "$EXISTING_API" ]; then
  API_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/infraweaver/api/console-secret" \
    -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"data\": {\"value\": \"${API_SECRET}\"}}" > /dev/null
  echo "==> InfraWeaver API console secret generated (infraweaver/api/console-secret)"
fi


# ─────────────────────────────────────────────────────────────────────────────
# OpenBao policies — THE ONLY COPY. Do not fork this file into another repo.
#
# `bao policy write` is a FULL REPLACE, not a merge. On 2026-08-06T20:21:18Z a
# run of a SECOND copy of this script (InfraWeaver-platform scripts/deploy/,
# resurrected by platform 3728d3f6 after af622592 moved IaC here, then edited by
# platform 1e8e30e3) overwrote platform-k8s with its own half of the policy. That
# silently dropped secret/{data,metadata}/{iwsl,catalog}/* and broke four
# ExternalSecrets; three ArgoCD Applications sat Degraded for ~12 hours because
# nothing compared live policy to git. The platform copy is now deleted and
# scripts/validate-openbao-policy-drift.sh diffs live against these heredocs.
#
# Both policies below are the UNION and match live byte-for-byte, so re-running
# this script is a no-op against the current cluster, never a regression.
# ─────────────────────────────────────────────────────────────────────────────

# platform-k8s — held by the ESO kubernetes-auth role AND by console service
# tokens. Least privilege for both: read-only over secret/platform/* with a
# single more-specific CRUD carve-out for the service-account subtree the
# console mints PATs into.
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 sh -c \
  'bao policy write platform-k8s - <<EOF
path "secret/data/platform/*" { capabilities = ["read","list"] }
path "secret/metadata/platform/*" { capabilities = ["read","list"] }
# Service-account tokens are minted BY the console at runtime, so this one
# subtree needs write — a more-specific path overrides the read-only glob above.
path "secret/data/platform/service-accounts/*" { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/platform/service-accounts/*" { capabilities = ["create","read","update","delete","list"] }
path "secret/data/infraweaver/*" { capabilities = ["read","list","create","update","delete"] }
path "secret/metadata/infraweaver/*" { capabilities = ["read","list","create","update","delete"] }
# IWSL phase-3 signer keys (infra 2520225). Regressed 2026-08-06T20:21:18Z.
path "secret/data/iwsl/*" { capabilities = ["read","list"] }
path "secret/metadata/iwsl/*" { capabilities = ["read","list"] }
# game-hub server credentials (PR#82) — app catalog secrets, read-only for ESO.
path "secret/data/catalog/*" { capabilities = ["read","list"] }
path "secret/metadata/catalog/*" { capabilities = ["read","list"] }
# tradesphere ESO reads. NARROW single path on purpose: secret/private/* is the
# per-app self-service namespace and ESO must never be able to read all of it.
path "secret/data/private/tradesphere" { capabilities = ["read"] }
path "secret/metadata/private/tradesphere" { capabilities = ["read"] }
EOF'
echo "==> ESO policy platform-k8s written"

# Console runtime policy (attached to the console's OpenBao token, -policy=wordpress).
# Covers the WordPress Manager addon's KV paths, the UDM/NAS/app-account config the
# console settings cards write, and the audit-log signing key. Policies are
# referenced by name and evaluated per-request, so updating this content lifts the
# live token's permissions without recreating the token or restarting the console.
#
# ── PENDING, DELIBERATELY NOT WRITTEN ────────────────────────────────────────
# Commit d35d412 added six further paths to this policy in git. They were never
# applied to the cluster, and re-adding them here would make the next run of this
# script silently widen the console token beyond what was approved — the exact
# failure mode that caused the 2026-08-06 outage, only in the granting direction.
# They are parked here as text, NOT inside the heredoc. To adopt them: get sign-off,
# move the six lines into the heredoc, run this script, and re-run
# scripts/validate-openbao-policy-drift.sh --live to confirm live matches git.
#
#   # Fleet Command member-cluster credentials (kubeconfig + ArgoCD token per cluster)
#   path "secret/data/platform/fleet/*" { capabilities = ["create","read","update","delete"] }
#   path "secret/metadata/platform/fleet/*" { capabilities = ["read","delete","list"] }
#   # Velocity forwarding secret, one per Game Hub network
#   path "secret/data/platform/game-hub/networks/*" { capabilities = ["create","read","update","delete"] }
#   path "secret/metadata/platform/game-hub/networks/*" { capabilities = ["read","delete","list"] }
#   # Signing keyrings for lib/trust (read+create only — a deletable keyring would
#   # make every signature it ever produced unverifiable)
#   path "secret/data/platform/trust/*" { capabilities = ["create","read","update"] }
#   path "secret/metadata/platform/trust/*" { capabilities = ["read","list"] }
#
# Until then, console features reading those paths get 403 — the same silent
# failure audit-log signing had. Tracked, not hidden.
# ─────────────────────────────────────────────────────────────────────────────
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 sh -c \
  'bao policy write wordpress - <<EOF
path "secret/data/wordpress/*" { capabilities = ["create","read","update","delete"] }
path "secret/metadata/wordpress/*" { capabilities = ["read","delete","list"] }
# InfraWeaver console UDM connector (settings card writes host + api-key here)
path "secret/data/platform/udm" { capabilities = ["create","read","update"] }
path "secret/metadata/platform/udm" { capabilities = ["read"] }
# InfraWeaver console NAS provider registry (Storage "Add provider" writes the
# dynamic Synology/TrueNAS list + credentials here, read at request time)
path "secret/data/platform/nas/providers" { capabilities = ["create","read","update"] }
path "secret/metadata/platform/nas/providers" { capabilities = ["read"] }
# Flat per-provider SMB creds the assign ExternalSecret projects into the CSI
# credential Secret (ESO reads these via secret/data/platform/* below).
path "secret/data/platform/nas/creds/*" { capabilities = ["create","read","update"] }
path "secret/metadata/platform/nas/creds/*" { capabilities = ["read","delete"] }
# Local app accounts the console provisions from RBAC grants (Jellyfin today):
# the service-account credential plus one generated password per user. Jellyfin
# native/TV clients cannot use OIDC, so these local passwords are the only way in
# and the console must be able to re-read them to hand them to their owner.
path "secret/data/platform/app-accounts/*" { capabilities = ["create","read","update","delete"] }
path "secret/metadata/platform/app-accounts/*" { capabilities = ["read","delete","list"] }
# Alertmanager inbound token (console lib/alerts/inbound-token.ts).
# create+read+update on this ONE path: the console mints it on first use from
# the "Set up cluster alert delivery" action, and an existing token is never
# overwritten, so read alone is not enough. NO delete, for the same reason the
# trust keyrings above are create/read/update only — a deletable token would
# break Alertmanager authentication silently, and the failure would look like a
# network problem during the incident it was carrying alerts about.
# Granted HERE rather than in platform-k8s for the same reason as the audit
# signing key below: platform-k8s is also held by the ESO token. ESO must be
# able to READ this value — it already can, via the read-only
# secret/data/platform/* glob in that policy, which is how it lands in both
# namespaces — but it has no business minting a credential it merely delivers.
# NOTE no apostrophes anywhere in this block: the policy body is wrapped in
# sh -c with single quotes, so one would terminate the wrapper. The pre-push
# IaC gate checks exactly that.
path "secret/data/platform/alerts" { capabilities = ["create","read","update"] }
path "secret/metadata/platform/alerts" { capabilities = ["read"] }
# Audit-log signing key (console lib/audit/signing.ts, SIGNING_KV_PATH).
# readKv+writeKv on this ONE path: the key is created on first use and rotated
# in place, so read alone is not enough. Granted here rather than in
# platform-k8s because that policy is also held by the ESO token, which has no
# business writing the key that signs the audit trail.
# Measured before this grant: 908 "permission denied" on
# secret/data/platform/audit/signing from token-infraweaver-console, continuous
# since at least 2026-08-02 — audit-log signing was failing silently.
path "secret/data/platform/audit/signing" { capabilities = ["create","read","update"] }
path "secret/metadata/platform/audit/signing" { capabilities = ["read"] }
EOF'
echo "==> Console runtime policy wordpress written"

# Tune token auth to allow long-lived tokens (use bao CLI)
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao auth tune -max-lease-ttl=87600h token/ 2>/dev/null || true

# ── ESO authenticates via Kubernetes auth (SA JWT) — no static token ──────────
# ESO logs in to OpenBao's kubernetes auth backend using its own auto-rotated pod
# ServiceAccount token (external-secrets/external-secrets), role `external-secrets`
# (policy platform-k8s). SA JWTs never expire as a class — this replaced the old
# periodic token that recurred as a cluster-wide outage every ~30 days.
# Prereq: the openbao SA holds system:auth-delegator so OpenBao can call the
# TokenReview API (kubernetes/core/openbao/manifests/rbac.yaml).

# Enable + configure the kubernetes auth method (idempotent). With
# disable_local_ca_jwt=false (default) OpenBao uses its own mounted CA + SA token
# to call TokenReview.
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao auth enable kubernetes 2>/dev/null || true
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc

# Register the ESO role: bound to its ServiceAccount, scoped to platform-k8s.
kubectl --kubeconfig "$KB" exec -n openbao openbao-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    token_policies=platform-k8s \
    token_ttl=1h
echo "==> ESO kubernetes auth role 'external-secrets' registered (policy platform-k8s)"

# Close port-forward before kubectl operations
kill $PF_PID 2>/dev/null || true

# Ensure the external-secrets namespace exists (the ClusterSecretStore + ESO land here)
kubectl --kubeconfig "$KB" create namespace external-secrets --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB" apply -f - 2>/dev/null || true

