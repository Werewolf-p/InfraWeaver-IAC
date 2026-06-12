#!/usr/bin/env bash
# seed-catalog-secrets.sh — Dynamically seed catalog app secrets into OpenBao
#
# ─────────────────────────────────────────────────────────────────────────────
# Architecture Overview
# ─────────────────────────────────────────────────────────────────────────────
#
# This script replaces the old approach of hardcoded per-app secret blocks
# in bootstrap-openbao.sh. Instead, each catalog app declares its secret
# requirements in catalog.yaml under a `secrets:` section:
#
#   secrets:
#     path: platform/wiki          # → stored at secret/data/platform/wiki
#     keys:
#       admin-password:
#         type: password           # random: openssl rand -base64 24
#       admin-email:
#         type: static
#         value: "admin@infraweaver.local"
#       postgresql-password:
#         type: password
#
# This script:
#   1. Reads platform.yaml to find enabled catalog apps
#   2. For each enabled app: reads catalog.yaml secrets section
#   3. For each key: checks if it already exists in OpenBao
#   4. If not present: generates password or uses static value
#   5. Writes the complete secret as a single atomic KV put
#
# IDEMPOTENT: Never overwrites existing secrets. Safe to run on every deploy.
# ATOMIC:     All keys for an app are written in a single KV v2 write
#             (existing keys are preserved via read-modify-write).
#
# Usage:
#   OPENBAO_ADDR=http://... VAULT_TOKEN=... bash scripts/seed-catalog-secrets.sh
#   OPENBAO_ADDR=http://... VAULT_TOKEN=... bash scripts/seed-catalog-secrets.sh --dry-run
#
# Environment:
#   OPENBAO_ADDR    OpenBao server URL (e.g. http://127.0.0.1:8200)
#   VAULT_TOKEN     Root or write-capable OpenBao token
#   REPO_ROOT       Path to repo root (default: parent of this script)
#
# Called by: scripts/deploy/bootstrap-openbao.sh (after OpenBao init)
# Dependencies: python3 (PyYAML), openssl, curl
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_NAME="seed-catalog-secrets"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DRY_RUN=false
STATS_SEEDED=0
STATS_EXISTING=0
STATS_APPS=0

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

PLATFORM_YAML="$REPO_ROOT/platform.yaml"
CATALOG_DIR="$REPO_ROOT/kubernetes/catalog"

log()    { echo "[seed-secrets] $*"; }
dry()    { echo "[seed-secrets] [dry-run] $*"; }

# ── Validate prerequisites ────────────────────────────────────────────────────
[[ -f "$PLATFORM_YAML" ]] || { warn "platform.yaml not found at $PLATFORM_YAML"; exit 1; }
[[ -n "${OPENBAO_ADDR:-}" ]]  || { warn "OPENBAO_ADDR not set"; exit 1; }
[[ -n "${VAULT_TOKEN:-}" ]]   || { warn "VAULT_TOKEN not set"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { warn "python3 with PyYAML is required"; exit 1; }

# ── Read enabled apps from platform.yaml ─────────────────────────────────────
ENABLED_APPS="$(python3 - "$PLATFORM_YAML" <<'PYEOF'
import yaml, sys
data = yaml.safe_load(open(sys.argv[1]))
apps = data.get('catalog', {}).get('enabled', [])
for app in apps:
    print(app)
PYEOF
)"

log "Seeding catalog secrets for enabled apps..."
log ""

# ── Helper: check if a key exists in OpenBao KV v2 ───────────────────────────
openbao_key_exists() {
  local path="$1"
  local key="$2"
  local response
  # Note: curl -s (not -sf) — 404 means key doesn't exist (not a script error)
  response=$(curl -s \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "${OPENBAO_ADDR}/v1/secret/data/${path}" 2>/dev/null || echo '{}')
  python3 - "$response" "$key" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    val = d.get('data', {}).get('data', {}).get(sys.argv[2], '')
    sys.exit(0 if val else 1)
except Exception:
    sys.exit(1)
PYEOF
}

