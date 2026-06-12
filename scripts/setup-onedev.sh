#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-onedev.sh — Create infraweaver service account + access token
#
# Idempotent: if the token already exists in OpenBao, exits immediately.
# Creates a single "infraweaver" service account in Onedev with Server
# Administrator rights and generates an access token that all platform
# services (console, API, ArgoCD) use for git authentication.
#
# Usage:
#   ENV_NAME=productie bash scripts/setup-onedev.sh
#
# Environment (all optional — defaults shown):
#   ENV_NAME           Target environment (used to pick kubeconfig)
#   ONEDEV_URL         Onedev API base URL (default: port-forwarded localhost)
#   OPENBAO_ADDR       OpenBao address (default: http://127.0.0.1:8200)
#   VAULT_TOKEN        Root or write-capable OpenBao token (required)
#
# Called by: .github/workflows/full-redeploy.yml (after bootstrap-openbao.sh)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="setup-onedev"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV="${ENV_NAME:-productie}"
KB="${KUBECONFIG:-${HOME}/.kube/config-platform-${ENV}}"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN is required}"
ONEDEV_NAMESPACE="onedev"
SERVICE_ACCOUNT="infraweaver"
TOKEN_NAME="infraweaver-automation"
ONEDEV_PROJECT="${ONEDEV_PROJECT:-InfraWeaver-platform}"
OPENBAO_SECRET_PATH="platform/infraweaver-console"

# ── Port-forward Onedev (if not already provided) ────────────────────────────
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

ONEDEV_URL="${ONEDEV_URL:-}"
if [[ -z "$ONEDEV_URL" ]]; then
  LOCAL_PORT=16610
  ONEDEV_URL="http://127.0.0.1:${LOCAL_PORT}"
  log "Port-forwarding Onedev on localhost:${LOCAL_PORT}..."
  # Wait for the onedev service to exist (up to 3 min) before port-forwarding
  _SVC_WAIT=0
  until kubectl --kubeconfig "$KB" get svc onedev -n "$ONEDEV_NAMESPACE" &>/dev/null; do
    _SVC_WAIT=$((_SVC_WAIT + 1))
    [[ $_SVC_WAIT -ge 18 ]] && { warn "onedev service not found after 3 min — giving up"; exit 1; }
    log "  Waiting for onedev service to appear (${_SVC_WAIT}/18)..."
    sleep 10
  done
  kubectl --kubeconfig "$KB" port-forward svc/onedev "${LOCAL_PORT}:80" -n "$ONEDEV_NAMESPACE" &
  PF_PID=$!
  sleep 5
fi

# ── Idempotency: skip if token already in OpenBao ────────────────────────────
log "Checking for existing Onedev token in OpenBao..."
EXISTING_TOKEN=$(curl -sf \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "${OPENBAO_ADDR}/v1/secret/data/${OPENBAO_SECRET_PATH}" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('data', {}).get('data', {}).get('onedev-token', ''))
except Exception:
    print('')
" || echo "")

if [[ -n "$EXISTING_TOKEN" ]]; then
  ok "Onedev token already exists in OpenBao — skipping setup"
  exit 0
fi

# ── Read admin credentials from OpenBao ──────────────────────────────────────
log "Reading Onedev admin credentials from OpenBao..."
ONEDEV_SECRETS=$(curl -sf \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "${OPENBAO_ADDR}/v1/secret/data/platform/onedev" 2>/dev/null || echo "{}")

