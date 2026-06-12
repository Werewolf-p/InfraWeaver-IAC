#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/send-welcome-emails.sh — Send welcome/recovery emails to non-admin users
#
# Usage: ENV_NAME=productie bash scripts/deploy/send-welcome-emails.sh
# Called by: .github/workflows/full-redeploy.yml
# Env required: AUTHENTIK_ADMIN_TOKEN, SMTP_USERNAME, SMTP_PASSWORD
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"

KB=~/.kube/config-platform-${ENV_NAME}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"

_NONADMIN_PY="aW1wb3J0IHlhbWwKdXNlcnMgPSB5YW1sLnNhZmVfbG9hZChvcGVuKCJ1c2Vycy55YW1sIikpWyJ1c2VycyJdCmZvciB1LCBkIGluIHVzZXJzLml0ZW1zKCk6CiAgICBpZiBkLmdldCgiYWNjZXNzX2xldmVsIikgIT0gImFkbWluIiBhbmQgZC5nZXQoInNlbmRfcmVjb3ZlcnlfZW1haWwiKSBhbmQgZC5nZXQoImVtYWlsIik6CiAgICAgICAgcHJpbnQodSkK"
NON_ADMIN_USERS=$(echo "$_NONADMIN_PY" | base64 -d | python3)

if [ -z "$NON_ADMIN_USERS" ]; then
  echo "==> No non-admin users with send_recovery_email + email — skipping"
  exit 0
fi

AK_TOKEN="${AUTHENTIK_ADMIN_TOKEN:-}"
if [ -z "$AK_TOKEN" ]; then
  echo "⚠️ No Authentik token available — skipping non-admin welcome emails"
  exit 0
fi

$KT port-forward svc/authentik-server -n authentik 8086:80 > /tmp/ak-pf-welcome.log 2>&1 &
WELCOME_PF_PID=$!
trap 'kill $WELCOME_PF_PID 2>/dev/null || true' EXIT
sleep 4

for USERNAME in $NON_ADMIN_USERS; do
  echo "==> Generating recovery link + sending welcome email for ${USERNAME}..."
  USER_ID=$(curl -sf \
    -H "Authorization: Bearer $AK_TOKEN" \
    "http://localhost:8086/api/v3/core/users/?username=${USERNAME}" \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('results',[]); print(r[0]['pk'] if r else '')" || echo "")
  if [ -n "$USER_ID" ]; then
    RAW_LINK=$(curl -sf -X POST \
      -H "Authorization: Bearer $AK_TOKEN" \
      -H "Content-Type: application/json" \
      "http://localhost:8086/api/v3/core/users/$USER_ID/recovery/" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('link',''))" || echo "")
    LINK=$(echo "$RAW_LINK" | sed "s|http://localhost:8086|https://auth.${BASE_DOMAIN}|g")
    if [ -n "$LINK" ]; then
      python3 scripts/send-welcome-email.py --username "$USERNAME" --recovery-link "$LINK" || true
    else
      echo "  ⚠️ Could not generate recovery link for ${USERNAME} — skipping"
    fi
  else
    echo "  ⚠️ User ${USERNAME} not found in Authentik — skipping"
  fi
done

echo "✅ Non-admin welcome emails sent"