# ── Helper: read all existing keys from OpenBao KV v2 ────────────────────────
openbao_read_all() {
  local path="$1"
  # Note: -f is intentionally NOT used here — a 404 (path not yet created) is expected
  # and should return an empty dict, not a script failure.
  curl -s \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "${OPENBAO_ADDR}/v1/secret/data/${path}" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(json.dumps(d.get('data', {}).get('data', {})))
except Exception:
    print('{}')
" || echo '{}'
}

# ── Helper: write key-value pairs to OpenBao KV v2 (patch: read-modify-write) ─
openbao_patch() {
  local path="$1"
  local data_json="$2"   # JSON object of keys to write
  # KV v2 patch: merge new keys into existing data (preserves unrelated keys)
  curl -sf -X PATCH \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/merge-patch+json" \
    "${OPENBAO_ADDR}/v1/secret/data/${path}" \
    -d "{\"data\": $data_json}" > /dev/null 2>&1 || {
    # PATCH is not always supported on all OpenBao versions — fall back to POST
    # Read existing, merge, write back
    EXISTING=$(openbao_read_all "$path")
    MERGED=$(python3 - "$EXISTING" "$data_json" <<'PYEOF'
import json, sys
existing = json.loads(sys.argv[1])
new_data = json.loads(sys.argv[2])
existing.update(new_data)
print(json.dumps(existing))
PYEOF
)
    curl -sf -X POST \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      -H "Content-Type: application/json" \
      "${OPENBAO_ADDR}/v1/secret/data/${path}" \
      -d "{\"data\": $MERGED}" > /dev/null
  }
}

# ── Helper: generate a random password ───────────────────────────────────────
generate_password() {
  local length="${1:-24}"
  openssl rand -base64 "$((length * 3 / 4 + 1))" | tr -d '=+/' | head -c "$length"
}

# ── Main: process each enabled app ───────────────────────────────────────────
while IFS= read -r app; do
  [[ -z "$app" ]] && continue

  catalog_yaml="$CATALOG_DIR/$app/catalog.yaml"
  [[ -f "$catalog_yaml" ]] || { warn "No catalog.yaml for $app — skipping"; continue; }

  # Check if this app has a secrets section
  has_secrets="$(python3 - "$catalog_yaml" <<'PYEOF'
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
print('yes' if d.get('secrets') else 'no')
PYEOF
)"
  [[ "$has_secrets" == "yes" ]] || {
    log "$app — no secrets: section in catalog.yaml, skipping"
    continue
  }

  # Read the secrets schema
  secrets_json="$(python3 - "$catalog_yaml" <<'PYEOF'
import yaml, json, sys
d = yaml.safe_load(open(sys.argv[1]))
s = d.get('secrets', {})
print(json.dumps(s))
PYEOF
)"

  SECRET_PATH="$(python3 - "$secrets_json" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get('path', ''))
PYEOF
)"

  [[ -n "$SECRET_PATH" ]] || { warn "$app — secrets.path is empty — skipping"; continue; }

  log "Processing: $app → secret/data/$SECRET_PATH"
  STATS_APPS=$((STATS_APPS + 1))

  # Read all keys for this app
  KEYS_JSON="$(python3 - "$secrets_json" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
print(json.dumps(d.get('keys', {})))
PYEOF
)"

  # Read existing values from OpenBao
  EXISTING_DATA="$(openbao_read_all "$SECRET_PATH")"

  # Build the data object: only include keys that don't already have a value
  NEW_DATA="{}"
  KEYS_TO_WRITE=()

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue

    # Check if key already has a value in OpenBao
    EXISTING_VAL="$(python3 - "$EXISTING_DATA" "$key" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get(sys.argv[2], ''))
except Exception:
    print('')
PYEOF
)"

    if [[ -n "$EXISTING_VAL" ]]; then
      log "  ↪ $key — already exists, preserving"
      STATS_EXISTING=$((STATS_EXISTING + 1))
      continue
    fi

    # Key doesn't exist — generate or use static value
    KEY_SPEC="$(python3 - "$KEYS_JSON" "$key" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
