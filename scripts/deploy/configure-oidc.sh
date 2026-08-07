#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/configure-oidc.sh — Configure OIDC for ArgoCD, OpenBao, and all SSO integrations
#
# Usage: ENV_NAME=productie bash scripts/deploy/configure-oidc.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Cleanup on exit
AUTHENTIK_PF_PID=""
cleanup() {
  [[ -n "${AUTHENTIK_PF_PID:-}" ]] && kill "$AUTHENTIK_PF_PID" 2>/dev/null || true
  rm -f /tmp/authentik-pf.log /tmp/authentik-pf
}
trap cleanup EXIT
KB=~/.kube/config-platform-${ENV_NAME:?ENV_NAME required}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"

# AUTHENTIK_ADMIN_TOKEN can be passed in from configure-authentik.sh (GitHub Actions)
# or we retrieve it directly from the worker pod (local deploy).
# Falls back to the K8s bootstrap-token secret for local/first-run deploys.
TOKEN="${AUTHENTIK_ADMIN_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo "==> Retrieving Authentik admin token from worker pod (gh-actions-api-token)..."
  _AK_TOKEN_PY='from authentik.core.models import Token; t = Token.objects.filter(identifier="gh-actions-api-token").first(); print("TOKEN:" + t.key) if t else print("")'
  TOKEN=$($KT exec -i -n authentik deploy/authentik-worker -c worker -- \
    sh -c "echo '${_AK_TOKEN_PY}' | ak shell" 2>/dev/null | grep "^TOKEN:" | sed 's/TOKEN://' || echo "")
fi

# Fallback: use the bootstrap-token from the authentik-secrets K8s Secret (local deploy)
if [ -z "$TOKEN" ]; then
  echo "==> Falling back to bootstrap-token from K8s secret..."
  TOKEN=$($KT get secret authentik-secrets -n authentik \
    -o jsonpath='{.data.bootstrap-token}' 2>/dev/null | base64 -d || echo "")
  [ -n "$TOKEN" ] && echo "  ✅ Using bootstrap-token for local deploy"
fi

if [ -z "$TOKEN" ]; then
  echo "⚠️ No Authentik token available — skipping OIDC bootstrap (non-critical)"
  exit 0
fi

# ── Port-forward Authentik server for TLS-free API access ────────
$KT port-forward svc/authentik-server -n authentik 8088:80 > /tmp/authentik-pf.log 2>&1 &
AUTHENTIK_PF_PID=$!
sleep 5
AUTHENTIK_URL="http://localhost:8088"
echo "Authentik API available at $AUTHENTIK_URL (port-forward PID=$AUTHENTIK_PF_PID)"

# ── Helper: wait for Authentik provider to exist ─────────────────
wait_for_provider() {
  local name="$1"
  for i in $(seq 1 30); do
    COUNT=$(curl -sf \
      -H "Authorization: Bearer $TOKEN" \
      "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")" \
      2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['pagination']['count'])" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then return 0; fi
    echo "  Waiting for Authentik provider '$name' ($i/30)..."
    sleep 10
  done
  return 1
}

# ── Read ArgoCD client_secret ─────────────────────────────────────
echo "==> Fetching ArgoCD OAuth2 client_secret from Authentik..."
wait_for_provider "ArgoCD Provider"
ARGOCD_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=ArgoCD%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")
if [ -z "$ARGOCD_SECRET" ]; then
  echo "⚠️ Could not fetch ArgoCD client_secret — OIDC login will not work until fixed"
else
  echo "✅ ArgoCD client_secret retrieved"
  # Patch argocd-secret so ArgoCD picks it up for OIDC
  ARGOCD_SECRET_B64=$(printf '%s' "$ARGOCD_SECRET" | base64 -w0)
  $KT patch secret argocd-secret -n argocd \
    --type=merge \
    -p "{\"data\": {\"oidc.authentik.clientSecret\": \"${ARGOCD_SECRET_B64}\"}}"
  echo "✅ argocd-secret patched with OIDC client_secret"

  # Store in OpenBao for reference
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv put secret/platform/argocd-oidc client_secret="$ARGOCD_SECRET" > /dev/null 2>&1 || true
  fi
