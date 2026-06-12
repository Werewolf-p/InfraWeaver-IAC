#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/ensure-cloudflare-dns.sh — Ensure Cloudflare DNS records exist for platform endpoints
#
# *.int.${BASE_DOMAIN} is a Cloudflare-proxied wildcard pointing
# at the public ingress (${PUBLIC_INGRESS_IP}). Reachability is public; the perimeter is
# Authentik forward-auth at Traefik, not the network. This script:
#   - removes the legacy public argocd record (ArgoCD lives at argocd.int now)
#   - upserts the *.int wildcard → ${PUBLIC_INGRESS_IP} (proxied)
#
# Usage: ENV_NAME=productie bash scripts/deploy/ensure-cloudflare-dns.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"
if [ -z "${CF_TOKEN:-}" ]; then
  echo "⚠ CLOUDFLARE_API_TOKEN not set — skipping DNS record check"
  exit 0
fi
CF_ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "Authorization: Bearer $CF_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
if [ -z "$CF_ZONE_ID" ]; then
  echo "⚠ Could not find ${BASE_DOMAIN} zone — skipping"
  exit 0
fi

# ── Helper: delete a record by exact name (any type) if it exists ─────────────
_delete_record() {
  local name="$1"
  local rid
  rid=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${name}" \
    -H "Authorization: Bearer $CF_TOKEN" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
  if [ -n "$rid" ]; then
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${rid}" \
      -H "Authorization: Bearer $CF_TOKEN" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print('Deleted: ${name}' if d.get('success') else 'Delete error (${name}): ' + str(d.get('errors','')))"
  else
    echo "  ${name} not in Cloudflare (already removed or never existed)"
  fi
}

# Remove legacy public argocd record — ArgoCD moved to argocd.int.${BASE_DOMAIN}
# (behind Authentik forward-auth)
_delete_record "argocd.${BASE_DOMAIN}"

# ── Upsert the *.int wildcard → public ingress (Cloudflare-proxied) ───────────
# This is the switch that makes every *.int.${BASE_DOMAIN} service reachable from
# anywhere; access is then gated by Authentik forward-auth at Traefik.
INT_NAME="*.int.${BASE_DOMAIN}"
INT_BODY="{\"type\":\"A\",\"name\":\"${INT_NAME}\",\"content\":\"${PUBLIC_INGRESS_IP}\",\"ttl\":1,\"proxied\":true}"
INT_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${INT_NAME}" \
  -H "Authorization: Bearer $CF_TOKEN" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
if [ -z "$INT_ID" ]; then
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" -d "$INT_BODY" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('Created: ${INT_NAME} -> ${PUBLIC_INGRESS_IP} (proxied)' if d.get('success') else 'Error: ' + str(d.get('errors','')))"
else
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${INT_ID}" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" -d "$INT_BODY" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('Updated: ${INT_NAME} -> ${PUBLIC_INGRESS_IP} (proxied)' if d.get('success') else 'Error: ' + str(d.get('errors','')))"
fi