print(json.dumps(d.get(sys.argv[2], {})))
PYEOF
)"

    KEY_TYPE="$(python3 - "$KEY_SPEC" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get('type', 'password'))
PYEOF
)"

    if [[ "$KEY_TYPE" == "static" ]]; then
      KEY_VALUE="$(python3 - "$KEY_SPEC" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get('value', ''))
PYEOF
)"
    elif [[ "$KEY_TYPE" == "htpasswd" ]]; then
      # htpasswd type: generate a bcrypt htpasswd entry
      # username comes from the key spec; the password key in the same secret block provides the raw password
      HTPASSWD_USERNAME="$(python3 - "$KEY_SPEC" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get('username', 'admin'))
PYEOF
)"
      # Generate a fresh random password for htpasswd (stored separately under 'password' key)
      HTPASSWD_PASS="$(generate_password 32)"
      # Use htpasswd binary if available, else python passlib, else openssl
      if command -v htpasswd &>/dev/null; then
        KEY_VALUE="$(htpasswd -nbB "$HTPASSWD_USERNAME" "$HTPASSWD_PASS")"
      elif python3 -c "import passlib" &>/dev/null 2>&1; then
        KEY_VALUE="$(python3 -c "
from passlib.apache import HtpasswdFile
h = HtpasswdFile()
h.set_password('$HTPASSWD_USERNAME', '$HTPASSWD_PASS')
print(h.to_string().decode().strip())
")"
      else
        # Fallback: use openssl for bcrypt hash
        HASH="$(python3 -c "import crypt; print(crypt.crypt('$HTPASSWD_PASS', crypt.mksalt(crypt.METHOD_BLOWFISH)))")"
        KEY_VALUE="${HTPASSWD_USERNAME}:${HASH}"
      fi
      # Also store the raw password so the console/CI can use it for docker login
      NEW_DATA="$(python3 - "$NEW_DATA" "password" "$HTPASSWD_PASS" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
if sys.argv[2] not in d:
    d[sys.argv[2]] = sys.argv[3]
print(json.dumps(d))
PYEOF
)"
      log "  ✦ password — generated (from htpasswd)"
    else
      # password type: generate random value
      KEY_LENGTH="$(python3 - "$KEY_SPEC" <<'PYEOF'
import json, sys
print(json.loads(sys.argv[1]).get('length', 24))
PYEOF
)"
      KEY_VALUE="$(generate_password "$KEY_LENGTH")"
    fi

    if $DRY_RUN; then
      dry "$app/$key — would set ($KEY_TYPE)"
    else
      # Add to the new data map
      NEW_DATA="$(python3 - "$NEW_DATA" "$key" "$KEY_VALUE" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
d[sys.argv[2]] = sys.argv[3]
print(json.dumps(d))
PYEOF
)"
      KEYS_TO_WRITE+=("$key")
      log "  ✦ $key — generated ($KEY_TYPE)"
      STATS_SEEDED=$((STATS_SEEDED + 1))
    fi
  done < <(python3 - "$KEYS_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
for k in d.keys():
    print(k)
PYEOF
)

  # Write new keys to OpenBao (only if there are keys to write)
  if [[ "${#KEYS_TO_WRITE[@]}" -gt 0 ]]; then
    log "  Writing ${#KEYS_TO_WRITE[@]} new key(s) to OpenBao..."
    openbao_patch "$SECRET_PATH" "$NEW_DATA"
    ok "$app — wrote keys: ${KEYS_TO_WRITE[*]}"
  else
    log "  $app — all keys already exist, nothing to write"
  fi

  log ""
done <<< "$ENABLED_APPS"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Catalog secrets seeding complete"
echo "  Apps processed:  $STATS_APPS"
echo "  Keys seeded:     $STATS_SEEDED  (newly generated)"
echo "  Keys preserved:  $STATS_EXISTING  (already existed)"
if $DRY_RUN; then echo "  ⚠  Dry run — no changes written"; fi
echo "═══════════════════════════════════════════════════════"