fi

# ── Read OpenBao client_secret ────────────────────────────────────
echo "==> Fetching OpenBao OAuth2 client_secret from Authentik..."
wait_for_provider "OpenBao Provider"
OPENBAO_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=OpenBao%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

# ── Configure OpenBao OIDC auth ───────────────────────────────────
if [ -z "$OPENBAO_SECRET" ]; then
  echo "⚠️ Could not fetch OpenBao client_secret — OIDC auth will not work"
else
  echo "✅ OpenBao client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    BAO_POD=$($KT get pod -n openbao \
      -l app.kubernetes.io/name=openbao --no-headers \
      -o custom-columns=":metadata.name" 2>/dev/null | head -1 || echo "")
    if [ -n "$BAO_POD" ]; then
      # Verify internal Authentik OIDC endpoint via runner port-forward (avoids hairpin NAT
      # and curl-dependency inside the openbao pod). OpenBao uses internal service URL
      # server-side to fetch JWKS keys; end-users redirect to external auth.${BASE_DOMAIN}.
      echo "==> Verifying internal Authentik OIDC endpoint via runner port-forward..."
      $KT port-forward svc/authentik-server -n authentik 8087:80 > /tmp/authentik-pf2.log 2>&1 &
      AK_PF2=$!
      sleep 3
      OIDC_URL_READY=false
      for i in $(seq 1 30); do
        HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
          "http://localhost:8087/application/o/openbao/.well-known/openid-configuration" 2>/dev/null || echo "0")
        if [ "$HTTP_CODE" = "200" ]; then
          echo "  ✅ Internal Authentik OIDC endpoint ready (HTTP $HTTP_CODE)"
          OIDC_URL_READY=true
          break
        fi
        echo "  Waiting for OIDC endpoint ($i/30) — HTTP: ${HTTP_CODE:-unreachable}..."
        sleep 10
      done
      kill $AK_PF2 2>/dev/null || true

      if [ "$OIDC_URL_READY" != "true" ]; then
        echo "⚠️ Internal Authentik OIDC endpoint not ready after 5 min — skipping OpenBao OIDC config"
        echo "   Run the configure-oidc workflow manually once Authentik is ready"
      else
        echo "==> Enabling + configuring OpenBao OIDC auth method..."

        # Enable oidc auth (idempotent)
        $KT exec -n openbao "$BAO_POD" -- \
          env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
          bao auth enable oidc 2>/dev/null || true

        # Configure OIDC using internal service URL (avoids hairpin NAT)
        $KT exec -n openbao "$BAO_POD" -- \
          env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
          bao write auth/oidc/config \
            oidc_discovery_url="http://authentik-server.authentik.svc.cluster.local/application/o/openbao/" \
            oidc_client_id="openbao" \
            oidc_client_secret="$OPENBAO_SECRET" \
            default_role="default" && echo "✅ OpenBao OIDC config written" || echo "⚠️ bao write auth/oidc/config failed (non-critical)"

        # Create admin policy if not exists (policy passed via base64 to avoid column-0 YAML issue)
        ADMIN_POLICY_B64=$(printf 'path "*" {\n  capabilities = ["create", "read", "update", "delete", "list", "sudo"]\n}' | base64 -w0)
        $KT exec -n openbao "$BAO_POD" -- \
          env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
          sh -c "bao policy read admin > /dev/null 2>&1 || echo $ADMIN_POLICY_B64 | base64 -d | bao policy write admin -" 2>/dev/null || true

        # Create default OIDC role for platform admin
        $KT exec -n openbao "$BAO_POD" -- \
          env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
          bao write auth/oidc/role/default \
            bound_audiences="openbao" \
            allowed_redirect_uris="https://openbao.int.${BASE_DOMAIN}/ui/vault/auth/oidc/oidc/callback" \
            allowed_redirect_uris="http://localhost:8250/oidc/callback" \
            user_claim="preferred_username" \
            policies="admin" \
            ttl=8h || true
        echo "✅ OpenBao OIDC role 'default' created"
      fi
    else
      echo "⚠️ OpenBao pod not found — skipping OIDC auth setup"
    fi
  fi
