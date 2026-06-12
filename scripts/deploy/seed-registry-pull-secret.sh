#!/usr/bin/env bash
# Seed the Zot registry pull credential into OpenBao so the
# `registry-pull-secret` ExternalSecret (kubernetes/catalog/infraweaver-console/
# manifests/externalsecret-registry.yaml) materializes a dockerconfigjson pull
# secret in the infraweaver-console namespace. Feedback PREVIEW pods (and
# Zot-released prod images after Publish) pull from registry.int.example.com.
#
# Stores at: secret/platform/registry-pull-secret  property: dockerconfigjson
# The ExternalSecret base64-decodes that property, so we store it base64-encoded.
#
# Usage:
#   seed-registry-pull-secret.sh <LOCAL_OPENBAO_URL> <ROOT_TOKEN> [--force]
# Example:
#   seed-registry-pull-secret.sh http://localhost:8200 hvs.xxxxx
#
# Credential source (first match wins):
#   1) $DOCKERCONFIGJSON           — full dockerconfigjson string
#   2) ~/.docker/config.json       — the runner's buildctl/login config (default)
#   3) $REGISTRY_USER + $REGISTRY_PASS (or ~/infraweaver-dispatch/.registry-pass)
#
# Fallback (no OpenBao / GitOps): create the secret directly with kubectl —
#   kubectl -n infraweaver-console create secret docker-registry registry-pull-secret \
#     --docker-server=registry.int.example.com \
#     --docker-username="$REGISTRY_USER" --docker-password="$REGISTRY_PASS"
set -euo pipefail

LOCAL_OPENBAO="${1:-http://localhost:8200}"
ROOT_TOKEN="${2:-}"
FORCE="${3:-}"

REGISTRY="${REGISTRY:-registry.int.example.com}"
DOCKER_CONFIG_PATH="${DOCKER_CONFIG_PATH:-$HOME/.docker/config.json}"
REGISTRY_PASS_FILE="${REGISTRY_PASS_FILE:-$HOME/infraweaver-dispatch/.registry-pass}"

if [ -z "$ROOT_TOKEN" ]; then
  echo "ERROR: ROOT_TOKEN required as second argument" >&2
  exit 1
fi
BAO_HEADER="X-Vault-Token: $ROOT_TOKEN"

# ── Resolve the dockerconfigjson ──────────────────────────────────────────────
build_dockerconfigjson() {
  if [ -n "${DOCKERCONFIGJSON:-}" ]; then
    printf '%s' "$DOCKERCONFIGJSON"
    return
  fi
  if [ -f "$DOCKER_CONFIG_PATH" ] && grep -q "$REGISTRY" "$DOCKER_CONFIG_PATH"; then
    cat "$DOCKER_CONFIG_PATH"
    return
  fi
  local user="${REGISTRY_USER:-}" pass="${REGISTRY_PASS:-}"
  if [ -z "$pass" ] && [ -f "$REGISTRY_PASS_FILE" ]; then
    pass="$(cat "$REGISTRY_PASS_FILE")"
    user="${user:-robot}"
  fi
  if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "ERROR: no credential source found (set DOCKERCONFIGJSON, or ~/.docker/config.json, or REGISTRY_USER/REGISTRY_PASS)" >&2
    exit 1
  fi
  local auth
  auth="$(printf '%s:%s' "$user" "$pass" | base64 -w0)"
  printf '{"auths":{"%s":{"auth":"%s"}}}' "$REGISTRY" "$auth"
}

DOCKERCFG="$(build_dockerconfigjson)"
# Sanity-check it is valid JSON with an auths entry for the registry.
echo "$DOCKERCFG" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('auths',{}).get('$REGISTRY'), 'no auths entry for $REGISTRY'" \
  || { echo "ERROR: resolved dockerconfigjson has no auth for $REGISTRY" >&2; exit 1; }
DOCKERCFG_B64="$(printf '%s' "$DOCKERCFG" | base64 -w0)"

echo "==> Checking secret/platform/registry-pull-secret in OpenBao..."
EXISTING="$(curl -sf "${LOCAL_OPENBAO}/v1/secret/data/platform/registry-pull-secret" \
  -H "$BAO_HEADER" 2>/dev/null || echo "")"

if [ -n "$EXISTING" ] && [ "$FORCE" != "--force" ]; then
  echo "==> registry-pull-secret already present — preserving (pass --force to overwrite)"
  exit 0
fi

curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/registry-pull-secret" \
  -H "$BAO_HEADER" -H "Content-Type: application/json" \
  -d "{\"data\":{\"dockerconfigjson\":\"${DOCKERCFG_B64}\"}}" > /dev/null

echo "==> Seeded secret/platform/registry-pull-secret (registry: ${REGISTRY})"
echo "    ExternalSecret will sync registry-pull-secret into ns infraweaver-console within refreshInterval (24h)."
echo "    Force an immediate sync: kubectl -n infraweaver-console annotate externalsecret registry-pull-secret force-sync=\$(date +%s) --overwrite"
