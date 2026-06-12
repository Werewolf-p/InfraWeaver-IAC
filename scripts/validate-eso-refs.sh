#!/usr/bin/env bash
# validate-eso-refs.sh — Validate all ExternalSecret secretStoreRef names
#
# Root cause prevention: In 2025-05, the Gatus ExternalSecret used
# secretStoreRef.name: openbao-backend (which does not exist) instead of
# secretStoreRef.name: openbao (the actual ClusterSecretStore name).
# This caused a CrashLoopBackOff on Gatus pods.
#
# This script scans all ExternalSecret and ClusterExternalSecret manifests
# and validates that their secretStoreRef.name matches an actual
# ClusterSecretStore or SecretStore in the repository.
#
# Exits 1 if any invalid reference is found (must be run in repo root).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
VALID_STORES=()
INVALID_REFS=()

# ── Discover all ClusterSecretStore + SecretStore names in repo ───────────────
while IFS= read -r file; do
  while IFS= read -r name; do
    [ -n "$name" ] && VALID_STORES+=("$name")
  done < <(python3 - "$file" <<'PYEOF'
import sys, yaml

try:
    with open(sys.argv[1]) as f:
        docs = list(yaml.safe_load_all(f))
    for doc in docs:
        if doc and doc.get("kind") in ("ClusterSecretStore", "SecretStore"):
            name = doc.get("metadata", {}).get("name", "")
            if name:
                print(name)
except Exception:
    pass
PYEOF
  )
done < <(find kubernetes/ -name "*.yaml" -o -name "*.yml" | sort)

if [ ${#VALID_STORES[@]} -eq 0 ]; then
  # No stores found in-repo — likely running outside the cluster context.
  # Fallback to known good store names from the platform.
  VALID_STORES=("openbao")
fi

echo "Known SecretStores: ${VALID_STORES[*]}"
echo ""

# ── Scan all ExternalSecret manifests ────────────────────────────────────────
while IFS= read -r file; do
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    FOUND=false
    for store in "${VALID_STORES[@]}"; do
      if [ "$ref" = "$store" ]; then
        FOUND=true
        break
      fi
    done
    if [ "$FOUND" = "false" ]; then
      INVALID_REFS+=("$file: secretStoreRef.name=$ref (valid: ${VALID_STORES[*]})")
      FAIL=1
    fi
  done < <(python3 - "$file" <<'PYEOF'
import sys, yaml

try:
    with open(sys.argv[1]) as f:
        docs = list(yaml.safe_load_all(f))
    for doc in docs:
        if doc and doc.get("kind") in ("ExternalSecret", "ClusterExternalSecret"):
            spec = doc.get("spec", {})
            store_ref = spec.get("secretStoreRef", {})
            name = store_ref.get("name", "")
            if name:
                print(name)
except Exception:
    pass
PYEOF
  )
done < <(find kubernetes/ -name "*.yaml" -o -name "*.yml" | sort)

echo ""

# ── Report results ────────────────────────────────────────────────────────────
if [ ${#INVALID_REFS[@]} -gt 0 ]; then
  echo "❌ Invalid ExternalSecret secretStoreRef references found:"
  for ref in "${INVALID_REFS[@]}"; do
    echo "   $ref"
  done
  echo ""
  echo "💡 All ExternalSecrets must reference an existing ClusterSecretStore."
  echo "   The platform's ClusterSecretStore is named 'openbao'."
  echo "   Use: secretStoreRef:"
  echo "          name: openbao"
  echo "          kind: ClusterSecretStore"
  exit 1
else
  echo "✅ All ExternalSecret secretStoreRef names are valid"
fi