fi

# ── Read InfraWeaver Console OIDC client_secret ───────────────────
# The console is a confidential OAuth2 client; Authentik auto-generates its
# client_secret when the blueprint creates the provider. That generated value
# MUST be written back to OpenBao so the ExternalSecret → console pod uses the
# exact secret Authentik expects — otherwise the code→token exchange fails with
# "invalid_client" and login dies at /auth/signin?error=... ("Server error").
# Use kv patch (NOT put) to preserve the other keys at this OpenBao path
# (nextauth-secret, argocd-token, authentik-token, etc.).
echo "==> Fetching InfraWeaver Console OAuth2 client_secret from Authentik..."
wait_for_provider "InfraWeaver Console Provider"
CONSOLE_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=InfraWeaver%20Console%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

if [ -z "$CONSOLE_SECRET" ]; then
  echo "⚠️ Could not fetch InfraWeaver Console client_secret — console OIDC login will not work"
else
  echo "✅ InfraWeaver Console client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    # kv patch preserves all other keys at secret/platform/infraweaver-console
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv patch secret/platform/infraweaver-console \
        oidc-client-secret="$CONSOLE_SECRET" \
        oidc-client-id="infraweaver-console" > /dev/null 2>&1 \
      && echo "✅ Console OIDC client_secret synced to OpenBao" \
      || echo "⚠️ bao kv patch for console secret failed (non-critical)"

    # Force ExternalSecret resync + console rollout so the corrected secret is
    # picked up immediately instead of waiting for the 1h refresh interval.
    $KT annotate externalsecret infraweaver-console-secret -n infraweaver-console \
      force-sync="$(date +%s)" --overwrite > /dev/null 2>&1 || true
    $KT rollout restart deployment/infraweaver-console -n infraweaver-console > /dev/null 2>&1 || true
    echo "✅ Console ExternalSecret refresh + rollout triggered"
  fi
fi

# ── Read Grafana OIDC client_secret ───────────────────────────────
echo "==> Fetching Grafana OAuth2 client_secret from Authentik..."
wait_for_provider "Grafana Provider"
GRAFANA_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=Grafana%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

if [ -z "$GRAFANA_SECRET" ]; then
  echo "⚠️ Could not fetch Grafana client_secret — OIDC login will not work"
else
  echo "✅ Grafana client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv put secret/platform/grafana-oidc client_secret="$GRAFANA_SECRET" > /dev/null 2>&1 || true
    echo "✅ Grafana OIDC client_secret stored in OpenBao"
  fi
fi

# ── Read Proxmox OIDC client_secret ───────────────────────────────
echo "==> Fetching Proxmox OAuth2 client_secret from Authentik..."
wait_for_provider "Proxmox Provider"
PROXMOX_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=Proxmox%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

if [ -z "$PROXMOX_SECRET" ]; then
  echo "⚠️ Could not fetch Proxmox client_secret — OIDC login for Proxmox will not work"
else
  echo "✅ Proxmox client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv put secret/platform/proxmox-oidc \
        client_secret="$PROXMOX_SECRET" \
        client_id="proxmox" \
        issuer_url="https://auth.${BASE_DOMAIN}/application/o/proxmox/" > /dev/null 2>&1 || true
    echo "✅ Proxmox OIDC client_secret stored in OpenBao at secret/platform/proxmox-oidc"
  fi

  # ── Automatically configure Proxmox OIDC realm via PVE API ──────────────────
  # Reads proxmox_host from cluster.yaml; requires PROXMOX_API_TOKEN env var.
  CLUSTER_YAML="envs/${ENV_NAME}/cluster.yaml"
  PVE_HOST=$(grep 'proxmox_host' "$CLUSTER_YAML" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)"/\1/' | xargs)
  PVE_TOKEN="${PROXMOX_API_TOKEN:-}"

  if [ -z "$PVE_HOST" ] || [ -z "$PVE_TOKEN" ]; then
    echo "ℹ️  PROXMOX_API_TOKEN or proxmox_host not set — skipping automatic PVE realm config"
    echo "   Manual: pveum realm add authentik --type openid \\"
    echo "     --issuer-url https://auth.${BASE_DOMAIN}/application/o/proxmox/ \\"
    echo "     --client-id proxmox --client-key '<secret>' --username-claim preferred_username --autocreate 1"
  else
