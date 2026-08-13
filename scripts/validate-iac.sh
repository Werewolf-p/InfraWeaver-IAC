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
#   3. secret-leak gate — no raw `kind: Secret` carrying a value is added
#                         (declarative refs via ExternalSecret/OpenBao only).
#                         Existing known offenders are baselined (ratchet): the
#                         gate blocks new leaks while we migrate the old ones.
#                         A write-me placeholder ("change-me") FAILS like any
#                         other value — under GitOps ArgoCD applies it and
#                         selfHeal re-asserts it, so it is the live credential,
#                         not a TODO. Narrow per-secret exemptions only, via
#                         PLACEHOLDER_EXEMPT below.
#   4. cron-secret seed gate — a secret key a workload names has to survive TWO
#                         hops, and this gate checks both:
#                           catalog.yaml `secrets.keys` → the value exists in OpenBao
#                           ExternalSecret `spec.data`  → it reaches the k8s Secret
#                         Miss the first and seed-catalog-secrets.sh never seeds it
#                         on a fresh install. Miss the second and ESO never puts it
#                         in the Secret at all — creationPolicy: Owner means no
#                         other writer exists. Either way the CronJob (and any
#                         Deployment sharing the key) fails to start, silently and
#                         forever; `optional: true` converts that into starting
#                         with the value EMPTY, which is quieter still.
#   5. alerting rules  — promtool check/test, plus a scan for duplicate
#                         alertnames and identical expressions across
#                         PrometheusRules.
#   6. armed-blueprint gate — the Authentik IP-reputation lockout may not be
#                         mounted while its own arming procedure still marks the
#                         Cloudflare X-Forwarded-For prerequisite outstanding.
#                         Armed early it is not a weak control, it is a remote
#                         DoS on login: any caller can pick a victim address. The
#                         warning and the mount shipped in the same commit once
#                         already, which is why this is a gate and not a comment.
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
# baseline them.
SECRET_BASELINE=()

# Secrets allowed to ship a WRITE-ME placeholder value ("change-me" and friends).
# Format: "<path>::<secret-name>". Intended for scaffolding a human must edit
# before it is ever applied — a template under kubernetes/catalog/_template/, not
# a manifest ArgoCD syncs.
#
# WHY THIS LIST IS NARROW AND WAS ONCE THE WHOLE RULE. Until now the gate treated
# "change-me" as a non-value everywhere, and that is exactly how two of them
# reached a live cluster: vaultwarden's ADMIN_TOKEN and bookstack's APP_KEY +
# DB_PASSWORD sat at "change-me" on apps whose own catalog.yaml said
# `installed_at: 2026-05-17`. Under GitOps a placeholder in a manifest ArgoCD
# applies is not a placeholder — it is the live credential, re-asserted by
# selfHeal every time somebody rotates it in-cluster. So the gate now FAILS on a
# placeholder by default and only an entry here excuses one, per file and per
# secret name, with a comment saying why. An EMPTY value is still not a
# credential and needs no entry.
PLACEHOLDER_EXEMPT=()

echo "── 1/6 kustomize build (overlays) ───────────────────────────────────────"
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

echo "── 2/6 kubeconform (flat manifest dirs without overlays) ─────────────────"
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

echo "── 3/6 secret-leak gate ──────────────────────────────────────────────────"
LEAKS="$(BASELINE="${SECRET_BASELINE[*]}" EXEMPT="${PLACEHOLDER_EXEMPT[*]}" python3 - << 'PY'
import glob, yaml, os
baseline = set(os.environ.get("BASELINE","").split())
exempt = set(os.environ.get("EXEMPT","").split())
# Write-me placeholders. NOT treated as "no value": under GitOps ArgoCD applies
# them verbatim and selfHeal re-applies them over any in-cluster rotation, so a
# committed "change-me" IS the live credential. They are reported separately
# from a real leak only so the message can say which mistake was made; both fail.
placeholders = {"change-me", "changeme", "change_me", "placeholder", "changethis",
                "change-this", "tbd", "todo", "secret", "password", "hunter2"}
leaks, weak = [], []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get('kind') != 'Secret':
            continue
        name = (d.get('metadata') or {}).get('name')
        ref = f"{f}::{name}"
        vals = list((d.get('stringData') or {}).values()) + list((d.get('data') or {}).values())
        # An empty value carries no credential and is how a template declares a
        # key it does not own; everything else is a value this repo would apply.
        present = [v.strip() for v in vals if isinstance(v, str) and v.strip()]
        if not present:
            continue
        if all(v.lower() in placeholders for v in present):
            if ref not in exempt:
                weak.append(ref)
        elif ref not in baseline:
            leaks.append(ref)
