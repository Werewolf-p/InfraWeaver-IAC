#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-iac.sh — Pre-merge IaC validation (run locally AND in CI).
#
# Mirrors how larger orgs gate GitOps changes: every change is validated the
# same way on a developer laptop and in the PR pipeline (single source of truth
# for "is this safe to merge"). Complements the focused validators
# (validate-eso-refs.sh, validate-platform-yaml.sh, validate-users-yaml.sh).
#
# Checks:
#   1. kustomize build — every overlays/*/ renders without error
#   2. kubeconform     — rendered manifests pass Kubernetes schema validation
#   3. secret-leak gate — no NEW raw `kind: Secret` with a real value is added
#                         (declarative refs via ExternalSecret/OpenBao only).
#                         Existing known offenders are baselined (ratchet): the
#                         gate blocks new leaks while we migrate the old ones.
#
# Usage: scripts/validate-iac.sh [--repo-root <path>]
# Exit non-zero on any failure (CI-friendly).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${1:-}" == "--repo-root" ]] && REPO_ROOT="$2"
cd "$REPO_ROOT" || exit 1

KUSTOMIZE=(kubectl kustomize)
KUBECONFORM_FLAGS=(-strict -ignore-missing-schemas -summary)
FAILED=0

# Known pre-existing raw Secrets pending migration to ExternalSecret/OpenBao.
# DO NOT add to this list — fix the secret instead. Remove entries as migrated.
# Format: "<path>::<secret-name>"  (see docs/gitops-operating-model.md §Secrets)
# Empty: all previously-committed raw Secrets have been migrated to ExternalSecret
# (OpenBao) or inlined as non-sensitive config. Keep it empty — fix leaks, don't
# baseline them. The placeholder community-app Secrets (vaultwarden/bookstack) use
# only "change-me" values, which the gate ignores as non-real.
SECRET_BASELINE=()

echo "── 1/3 kustomize build (overlays) ───────────────────────────────────────"
mapfile -t OVERLAYS < <(find kubernetes -type f -path '*/overlays/*/kustomization.yaml' -printf '%h\n' | sort -u)
if [[ ${#OVERLAYS[@]} -eq 0 ]]; then
  echo "  (no overlays yet — skipping)"
fi
for d in "${OVERLAYS[@]}"; do
  if "${KUSTOMIZE[@]}" "$d" >/tmp/iac-render.yaml 2>/tmp/iac-err.txt; then
    echo "  ✓ $d"
    if command -v kubeconform >/dev/null 2>&1; then
      kubeconform "${KUBECONFORM_FLAGS[@]}" /tmp/iac-render.yaml >/tmp/kc.txt 2>&1 \
        && echo "    ✓ kubeconform" \
        || { echo "    ✗ kubeconform:"; sed 's/^/      /' /tmp/kc.txt; FAILED=1; }
    fi
  else
    echo "  ✗ $d"; sed 's/^/    /' /tmp/iac-err.txt; FAILED=1
  fi
done

echo "── 2/3 kubeconform (flat manifest dirs without overlays) ─────────────────"
if command -v kubeconform >/dev/null 2>&1; then
  mapfile -t FLAT < <(find kubernetes -type d -name manifests | sort)
  for d in "${FLAT[@]}"; do
    kubeconform "${KUBECONFORM_FLAGS[@]}" "$d" >/tmp/kc.txt 2>&1 \
      && echo "  ✓ $d" \
      || { echo "  ✗ $d:"; sed 's/^/    /' /tmp/kc.txt; FAILED=1; }
  done
else
  echo "  kubeconform not installed — skipping (CI installs it)"
fi

echo "── 3/3 secret-leak gate ──────────────────────────────────────────────────"
LEAKS="$(BASELINE="${SECRET_BASELINE[*]}" python3 - << 'PY'
import glob, yaml, os
baseline = set(os.environ.get("BASELINE","").split())
placeholders = {"", "change-me", "changeme", "placeholder", "changethis", "tbd"}
violations = []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get('kind') != 'Secret':
            continue
        name = (d.get('metadata') or {}).get('name')
        vals = list((d.get('stringData') or {}).values()) + list((d.get('data') or {}).values())
        real = [v for v in vals if isinstance(v, str) and v.strip() and v.strip().lower() not in placeholders]
        if real and f"{f}::{name}" not in baseline:
            violations.append(f"{f}::{name}")
for v in sorted(set(violations)):
    print(v)
PY
)"
if [[ -n "$LEAKS" ]]; then
  echo "  ✗ raw Secret(s) with real values committed to git (use ExternalSecret + OpenBao):"
  echo "$LEAKS" | sed 's/^/      /'
  FAILED=1
else
  echo "  ✓ no new committed secrets (baseline: ${#SECRET_BASELINE[@]} pending migration)"
fi

echo "──────────────────────────────────────────────────────────────────────────"
[[ $FAILED -eq 0 ]] && echo "IaC validation PASSED" || echo "IaC validation FAILED"
exit $FAILED
