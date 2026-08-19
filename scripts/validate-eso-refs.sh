#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-eso-refs.sh — every ExternalSecret must name a SecretStore that exists
#
# Root cause prevention: in 2025-05 the Gatus ExternalSecret used
# secretStoreRef.name: openbao-backend (which does not exist) instead of
# secretStoreRef.name: openbao (the real ClusterSecretStore). ESO never
# reconciled it, the Secret was never created, and Gatus CrashLooped.
#
# ── WHY THIS FILE WAS REWRITTEN 2026-08-19 ───────────────────────────────────
# It was the last `|| true` in CI ("informational until hardened",
# validate-iac.yml). Promoting it to blocking meant first proving it could
# fail, and it could not. The previous version printed the same green
# "✅ All ExternalSecret secretStoreRef names are valid" when:
#
#   · zero ExternalSecrets were found (no floor on what it scanned);
#   · zero SecretStores were found — it silently substituted a hardcoded
#     VALID_STORES=("openbao"), so renaming or deleting the real store made
#     the gate MORE permissive, not less;
#   · every manifest failed to parse — both YAML loops swallowed exceptions
#     with `except Exception: pass`, so a syntax error anywhere read as
#     "nothing to check".
#
# All three are now hard failures. A gate that cannot fail is not a gate; that
# is the exact defect this repo has paid for repeatedly (promtool skipped
# silently while CI stayed red for four commits; 45 files sat uncommitted while
# every gate passed). Counts are printed so the floor is auditable, not implied.
#
# USAGE:  bash scripts/validate-eso-refs.sh [--repo-root <dir>]
# EXIT:   0 all refs valid AND the scan was non-vacuous
#         1 an invalid ref, OR the scan proved nothing
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "validate-eso-refs.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
cd "$REPO_ROOT"

if [[ ! -d kubernetes ]]; then
  echo "✗ $REPO_ROOT/kubernetes does not exist — this gate would scan nothing." >&2
  exit 1
fi

# One Python pass over the whole tree. Emits three record types on stdout:
#   STORE<TAB><name><TAB><file>
#   REF<TAB><name><TAB><file>
#   PARSE_ERROR<TAB><file><TAB><message>
# A parse error is REPORTED, never swallowed — the old `except: pass` is what
# made a broken tree indistinguishable from a clean one.
SCAN="$(python3 - <<'PYEOF'
import os, sys, yaml

STORE_KINDS = ("ClusterSecretStore", "SecretStore")
REF_KINDS   = ("ExternalSecret", "ClusterExternalSecret")
SKIP_DIRS   = {".git", "node_modules", "__pycache__", ".venv", "out", "dist", "build"}

for root, dirs, files in os.walk("kubernetes"):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for fn in sorted(files):
        if not fn.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(root, fn)
        try:
            with open(path) as fh:
                docs = list(yaml.safe_load_all(fh))
        except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
            print("PARSE_ERROR\t%s\t%s" % (path, str(exc).replace("\n", " ")[:160]))
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get("kind")
            if kind in STORE_KINDS:
                name = (doc.get("metadata") or {}).get("name") or ""
                if name:
                    print("STORE\t%s\t%s" % (name, path))
            elif kind in REF_KINDS:
                ref = ((doc.get("spec") or {}).get("secretStoreRef") or {}).get("name") or ""
                if ref:
                    print("REF\t%s\t%s" % (ref, path))
                else:
                    print("REF\t<missing>\t%s" % path)
PYEOF
)"

mapfile -t PARSE_ERRORS < <(printf '%s\n' "$SCAN" | awk -F'\t' '$1=="PARSE_ERROR"{print $2": "$3}')
mapfile -t STORES       < <(printf '%s\n' "$SCAN" | awk -F'\t' '$1=="STORE"{print $2}' | sort -u)
mapfile -t REFS         < <(printf '%s\n' "$SCAN" | awk -F'\t' '$1=="REF"{print $2"\t"$3}')

FAIL=0

# ── Floor 1: the tree must have parsed ───────────────────────────────────────
if (( ${#PARSE_ERRORS[@]} > 0 )); then
  echo "✗ ${#PARSE_ERRORS[@]} manifest(s) failed to parse — this scan cannot be trusted:"
  printf '    %s\n' "${PARSE_ERRORS[@]}"
  FAIL=1
fi

# ── Floor 2: at least one SecretStore must be DISCOVERED, never assumed ──────
if (( ${#STORES[@]} == 0 )); then
  echo "✗ no ClusterSecretStore/SecretStore found anywhere under kubernetes/."
  echo "    The previous version substituted a hardcoded 'openbao' here, which meant"
  echo "    deleting or renaming the real store made this gate PASS MORE EASILY."
  echo "    If the store legitimately moved, this gate must learn where — not guess."
  FAIL=1
fi

# ── Floor 3: there must be something to validate ─────────────────────────────
if (( ${#REFS[@]} == 0 )); then
  echo "✗ no ExternalSecret/ClusterExternalSecret found under kubernetes/ — a green"
  echo "    result here would mean 'nothing was checked', not 'everything is correct'."
  FAIL=1
fi

if (( FAIL == 0 )); then
  echo "Known SecretStores (${#STORES[@]}, discovered — not assumed): ${STORES[*]}"
fi

INVALID=()
for entry in "${REFS[@]}"; do
  ref="${entry%%$'\t'*}"; file="${entry#*$'\t'}"
  if [[ "$ref" == "<missing>" ]]; then
    INVALID+=("$file: ExternalSecret has no spec.secretStoreRef.name")
    continue
  fi
  printf '%s\n' "${STORES[@]}" | grep -qxF "$ref" \
    || INVALID+=("$file: secretStoreRef.name=$ref (valid: ${STORES[*]:-none})")
done

if (( ${#INVALID[@]} > 0 )); then
  echo ""
  echo "✗ ${#INVALID[@]} invalid ExternalSecret secretStoreRef reference(s):"
  printf '    %s\n' "${INVALID[@]}"
  echo ""
  echo "  Every ExternalSecret must reference a SecretStore that exists in-repo:"
  echo "      secretStoreRef:"
  echo "        name: openbao"
  echo "        kind: ClusterSecretStore"
  echo "  ESO does not error on an unknown store — it just never reconciles, the"
  echo "  Secret is never created, and the workload CrashLoops (Gatus, 2025-05)."
  FAIL=1
fi

if (( FAIL != 0 )); then
  echo ""
  echo "ESO reference validation FAILED"
  exit 1
fi

echo "✓ ${#REFS[@]} ExternalSecret reference(s) checked, all resolve to a discovered SecretStore"