for v in sorted(set(leaks)):
    print(f"leak {v}")
for v in sorted(set(weak)):
    print(f"placeholder {v}")
PY
)"
if [[ -n "$LEAKS" ]]; then
  echo "  ✗ raw Secret(s) committed to git — use ExternalSecret + OpenBao:"
  echo "$LEAKS" | sed 's/^/      /'
  echo "      (a 'placeholder' hit is a credential too: ArgoCD applies it and selfHeal"
  echo "       re-asserts it over any in-cluster rotation. Exempt only a template a"
  echo "       human edits before apply, via PLACEHOLDER_EXEMPT in this script.)"
  FAILED=1
else
  echo "  ✓ no committed secrets or write-me placeholders (baseline: ${#SECRET_BASELINE[@]}, exempt: ${#PLACEHOLDER_EXEMPT[@]})"
fi

echo "── 4/6 cron-secret seed gate ─────────────────────────────────────────────"
CRON_GAPS="$(python3 - << 'PY'
import glob, yaml

def load(f):
    try:
        return list(yaml.safe_load_all(open(f)))
    except Exception:
        return []

# 1. ExternalSecret map: k8s Secret name -> { secretKey: (openbao_key, property) }
#
# `es_opaque` records the targets whose final key set this file cannot enumerate,
# so §3 must not claim a key is missing from them:
#   - `spec.target.template.data` RENAMES the fetched values. bookstack fetches
#     `secretKey: appKey` and the template emits a key literally called `value`
#     (`base64:{{ .appKey | trunc 32 | b64enc }}`), which deployment.yaml is what
#     reads. Judging that target by spec.data alone reports a live, working app as
#     unable to start.
#   - `spec.dataFrom` (extract/find) pulls an entire OpenBao path, so the produced
#     keys are whatever the store holds and are not knowable from the manifest.
es = {}
es_opaque = set()
es_retain_refs = []  # (target, openbao_key, property) for every Retain-policy ES data entry
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') not in ('ExternalSecret', 'ClusterExternalSecret'):
            continue
        spec = d.get('spec', {})
        if d.get('kind') == 'ClusterExternalSecret':
            spec = (spec.get('externalSecretSpec') or spec)
        target = (spec.get('target') or {}).get('name') or (d.get('metadata') or {}).get('name')
        deletion_policy = (spec.get('target') or {}).get('deletionPolicy')
        template = ((spec.get('target') or {}).get('template') or {})
        mapping = {}
        for item in (spec.get('data') or []):
            rr = item.get('remoteRef', {}) or {}
            sk = item.get('secretKey')
            mapping[sk] = (rr.get('key'), rr.get('property') or sk)
            if target and deletion_policy == 'Retain' and rr.get('key'):
                es_retain_refs.append((target, rr.get('key'), rr.get('property') or sk))
        if target:
            es[target] = mapping
            if template.get('data') or template.get('templateFrom') or spec.get('dataFrom'):
                es_opaque.add(target)

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