echo "==> Configuring Proxmox OIDC realm via pveum SSH (host=${PVE_HOST})..."
    ISSUER="https://auth.${BASE_DOMAIN}/application/o/proxmox/"
    # Use pveum via SSH — Proxmox 9.x JSON API /access/realms not universally available
    _PVE_SSH_KEY="${PVE_SSH_KEY:-${HOME}/.ssh/deployer_ed25519}"
    _pveum_cmd() {
      if [ -f "$_PVE_SSH_KEY" ]; then
        ssh -i "$_PVE_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
          root@"${PVE_HOST}" "$@" 2>&1
      elif command -v sshpass >/dev/null 2>&1 && [ -n "${PROXMOX_SSH_PASSWORD:-}" ]; then
        sshpass -p "$PROXMOX_SSH_PASSWORD" \
          ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"${PVE_HOST}" "$@" 2>&1
      else
        echo "SSH_NOT_AVAILABLE"; return 127
      fi
    }
    _REALM_STATUS=$(_pveum_cmd pveum realm list 2>/dev/null)
    if echo "$_REALM_STATUS" | grep -q "authentik"; then
      _pveum_cmd pveum realm modify authentik \
        --issuer-url "${ISSUER}" \
        --client-id "proxmox" \
        --client-key "${PROXMOX_SECRET}" \
        --username-claim preferred_username \
        --autocreate 1 > /dev/null 2>&1 \
        && echo "✅ Proxmox OIDC realm updated" \
        || echo "⚠️  pveum realm modify failed (non-fatal)"
    else
      _pveum_cmd pveum realm add authentik \
        --type openid \
        --issuer-url "${ISSUER}" \
        --client-id "proxmox" \
        --client-key "${PROXMOX_SECRET}" \
        --username-claim preferred_username \
        --autocreate 1 > /dev/null 2>&1 \
        && echo "✅ Proxmox OIDC realm created" \
        || echo "⚠️  pveum realm add failed (may already exist or need manual setup)"
    fi
  fi
fi

# ── Read Gitea OIDC client_secret ─────────────────────────────────
echo "==> Fetching Gitea OAuth2 client_secret from Authentik..."
wait_for_provider "Gitea Provider"
GITEA_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=Gitea%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

if [ -z "$GITEA_SECRET" ]; then
  echo "⚠️ Could not fetch Gitea client_secret — OIDC login will not work"
else
  echo "✅ Gitea client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv put secret/platform/gitea-oidc client_secret="$GITEA_SECRET" > /dev/null 2>&1 || true
    echo "✅ Gitea OIDC client_secret stored in OpenBao"
  fi
fi

# ── Read Forgejo OIDC client_secret ───────────────────────────────
echo "==> Fetching Forgejo OAuth2 client_secret from Authentik..."
wait_for_provider "Forgejo Provider"
FORGEJO_SECRET=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  "${AUTHENTIK_URL}/api/v3/providers/oauth2/?name=Forgejo%20Provider" \
  2>/dev/null | python3 -c "import sys,json; results=json.load(sys.stdin)['results']; print(results[0]['client_secret']) if results else print('')" 2>/dev/null || echo "")

if [ -z "$FORGEJO_SECRET" ]; then
  echo "⚠️ Could not fetch Forgejo client_secret — OIDC login will not work"
else
  echo "✅ Forgejo client_secret retrieved"
  ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$ROOT_TOKEN" ]; then
    $KT exec -n openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao kv put secret/platform/forgejo-oidc client_secret="$FORGEJO_SECRET" client_id="forgejo" > /dev/null 2>&1 || true
    echo "✅ Forgejo OIDC client_secret stored in OpenBao"
  fi
fi