ADMIN_USER=$(echo "$ONEDEV_SECRETS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('data', {}).get('data', {}).get('admin-login', ''))
" || echo "")
ADMIN_PASS=$(echo "$ONEDEV_SECRETS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('data', {}).get('data', {}).get('admin-password', ''))
" || echo "")

if [[ -z "$ADMIN_USER" ]] || [[ -z "$ADMIN_PASS" ]]; then
  die "Onedev admin credentials not found in OpenBao at secret/data/platform/onedev — run bootstrap-openbao.sh first"
fi

ADMIN_EMAIL=$(echo "$ONEDEV_SECRETS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('data', {}).get('data', {}).get('admin-email', 'admin@infraweaver.local'))
" || echo "admin@infraweaver.local")

# ── Complete Onedev setup wizard if needed ────────────────────────────────────
# On first boot, Onedev shows a 2-step web wizard before the REST API works.
# INITIAL_ADMIN_* env vars pre-fill the form but do NOT bypass it.
# We automate the wizard here before the API wait loop.
log "Checking if Onedev setup wizard needs to be completed..."
_wizard_api=$(curl -sk -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/users/1" 2>/dev/null || echo "000")

if [[ "$_wizard_api" != "200" ]]; then
  log "Wizard not yet complete (API HTTP: $_wizard_api) — waiting for /~init page..."
  _COOKIE_JAR=$(mktemp)

  # Wait for /~init to be available (Onedev may still be starting up)
  for i in $(seq 1 30); do
    _init_http=$(curl -sk -o /dev/null -w "%{http_code}" \
      -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
      "${ONEDEV_URL}/~init" 2>/dev/null || echo "000")
    if [[ "$_init_http" == "200" ]]; then
      log "  /~init available"
      break
    fi
    [[ "$i" -eq 30 ]] && die "Onedev /~init not available after 5 minutes (HTTP: $_init_http)"
    log "  Attempt $i/30: HTTP $_init_http — waiting 10s..."
    sleep 10
  done

  # Step 1: Submit admin credentials form
  log "Completing wizard step 1: admin credentials..."
  curl -sk -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
    "${ONEDEV_URL}/~init" -o /tmp/od_wizard1.html 2>/dev/null

  _A1=$(python3 -c "import re; h=open('/tmp/od_wizard1.html').read(); m=re.search(r'action=\"(/[^\"]+)\"', h); print(m.group(1) if m else '')" 2>/dev/null || true)
  _I1=$(python3 -c "import re; h=open('/tmp/od_wizard1.html').read(); m=re.search(r'<form[^>]+id=\"([^\"]+)\"', h); print(m.group(1) if m else 'id4')" 2>/dev/null || true)

  if [[ -n "$_A1" ]]; then
    curl -sk -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
      -o /tmp/od_wizard_r1.html \
      -X POST "${ONEDEV_URL}${_A1}" \
      --data-urlencode "${_I1}_hf_0=" \
      --data-urlencode "content:groups:1:properties:2:value:content:input=${ADMIN_USER}" \
      --data-urlencode "content:groups:1:properties:3:value:input=${ADMIN_PASS}" \
      --data-urlencode "content:groups:1:properties:3:value:inputAgain=${ADMIN_PASS}" \
      --data-urlencode "content:groups:1:properties:4:value:content:input=" \
      --data-urlencode "content:groups:1:properties:7:value:content:input=${ADMIN_EMAIL}" \
      --data-urlencode "next=" 2>/dev/null || true
    sleep 2

    # Step 2: Submit server URL form with Finish button
    # After admin creds step, wizard shows the server URL step with endActions:finish
    log "Completing wizard step 2: server URL..."
    curl -sk -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
      "${ONEDEV_URL}/~init" -o /tmp/od_wizard2.html 2>/dev/null

    _A2=$(python3 -c "import re; h=open('/tmp/od_wizard2.html').read(); m=re.search(r'action=\"(/[^\"]+)\"', h); print(m.group(1) if m else '')" 2>/dev/null || true)
    _I2=$(python3 -c "import re; h=open('/tmp/od_wizard2.html').read(); m=re.search(r'<form[^>]+id=\"([^\"]+)\"', h); print(m.group(1) if m else 'id4')" 2>/dev/null || true)
    _F2=$(python3 -c "import re; h=open('/tmp/od_wizard2.html').read(); m=re.search(r'name=\"(content[^\"]+)\"', h); print(m.group(1) if m else '')" 2>/dev/null || true)
    # Check if this is the final step (has endActions:finish button)
    _FINISH=$(python3 -c "import re; h=open('/tmp/od_wizard2.html').read(); print('yes' if re.search(r'endActions:finish', h) else 'no')" 2>/dev/null || echo "no")

    if [[ -n "$_A2" ]] && [[ "$_FINISH" == "yes" ]]; then
      curl -sk -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
        -o /tmp/od_wizard_r2.html \
        -X POST "${ONEDEV_URL}${_A2}" \
        --data-urlencode "${_I2}_hf_0=" \
        ${_F2:+--data-urlencode "${_F2}=${ONEDEV_URL}"} \
        --data-urlencode "endActions:finish=Finish" 2>/dev/null || true
      sleep 2
      log "  Wizard step 2 (server URL) submitted with Finish"
    elif [[ -n "$_A2" ]] && [[ -n "$_F2" ]]; then
      # Multi-step wizard: intermediate step, just click Next
      curl -sk -c "$_COOKIE_JAR" -b "$_COOKIE_JAR" \
        -o /tmp/od_wizard_r2.html \
        -X POST "${ONEDEV_URL}${_A2}" \
        --data-urlencode "${_I2}_hf_0=" \
        --data-urlencode "${_F2}=${ONEDEV_URL}" \
        --data-urlencode "next=" 2>/dev/null || true
      sleep 2
      log "  Wizard step 2 submitted (intermediate step)"
    else
      log "  No step 2 form found — wizard may already be complete"
    fi
  else
    warn "  Could not parse wizard form — setup wizard may need manual completion"
  fi

  rm -f "$_COOKIE_JAR" /tmp/od_wizard*.html 2>/dev/null || true
  ok "Wizard completion attempted"
else
  ok "Onedev wizard already complete (API HTTP: $_wizard_api)"
fi

# ── Wait for Onedev to be ready ───────────────────────────────────────────────
log "Waiting for Onedev API to be ready (up to 5 min)..."
for i in $(seq 1 30); do
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${ONEDEV_URL}/~api/users/1" 2>/dev/null || echo "000")
  if [[ "$HTTP" == "200" ]]; then
    ok "Onedev API ready (HTTP $HTTP)"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    die "Onedev not ready after 5 minutes (last HTTP: $HTTP)"
  fi
  log "  Attempt $i/30: HTTP $HTTP — waiting 10s..."
  sleep 10
done

# ── Create or find the infraweaver service account ───────────────────────────
log "Checking for '${SERVICE_ACCOUNT}' user in Onedev..."
USER_LIST=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/users?offset=0&count=500" 2>/dev/null || echo "[]")

USER_ID=$(echo "$USER_LIST" | python3 -c "
import json,sys
name='${SERVICE_ACCOUNT}'
try:
    us = json.load(sys.stdin)
    for u in (us if isinstance(us, list) else []):
        if u.get('name') == name:
            print(u['id']); break
except Exception:
    pass
" 2>/dev/null || true)

if [[ -z "$USER_ID" ]]; then
  log "Creating '${SERVICE_ACCOUNT}' service account..."
  SVC_PASS=$(openssl rand -base64 24 | tr -d '=+/')
  USER_ID=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X POST "${ONEDEV_URL}/~api/users" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${SERVICE_ACCOUNT}\",\"password\":\"${SVC_PASS}\",\"emailAddress\":\"infraweaver@infraweaver.internal\",\"type\":\"SERVICE\"}" \
    2>/dev/null || echo "")
  [[ -n "$USER_ID" ]] || die "Failed to create '${SERVICE_ACCOUNT}' user in Onedev"
  ok "Created '${SERVICE_ACCOUNT}' user (ID: $USER_ID)"
else
  ok "Found existing '${SERVICE_ACCOUNT}' user (ID: $USER_ID)"
fi

# ── Delete any pre-existing token with the same name (token rotation) ─────────
log "Checking for existing '${TOKEN_NAME}' tokens..."
EXISTING_TOKENS=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/users/${USER_ID}/access-tokens" \
  2>/dev/null || echo "[]")

OLD_TOKEN_IDS=$(echo "$EXISTING_TOKENS" | python3 -c "
import json,sys
name='${TOKEN_NAME}'
try:
    ts = json.load(sys.stdin)
    for t in (ts if isinstance(ts, list) else []):
        if t.get('name') == name:
            print(t['id'])
except Exception:
    pass
" 2>/dev/null || true)
while IFS= read -r OLD_ID; do
  [[ -z "$OLD_ID" ]] && continue
  curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X DELETE "${ONEDEV_URL}/~api/access-tokens/${OLD_ID}" 2>/dev/null && \
    log "  Deleted old token ID: $OLD_ID"
done <<< "$OLD_TOKEN_IDS"

# ── Generate access token ─────────────────────────────────────────────────────
# Onedev API: POST /~api/access-tokens with {"name","ownerId","hasOwnerPermissions"}
# Returns the new token ID (integer). Then GET /~api/access-tokens/{ID} to get the value.
log "Generating access token for '${SERVICE_ACCOUNT}'..."
TOKEN_ID=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X POST "${ONEDEV_URL}/~api/access-tokens" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${TOKEN_NAME}\",\"ownerId\":${USER_ID},\"hasOwnerPermissions\":true}" \
  2>/dev/null || echo "")

if [[ -z "$TOKEN_ID" ]]; then
  die "Onedev returned empty response when creating access token"
fi

TOKEN_DATA=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/access-tokens/${TOKEN_ID}" \
  2>/dev/null || echo "")

TOKEN=$(echo "$TOKEN_DATA" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('value', ''))
" 2>/dev/null || echo "")

[[ -n "$TOKEN" ]] || die "Could not extract token value from Onedev response: $TOKEN_DATA"
ok "Access token generated for '${SERVICE_ACCOUNT}' (ID: ${TOKEN_ID})"

# ── Add service account to Server Administrators group ────────────────────────
log "Adding '${SERVICE_ACCOUNT}' to Server Administrators group..."
_GROUPS_RAW=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/groups?offset=0&count=100" 2>/dev/null || echo "[]")

ADMIN_GROUP_ID=$(echo "$_GROUPS_RAW" | python3 -c "
import json,sys
try:
    gs = json.load(sys.stdin)
    for g in (gs if isinstance(gs, list) else []):
        if g.get('administrator') is True:
            print(g['id']); break
except Exception:
    pass
" 2>/dev/null || true)

if [[ -n "$ADMIN_GROUP_ID" ]]; then
  _MEMBERS_RAW=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${ONEDEV_URL}/~api/groups/${ADMIN_GROUP_ID}/memberships" 2>/dev/null || echo "[]")

  ALREADY_MEMBER=$(echo "$_MEMBERS_RAW" | python3 -c "
import json,sys
try:
    ms = json.load(sys.stdin)
    if any(m.get('userId') == ${USER_ID} for m in (ms if isinstance(ms, list) else [])):
        print('yes')
except Exception:
    pass
" 2>/dev/null || true)

  if [[ "$ALREADY_MEMBER" != "yes" ]]; then
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X POST "${ONEDEV_URL}/~api/memberships" \
      -H "Content-Type: application/json" \
      -d "{\"userId\":${USER_ID},\"groupId\":${ADMIN_GROUP_ID}}" > /dev/null 2>&1 \
      && ok "Added '${SERVICE_ACCOUNT}' to Server Administrators" || true
  else
    ok "'${SERVICE_ACCOUNT}' already in Server Administrators"
  fi
else
  warn "Server Administrators group not found — it will be created by the bootstrap job after ArgoCD syncs"
fi

# ── Create InfraWeaver-platform project if it doesn't exist ──────────────────
log "Checking for '${ONEDEV_PROJECT}' project..."
_PROJECTS_RAW=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${ONEDEV_URL}/~api/projects?offset=0&count=100" 2>/dev/null || echo "[]")

PROJECT_ID=$(echo "$_PROJECTS_RAW" | python3 -c "
import json,sys
name='${ONEDEV_PROJECT}'
try:
    ps = json.load(sys.stdin)
    for p in (ps if isinstance(ps, list) else []):
        if p.get('name') == name or p.get('path') == name:
            print(p['id']); break
except Exception:
    pass
" 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
  log "Creating '${ONEDEV_PROJECT}' project..."
  PROJECT_ID=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X POST "${ONEDEV_URL}/~api/projects" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${ONEDEV_PROJECT}\",\"description\":\"InfraWeaver Platform IaC repository\",\"codeManagement\":true,\"issueManagement\":false,\"timeTracking\":false,\"codeAnalysisSetting\":{},\"gitPackConfig\":{}}" \
    2>/dev/null || echo "")
  [[ -n "$PROJECT_ID" ]] || warn "Could not create project (may already exist under a different ID format)"
  ok "Created project '${ONEDEV_PROJECT}' (ID: $PROJECT_ID)"
else
  ok "Project '${ONEDEV_PROJECT}' already exists (ID: $PROJECT_ID)"
fi

# ── Grant infraweaver Project Owner access ────────────────────────────────────
if [[ -n "$PROJECT_ID" ]] && [[ -n "$USER_ID" ]]; then
  # Role ID 1 = Project Owner in Onedev defaults
  _OWNER_ROLE_ID=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${ONEDEV_URL}/~api/roles?offset=0&count=50" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    rs=json.load(sys.stdin)
    for r in (rs if isinstance(rs,list) else []):
        if r.get('name')=='Project Owner': print(r['id']); break
except Exception: pass
" 2>/dev/null || echo "1")
  _OWNER_ROLE_ID="${_OWNER_ROLE_ID:-1}"

  # Check if authorization already exists
  _EXISTING_AUTH=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${ONEDEV_URL}/~api/projects/${PROJECT_ID}/user-authorizations" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    auths=json.load(sys.stdin)
    for a in (auths if isinstance(auths,list) else []):
        if a.get('userId')==${USER_ID}: print('yes'); break
except Exception: pass
" 2>/dev/null || true)

  if [[ "$_EXISTING_AUTH" != "yes" ]]; then
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X POST "${ONEDEV_URL}/~api/user-authorizations" \
      -H "Content-Type: application/json" \
      -d "{\"userId\":${USER_ID},\"projectId\":${PROJECT_ID},\"roleId\":${_OWNER_ROLE_ID}}" \
      > /dev/null 2>&1 && ok "Granted '${SERVICE_ACCOUNT}' Project Owner access to '${ONEDEV_PROJECT}'" || \
      warn "Could not grant project access — infraweaver may need manual project access"
  else
    ok "'${SERVICE_ACCOUNT}' already has access to '${ONEDEV_PROJECT}'"
  fi
fi

# ── Store token in OpenBao ────────────────────────────────────────────────────
log "Storing Onedev token in OpenBao..."

# Read-modify-write: preserve all existing keys
EXISTING_DATA=$(curl -sf \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "${OPENBAO_ADDR}/v1/secret/data/${OPENBAO_SECRET_PATH}" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(json.dumps(d.get('data', {}).get('data', {})))
except Exception:
    print('{}')
" || echo "{}")

PATCHED_DATA=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['onedev-token'] = sys.argv[2]
print(json.dumps({'data': d}))
" "$EXISTING_DATA" "$TOKEN")

curl -sf -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  "${OPENBAO_ADDR}/v1/secret/data/${OPENBAO_SECRET_PATH}" \
  -d "$PATCHED_DATA" > /dev/null

ok "Token stored in OpenBao at secret/data/${OPENBAO_SECRET_PATH}[onedev-token]"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Onedev service account setup complete            ║"
echo "╚══════════════════════════════════════════════════════╝"
ok "Service account '${SERVICE_ACCOUNT}' ready in Onedev"
ok "Access token stored in OpenBao"
ok "ArgoCD repo creds ExternalSecret will refresh within 1h (or force: kubectl annotate es argocd-onedev-repo-creds -n argocd force-sync=true)"
echo ""
