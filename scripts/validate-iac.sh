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
#   4. cron-secret seed gate — every secret key an in-cluster CronJob depends on,
#                         when sourced (via its ExternalSecret) from a catalog
#                         app's OpenBao path, must be declared in that app's
#                         catalog.yaml `secrets.keys`. Otherwise seed-catalog-
#                         secrets.sh never seeds it on a fresh install, ESO can't
#                         sync the key, and the CronJob (and any Deployment that
#                         shares the key) fails to start — silently, forever.
#
# Usage: scripts/validate-iac.sh [--repo-root <path>]
# Exit non-zero on any failure (CI-friendly).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${1:-}" == "--repo-root" ]] && REPO_ROOT="$2"
cd "$REPO_ROOT" || exit 1

KUSTOMIZE=(kubectl kustomize)
# `-ignore-filename-pattern '/\.'` skips hidden directories. kubeconform is handed a
# manifests DIRECTORY and recurses, so editor/tooling caches such as
# `.impeccable/hook.cache.json` were being parsed as manifests and failing the gate
# with "missing 'kind' key". Nothing under a dot-directory is a Kubernetes manifest.
KUBECONFORM_FLAGS=(-strict -ignore-missing-schemas -summary -ignore-filename-pattern '/\.')
FAILED=0

# Known pre-existing raw Secrets pending migration to ExternalSecret/OpenBao.
# DO NOT add to this list — fix the secret instead. Remove entries as migrated.
# Format: "<path>::<secret-name>"  (see docs/gitops-operating-model.md §Secrets)
# Empty: all previously-committed raw Secrets have been migrated to ExternalSecret
# (OpenBao) or inlined as non-sensitive config. Keep it empty — fix leaks, don't
# baseline them. The placeholder community-app Secrets (vaultwarden/bookstack) use
# only "change-me" values, which the gate ignores as non-real.
SECRET_BASELINE=()

echo "── 1/5 kustomize build (overlays) ───────────────────────────────────────"
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

echo "── 2/5 kubeconform (flat manifest dirs without overlays) ─────────────────"
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

echo "── 3/5 secret-leak gate ──────────────────────────────────────────────────"
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

echo "── 4/5 cron-secret seed gate ─────────────────────────────────────────────"
CRON_GAPS="$(python3 - << 'PY'
import glob, yaml

def load(f):
    try:
        return list(yaml.safe_load_all(open(f)))
    except Exception:
        return []

# 1. ExternalSecret map: k8s Secret name -> { secretKey: (openbao_key, property) }
es = {}
es_retain_refs = []  # (target, openbao_key, property) for every Retain-policy ES data entry
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') not in ('ExternalSecret', 'ClusterExternalSecret'):
            continue
        spec = d.get('spec', {})
        target = (spec.get('target') or {}).get('name') or (d.get('metadata') or {}).get('name')
        deletion_policy = (spec.get('target') or {}).get('deletionPolicy')
        mapping = {}
        for item in (spec.get('data') or []):
            rr = item.get('remoteRef', {}) or {}
            sk = item.get('secretKey')
            mapping[sk] = (rr.get('key'), rr.get('property') or sk)
            if target and deletion_policy == 'Retain' and rr.get('key'):
                es_retain_refs.append((target, rr.get('key'), rr.get('property') or sk))
        if target:
            es[target] = mapping

# 2. Catalog apps that own an OpenBao path via their declared secrets: section.
#    Normalise: catalog `path: platform/x` == ExternalSecret `key: secret/platform/x`.
def norm(p):
    if not p:
        return p
    p = p[len('secret/'):] if p.startswith('secret/') else p
    p = p[len('data/'):] if p.startswith('data/') else p
    return p.rstrip('/')

owned = {}  # normalised path -> (app_name, set(declared keys))
for f in glob.glob('kubernetes/catalog/*/catalog.yaml'):
    d = (load(f) or [None])[0]
    if not isinstance(d, dict):
        continue
    s = d.get('secrets')
    if not s:
        continue
    p = norm(s.get('path'))
    if p:
        owned[p] = (d.get('name', f.split('/')[-2]), set((s.get('keys') or {}).keys()))