# ── Authentik API helper ──────────────────────────────────────────────────────
# Runs curl inside the Authentik server pod against internal port 9000 (avoids the
# 405 you get through a port-forward). Used below by the embedded-outpost
# proxy-provider assignment — that is the WORKING forward-auth path (TrueNAS,
# Longhorn, n8n). Do not remove it.
#
# The LDAP outpost provisioning that used to live here was REMOVED 2026-08-07.
# The outpost was dead at every link: no Authentik LDAP provider, no LDAP outpost
# object, no token, no OpenBao path, a Service whose VIP was never assigned
# (${METALLB_LDAP_VIP} was never in the CMP allowlist) and a Deployment sitting at
# 0/0 for 54 days. Leaving this block in place would have re-created all of it on
# the next DR rebuild — resurrecting precisely the dead configuration that the
# manifest deletion removes. See docs/BREAK-GLASS.md §10.
ak_exec_curl() {
  local method="$1"; local path="$2"; local data="${3:-}"
  if [ -n "$data" ]; then
    $KT exec -i -n authentik deploy/authentik-server -c server -- \
      curl -sf -X "$method" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://localhost:9000${path}" 2>/dev/null || echo ""
  else
    $KT exec -i -n authentik deploy/authentik-server -c server -- \
      curl -sf \
        -H "Authorization: Bearer $TOKEN" \
        "http://localhost:9000${path}" 2>/dev/null || echo ""
  fi
}

# ── Assign proxy providers to the embedded outpost ───────────────────────────
# Enables Traefik forward-auth for all proxy-protected apps (n8n, Longhorn, etc).
# The blueprint creates the proxy providers + applications but cannot attach them
# to the auto-created embedded outpost, so we do it here once they exist.
echo "==> Assigning proxy providers to embedded outpost..."
# The forward-auth blueprint is imported asynchronously by the Authentik worker,
# so the proxy providers may not exist yet when this script first runs (common on
# a fresh/DR deploy). Poll until the provider count is non-zero AND stable across
# two consecutive reads (blueprint import finished), capped at ~2.5 min, before
# attaching — otherwise a race leaves the embedded outpost empty and every *.int
# host returns Authentik's 404.
PROXY_PKS=""
prev_count=-1
for attempt in $(seq 1 30); do
  PROXY_PKS=$(ak_exec_curl GET "/api/v3/providers/proxy/?page_size=100" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(str(p['pk']) for p in d.get('results',[])))" 2>/dev/null || echo "")
  cur_count=$(printf '%s\n' "$PROXY_PKS" | awk -F, '{print ($0==""?0:NF)}')
  if [ "$cur_count" -gt 0 ] && [ "$cur_count" -eq "$prev_count" ]; then
    echo "  proxy providers stabilized at ${cur_count} (attempt ${attempt})"
    break
  fi
  prev_count=$cur_count
  echo "  waiting for forward-auth blueprint import (proxy providers: ${cur_count})..."
  sleep 5
done
EMB_UUID=$(ak_exec_curl GET "/api/v3/outposts/instances/?page_size=100" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((o['pk'] for o in d.get('results',[]) if o.get('name')=='authentik Embedded Outpost'),''))" 2>/dev/null || echo "")
if [ -n "$PROXY_PKS" ] && [ -n "$EMB_UUID" ]; then
  if ak_exec_curl PATCH "/api/v3/outposts/instances/${EMB_UUID}/" "{\"providers\":[${PROXY_PKS}],\"config\":{\"authentik_host\":\"https://auth.${BASE_DOMAIN}\",\"authentik_host_browser\":\"https://auth.${BASE_DOMAIN}\",\"authentik_host_insecure\":false,\"log_level\":\"info\"}}" >/dev/null; then
    echo "  ✅ Embedded outpost now serves proxy providers: [${PROXY_PKS}]"
    echo "  ✅ Embedded outpost authentik_host set to https://auth.${BASE_DOMAIN}"
  else
    echo "  ⚠️ Failed to patch embedded outpost"
  fi
else
  echo "  ⚠️ No proxy providers or embedded outpost found (skipping)"
fi
