#!/usr/bin/env bash
# Seed the ghcr.io (GitHub Container Registry) pull credential into OpenBao so the
# `ghcr-pull-secret` ExternalSecrets
# (kubernetes/catalog/infraweaver-console/base/externalsecret-ghcr.yaml and
#  kubernetes/catalog/infraweaver-node/base/externalsecret-ghcr.yaml)
# materialize a dockerconfigjson pull secret in the infraweaver-console and
# infraweaver-system namespaces. This replaces the old hand-applied plaintext
# secret (the leaked PAT) — rotate by re-running this with a fresh token.
#
# Stores at: secret/platform/ghcr-pull-secret  property: dockerconfigjson
# The ExternalSecret base64-decodes that property, so we store it base64-encoded.
#
# The token is read from the environment ONLY — never pass it as an argument
# (arguments leak into shell history and process listings). Use a read-only
# token: a classic PAT with just the `read:packages` scope.
#
# Usage:
#   GHCR_TOKEN=ghp_xxx GHCR_USER=your-gh-user \
#     scripts/deploy/seed-ghcr-pull-secret.sh <LOCAL_OPENBAO_URL> <ROOT_TOKEN> [--force]
# Example:
#   GHCR_TOKEN=$(cat ~/.ghcr-ro-token) GHCR_USER=example-owner \
#     scripts/deploy/seed-ghcr-pull-secret.sh http://localhost:8200 hvs.xxxxx --force
set -euo pipefail

LOCAL_OPENBAO="${1:-http://localhost:8200}"
ROOT_TOKEN="${2:-}"
FORCE="${3:-}"

REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
GHCR_USER="${GHCR_USER:-${GITHUB_ACTOR:-}}"
GHCR_TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$ROOT_TOKEN" ]; then
  echo "ERROR: ROOT_TOKEN required as second argument" >&2
  exit 1
fi
if [ -z "$GHCR_USER" ]; then
  echo "ERROR: set GHCR_USER (GitHub username that owns the token)" >&2
  exit 1
fi
if [ -z "$GHCR_TOKEN" ]; then
  echo "ERROR: set GHCR_TOKEN (read-only read:packages PAT) in the environment" >&2
  exit 1
fi
BAO_HEADER="X-Vault-Token: $ROOT_TOKEN"

# ── Build the dockerconfigjson ────────────────────────────────────────────────
AUTH="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)"
DOCKERCFG="$(printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
  "$REGISTRY" "$GHCR_USER" "$GHCR_TOKEN" "$AUTH")"

# Sanity-check it is valid JSON with an auths entry for the registry.
echo "$DOCKERCFG" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('auths',{}).get('$REGISTRY'), 'no auths entry for $REGISTRY'" \
  || { echo "ERROR: built dockerconfigjson has no auth for $REGISTRY" >&2; exit 1; }
DOCKERCFG_B64="$(printf '%s' "$DOCKERCFG" | base64 -w0)"

echo "==> Checking secret/platform/ghcr-pull-secret in OpenBao..."
EXISTING="$(curl -sf "${LOCAL_OPENBAO}/v1/secret/data/platform/ghcr-pull-secret" \
  -H "$BAO_HEADER" 2>/dev/null || echo "")"

if [ -n "$EXISTING" ] && [ "$FORCE" != "--force" ]; then
  echo "==> ghcr-pull-secret already present — preserving (pass --force to overwrite / rotate)"
  exit 0
fi

curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/ghcr-pull-secret" \
  -H "$BAO_HEADER" -H "Content-Type: application/json" \
  -d "{\"data\":{\"dockerconfigjson\":\"${DOCKERCFG_B64}\"}}" > /dev/null

echo "==> Seeded secret/platform/ghcr-pull-secret (registry: ${REGISTRY}, user: ${GHCR_USER})"
echo "    ExternalSecrets will sync ghcr-pull-secret into ns infraweaver-console and"
echo "    infraweaver-system within refreshInterval (24h). Force an immediate sync:"
for NS in infraweaver-console infraweaver-system; do
  echo "      kubectl -n $NS annotate externalsecret ghcr-pull-secret force-sync=\$(date +%s) --overwrite"
done