# 3. Every CronJob secretKeyRef whose backing key comes from an owned path must be
#    a declared key (else bootstrap never seeds it and the job can't start).
violations = []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') != 'CronJob':
            continue
        job = (d.get('metadata') or {}).get('name', '?')
        try:
            pod = d['spec']['jobTemplate']['spec']['template']['spec']
        except Exception:
            continue
        for c in pod.get('containers', []):
            for e in (c.get('env') or []):
                skr = (e.get('valueFrom') or {}).get('secretKeyRef')
                if not skr:
                    continue
                sec, key = skr.get('name'), skr.get('key')
                src = es.get(sec, {}).get(key)
                if not src:
                    continue  # not ExternalSecret-backed here (raw/generated) — out of scope
                path, prop = norm(src[0]), src[1]
                if path in owned:
                    app, keys = owned[path]
                    if prop not in keys:
                        violations.append(
                            f"{job}: needs {sec}[{key}] = {path}::{prop}, "
                            f"but '{prop}' is not declared in catalog/{app}/catalog.yaml secrets.keys")

# 4. deletionPolicy: Retain ExternalSecrets fail the WHOLE secret sync if ANY
#    referenced property is missing in OpenBao (ESO only skips a missing key when
#    deletionPolicy != Retain). So every property such an ES reads from an owned
#    catalog path must be declared, else a fresh install can't materialise the
#    secret at all — every consumer (the app pod AND its CronJobs) stays stuck.
for target, key, prop in es_retain_refs:
    path = norm(key)
    if path in owned:
        app, keys = owned[path]
        if prop not in keys:
            violations.append(
                f"ExternalSecret {target} (deletionPolicy: Retain): needs {path}::{prop}, "
                f"but '{prop}' is not declared in catalog/{app}/catalog.yaml secrets.keys "
                f"(Retain aborts the entire secret on any one missing key)")
for v in sorted(set(violations)):
    print(v)
PY
)"
if [[ -n "$CRON_GAPS" ]]; then
  echo "  ✗ a CronJob or Retain-policy ExternalSecret needs a secret key no bootstrap seeds (declare it in the app's catalog.yaml secrets.keys):"
  echo "$CRON_GAPS" | sed 's/^/      /'
  FAILED=1
else
  echo "  ✓ every CronJob secret key sourced from a catalog path is declared (bootstrap will seed it)"
fi

echo "── 5/5 alerting rules (promtool + duplicate scan) ────────────────────────"
# Alerting rules used to have no gate at all. Two real defects shipped through
# that gap: a >85% node-memory alert existed twice under different alertnames in
# two files (one condition, two Discord pages, un-inhibitable because
# Alertmanager keys inhibition on alertname), and a console CronJob alert was
# added that duplicated one already in alerts/openbao-token.yaml.
#
# promtool cannot read a PrometheusRule custom resource, so `.spec` is extracted
# from every one of them into a temp dir first. Group names are prefixed with
# their source file because group names must be unique within a rules file.
RULES_TMP="$(mktemp -d)"
trap 'rm -rf "$RULES_TMP"' EXIT

