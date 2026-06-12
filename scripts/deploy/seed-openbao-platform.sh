#!/usr/bin/env bash
# Seed or patch new platform secrets in OpenBao:
#   - secret/platform/minio-velero   (MinIO credentials for Velero backups)
#   - secret/platform/discord        (Discord webhook URL for Alertmanager)
#   - secret/platform/onedev         (OneDev admin password)
#
# Usage: seed-openbao-platform.sh <LOCAL_OPENBAO_URL> <ROOT_TOKEN>
# Example: seed-openbao-platform.sh http://localhost:8200 hvs.xxxxx
set -euo pipefail

LOCAL_OPENBAO="${1:-http://localhost:8200}"
ROOT_TOKEN="${2:-}"

if [ -z "$ROOT_TOKEN" ]; then
  echo "ERROR: ROOT_TOKEN required as second argument"
  exit 1
fi

BAO_HEADER="X-Vault-Token: $ROOT_TOKEN"

# Generate a random password
rand_b64() { openssl rand -base64 "${1:-24}" | tr -d '=+/' | cut -c1-"${1:-24}"; }

echo "==> Seeding platform secrets in OpenBao..."

# ── MinIO Velero credentials ──────────────────────────────────────────────────
echo "==> Checking secret/platform/minio-velero..."
EXISTING=$(curl -sf "${LOCAL_OPENBAO}/v1/secret/data/platform/minio-velero" \
  -H "$BAO_HEADER" 2>/dev/null || echo "")

if [ -z "$EXISTING" ]; then
  # Create new MinIO credentials
  MINIO_ACCESS_KEY="infraweaver-velero"
  MINIO_SECRET_KEY=$(rand_b64 32)
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/minio-velero" \
    -H "$BAO_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"data\":{\"access_key\":\"${MINIO_ACCESS_KEY}\",\"secret_key\":\"${MINIO_SECRET_KEY}\"}}" > /dev/null
  echo "==> MinIO Velero credentials created (access_key: ${MINIO_ACCESS_KEY})"
else
  echo "==> MinIO Velero credentials already exist — preserving"
fi

# ── Discord webhook ───────────────────────────────────────────────────────────
echo "==> Checking secret/platform/discord..."
EXISTING_DISCORD=$(curl -sf "${LOCAL_OPENBAO}/v1/secret/data/platform/discord" \
  -H "$BAO_HEADER" 2>/dev/null || echo "")

if [ -z "$EXISTING_DISCORD" ]; then
  # Create placeholder — user must update with real Discord webhook URL
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/discord" \
    -H "$BAO_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"data":{"webhook_url":"https://discord.com/api/webhooks/PLACEHOLDER/PLACEHOLDER"}}' > /dev/null
  echo "==> Discord webhook placeholder created"
  echo "    !! Update with real URL: bao kv put secret/platform/discord webhook_url='https://discord.com/api/webhooks/...'"
else
  echo "==> Discord webhook already configured — preserving"
fi

# ── OneDev admin password ─────────────────────────────────────────────────────
echo "==> Checking secret/platform/onedev..."
EXISTING_ONEDEV=$(curl -sf "${LOCAL_OPENBAO}/v1/secret/data/platform/onedev" \
  -H "$BAO_HEADER" 2>/dev/null || echo "")

if [ -z "$EXISTING_ONEDEV" ]; then
  ONEDEV_PASS=$(openssl rand -base64 24 | tr -d '/+=')
  curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/onedev" \
    -H "$BAO_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"data\":{\"admin-password\":\"${ONEDEV_PASS}\"}}" > /dev/null
  echo "==> OneDev admin password created (auto-generated)"
  echo "    Login at https://onedev.int.${BASE_DOMAIN} with user 'admin' and the generated password"
  echo "    Retrieve: bao kv get secret/platform/onedev"
else
  echo "==> OneDev secret already configured — preserving"
fi

echo "==> Platform secrets seeding complete"