# 3. Every workload secretKeyRef whose backing key comes from an owned path must be
#    a declared key (else bootstrap never seeds it and the job can't start).
#
#    TWO chains have to hold, and this gate used to check only the second half of
#    the first one:
#      catalog.yaml secrets.keys  →  the value exists in OpenBao
#      ExternalSecret spec.data   →  the value reaches the k8s Secret
#    `placement-rebalance-cron-token` was declared in catalog.yaml and named by the
#    CronJob and the Deployment — and by no ExternalSecret entry. The lookup below
#    returned None, the old code read that as "raw/generated Secret, out of scope"
#    and skipped it, and the gate reported PASSED while the CronJob sat in
#    CreateContainerConfigError on every schedule for as long as it existed.
#    A Secret produced by an ExternalSecret with creationPolicy: Owner has no other
#    writer, so a key missing from spec.data can never appear: that is a MISSING
#    ENTRY, not an out-of-scope one. Only a Secret name no ExternalSecret produces
#    at all is genuinely out of scope.
#
#    `optional: true` does not excuse it either — that flag is what let the console
#    Deployment start with an EMPTY token and hid the same defect on its other half.
#    An env var that can never be populated is dead config, so it is reported too,
#    with its own wording.
WORKLOAD_PODSPEC = {
    'CronJob': lambda d: d['spec']['jobTemplate']['spec']['template']['spec'],
    'Deployment': lambda d: d['spec']['template']['spec'],
    'StatefulSet': lambda d: d['spec']['template']['spec'],
    'DaemonSet': lambda d: d['spec']['template']['spec'],
    'Job': lambda d: d['spec']['template']['spec'],
}
violations = []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') not in WORKLOAD_PODSPEC:
            continue
        kind = d['kind']
        job = f"{kind}/{(d.get('metadata') or {}).get('name', '?')}"
        try:
            pod = WORKLOAD_PODSPEC[kind](d)
        except Exception:
            continue
        containers = (pod.get('containers') or []) + (pod.get('initContainers') or [])
        for c in containers:
            for e in (c.get('env') or []):
                skr = (e.get('valueFrom') or {}).get('secretKeyRef')
                if not skr:
                    continue
                sec, key = skr.get('name'), skr.get('key')
                if sec not in es:
                    continue  # no ExternalSecret produces this Secret — raw/generated, out of scope
                if sec in es_opaque:
                    continue  # a template/dataFrom decides the final key set — not enumerable here
                src = es[sec].get(key)
                if not src:
                    how = ("declared optional, so the workload starts with the value EMPTY"
                           if skr.get('optional')
                           else "not optional, so the pod cannot start at all")
                    violations.append(
                        f"{job}: needs {sec}[{key}], but no ExternalSecret data entry produces "
                        f"that key and creationPolicy: Owner leaves the Secret no other writer "
                        f"({how})")
                    continue
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
  echo "  ✓ every workload secret key is declared in its catalog.yaml AND produced by an ExternalSecret"
fi

echo "── 5/6 alerting rules (promtool + duplicate scan) ────────────────────────"
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

echo "── 6/6 armed-blueprint gate ──────────────────────────────────────────────"
# A security control that is WRONG is worse than one that is absent, and this
# repo has already written the proof of it: manifests/blueprints/
# 70-brute-force-reputation.yaml documents, in its own §3c, that arming the
# Authentik IP-reputation lockout while Cloudflare still appends to a
# caller-supplied X-Forwarded-For turns the control into a remote DoS — 21 failed
# logins carrying `X-Forwarded-For: <victim>` deny that address login for 24h,
# and any unauthenticated caller picks the victim.
#
# The mount and the warning shipped in the SAME commit on
# fix/traefik-cloudflare-xff-arm-brute-force, so the warning could not stop it:
# whoever merged the branch would have armed the policy and read the reason
# afterwards. A comment is not a gate. This is.
#
# The rule: the blueprint may be listed in values.yaml `blueprints.configMaps`
# only once its own arming procedure no longer marks step 0b OUTSTANDING.
# Closing 0b means editing the blueprint, so the two cannot drift apart.
BF_BLUEPRINT="kubernetes/platform/authentik/manifests/blueprints/70-brute-force-reputation.yaml"
BF_VALUES="kubernetes/platform/authentik/values.yaml"
if [[ -f "$BF_BLUEPRINT" && -f "$BF_VALUES" ]]; then
  # An uncommented list entry only — the disarmed form is commented out.
  if grep -qE '^[[:space:]]*-[[:space:]]*authentik-blueprint-brute-force[[:space:]]*$' "$BF_VALUES"; then
    if grep -qE '0b\.[[:space:]]*\[OUTSTANDING\]' "$BF_BLUEPRINT"; then
      echo "  ✗ authentik-blueprint-brute-force is MOUNTED while its own §4 step 0b is still [OUTSTANDING]."
      echo "      Arming the IP-reputation lockout before the Cloudflare Transform Rule exists makes"
      echo "      login remotely deniable for any address an attacker names. Close 0b in"
      echo "      $BF_BLUEPRINT (and prove it: a request with a bogus X-Forwarded-For must be"
      echo "      recorded under the real caller) before listing it in $BF_VALUES."
      FAILED=1
    else
      echo "  ✓ brute-force blueprint is mounted and its §3c prerequisite is marked closed"
    fi
  else
    echo "  ✓ brute-force blueprint is not mounted (§3c still open — see values.yaml)"
  fi
else
  echo "  ✗ expected blueprint/values pair not found — this gate is not guarding anything"
  FAILED=1
fi

echo "──────────────────────────────────────────────────────────────────────────"
[[ $FAILED -eq 0 ]] && echo "IaC validation PASSED" || echo "IaC validation FAILED"
exit $FAILED