RULE_EXTRACT="$(python3 - "$RULES_TMP" <<'PY'
import sys, glob, yaml, os
out_dir = sys.argv[1]
groups, files = [], 0
for f in sorted(glob.glob('kubernetes/**/*.yaml', recursive=True)):
    try:
        docs = [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
    except Exception:
        continue                      # not our file; other gates cover parse errors
    for d in docs:
        if d.get('kind') != 'PrometheusRule':
            continue
        files += 1
        stem = os.path.basename(f).rsplit('.', 1)[0]
        for g in d.get('spec', {}).get('groups', []):
            g = dict(g)
            g['name'] = f"{stem}::{g['name']}"
            groups.append(g)
if not groups:
    # A scan that finds nothing must not read as success.
    print("ERROR: no PrometheusRule groups found — the extractor is broken or the rules moved")
    sys.exit(1)
with open(os.path.join(out_dir, 'rules.yaml'), 'w') as fh:
    yaml.safe_dump({'groups': groups}, fh, sort_keys=False, width=10**6)
print(f"{files} PrometheusRule doc(s), {len(groups)} group(s), "
      f"{sum(len(g.get('rules', [])) for g in groups)} rule(s)")
PY
)" || { echo "  ✗ rule extraction failed:"; echo "$RULE_EXTRACT" | sed 's/^/      /'; FAILED=1; }
[[ -n "$RULE_EXTRACT" ]] && echo "  · extracted $RULE_EXTRACT"

# Duplicate scan. Pure Python, so it runs everywhere — including where promtool
# is absent. This is the check that would have caught both defects above.
DUPES="$(python3 - <<'PY'
import glob, yaml, collections
names, exprs = collections.defaultdict(list), collections.defaultdict(list)
for f in sorted(glob.glob('kubernetes/**/*.yaml', recursive=True)):
    try:
        docs = [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
    except Exception:
        continue
    for d in docs:
        if d.get('kind') != 'PrometheusRule':
            continue
        for g in d.get('spec', {}).get('groups', []):
            for r in g.get('rules', []):
                if 'alert' not in r:
                    continue
                names[r['alert']].append(f)
                exprs[' '.join(r['expr'].split())].append(f"{r['alert']} ({f})")
for n, fs in sorted(names.items()):
    if len(fs) > 1:
        print(f"duplicate alertname '{n}' in: {', '.join(sorted(set(fs)))}")
for e, rs in sorted(exprs.items()):
    if len(rs) > 1:
        print(f"identical expression shared by: {', '.join(sorted(set(rs)))}")
        print(f"    expr: {e[:110]}")
PY
)"
if [[ -n "$DUPES" ]]; then
  echo "  ✗ duplicate alerts — one condition would page twice and Alertmanager cannot inhibit across alertnames:"
  echo "$DUPES" | sed 's/^/      /'
  FAILED=1
else
  echo "  ✓ no duplicate alertnames or identical expressions across PrometheusRules"
fi

if command -v promtool >/dev/null 2>&1; then
  if [[ -f "$RULES_TMP/rules.yaml" ]]; then
    promtool check rules "$RULES_TMP/rules.yaml" >/tmp/pt.txt 2>&1 \
      && echo "  ✓ promtool check rules" \
      || { echo "  ✗ promtool check rules:"; sed 's/^/      /' /tmp/pt.txt; FAILED=1; }

    # Unit tests live beside the rules they cover. Each is copied next to the
    # extracted rules.yaml because promtool resolves rule_files relative to the
    # test file.
    shopt -s nullglob
    TESTS=(kubernetes/monitoring/alerts/tests/*.test.yaml)
    shopt -u nullglob
    if (( ${#TESTS[@]} == 0 )); then
      echo "  ✗ no *.test.yaml found under kubernetes/monitoring/alerts/tests/ — alert unit tests are expected to exist"
      FAILED=1
    else
      for t in "${TESTS[@]}"; do
        cp "$t" "$RULES_TMP/$(basename "$t")"
        if (cd "$RULES_TMP" && promtool test rules "$(basename "$t")") >/tmp/pt.txt 2>&1; then
          echo "  ✓ promtool test rules — $(basename "$t")"
        else
          echo "  ✗ promtool test rules — $(basename "$t"):"; sed 's/^/      /' /tmp/pt.txt; FAILED=1
        fi
      done
    fi
  fi
else
  echo "  promtool not installed — skipping check/test (CI installs it; see .github/workflows/validate-iac.yml)"
fi

echo "──────────────────────────────────────────────────────────────────────────"
[[ $FAILED -eq 0 ]] && echo "IaC validation PASSED" || echo "IaC validation FAILED"
exit $FAILED
