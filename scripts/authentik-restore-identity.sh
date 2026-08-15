#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/authentik-restore-identity.sh
#
# Rebuild Authentik's identity state from git after the database has been
# restored, rebuilt, or migrated.
#
#   ./scripts/authentik-restore-identity.sh               # dry run (default)
#   ./scripts/authentik-restore-identity.sh --apply       # make the changes
#   ./scripts/authentik-restore-identity.sh --verify-only # just the invariants
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS — the 2026-08-15 lockout
# ─────────────────────────────────────────────────────────────────────────────
# On 2026-08-14 ~22:33 Authentik's Postgres was rebuilt and reloaded from a
# data-only dump. Users (12), groups (31) and roles (3) all came back. The
# many-to-many JOIN tables did not:
#
#     select count(*) from authentik_core_user_groups;   ->  0
#     role 'role-infraweaver-console' model permissions  ->  0
#
# Every object a human looks at in the admin UI was present, so the restore
# looked successful. But in Authentik, *authorisation lives almost entirely in
# those join tables*: `policy-admins-only` is
# `request.user.is_superuser or ak_is_group_member(request.user, name="platform-admins")`,
# and even `is_superuser` is conferred BY group membership. With the join table
# empty, every forward-auth application denied every user — ArgoCD, Grafana,
# Longhorn, OpenBao, Proxmox, Jellyfin, Nextcloud, the console itself — and the
# console's own service account got HTTP 403 on every API call, which in turn
# stopped user provisioning cluster-wide.
#
# Nothing detected it. `roster-drift` runs every 5 minutes and kept reporting
# `"alert": false`, because its projection check only iterates LIVE members
# looking for UNEXPECTED ones; the reverse difference — "git says this
# membership should exist and Authentik does not have it" — was never computed.
#
# THE LESSON: a restored Authentik database is NOT proof of a restored
# Authentik. Run this script after any restore and let it fail the invariants.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS RESTORES, AND WHAT IT DELIBERATELY DOES NOT
# ─────────────────────────────────────────────────────────────────────────────
# RESTORED — everything git actually declares:
#   1. Blueprints: roles and their permissions, groups, applications, providers,
#      policies, flows, brands. Applied from the ConfigMaps already mounted into
#      the worker at /blueprints/mounted/ (the same files this repo commits under
#      kubernetes/platform/authentik/manifests/blueprints/).
#   2. Organisational group membership from users.yaml `authentik_groups`.
#   3. The console service account's scope group and role.
#
# NOT RESTORED — projection groups (`wordpress-<site>-access`, `storage-*`):
#   These are OWNED BY THE CONSOLE, which derives them from `role_assignments`
#   in users.yaml. Re-deriving them here would fork that logic, and this repo
#   has been burned by exactly that before ("Don't duplicate console logic in a
#   script: the interlock system already existed and was the right place").
#   Phase 4 therefore REPORTS them and prints the console-side commands instead
#   of guessing. `users-reconcile` (every 5 min) already restores the storage
#   ones on its own; the WordPress ones have no fleet-wide re-run and need the
#   per-site sync endpoint.
#
# ADD-ONLY. This never removes a membership. A restore is not the moment to
# discover that a script's idea of "extra" was wrong, and `authentik Admins`
# must never be asserted as a full user list — that would evict break-glass.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODE="dry-run"
case "${1:-}" in
  --apply)       MODE="apply" ;;
  --verify-only) MODE="verify" ;;
  --dry-run|"")  MODE="dry-run" ;;
  -h|--help)     sed -n '2,64p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (expected --apply, --dry-run or --verify-only)" >&2; exit 2 ;;
esac

KUBECTL="${KUBECTL:-kubectl}"
NS="${AUTHENTIK_NAMESPACE:-authentik}"
WORKER="deploy/authentik-worker"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USERS_YAML="${USERS_YAML:-$REPO_ROOT/users.yaml}"

[[ -f "$USERS_YAML" ]] || { echo "FATAL: users.yaml not found at $USERS_YAML" >&2; exit 2; }

echo "═══ authentik-restore-identity — mode: $MODE ═══"
echo "    namespace : $NS"
echo "    roster    : $USERS_YAML"
echo

# `ak shell` prints a banner and a stream of JSON boot logs on stdout before the
# script's own output. Everything below filters them out rather than parsing
# them, so a log-format change upstream cannot silently corrupt a result.
ak_shell() { $KUBECTL exec -n "$NS" "$WORKER" -- ak shell -c "$1" 2>/dev/null | grep -v '^{' | grep -v '^###' | grep -v 'objects imported'; }

# ── PHASE 1 — blueprints: roles, permissions, groups, applications ───────────
# These carry the role PERMISSION rows, which the 2026-08-15 restore also lost.
# Blueprint entries are `state: present` / `state: created`, i.e. idempotent.
#
# ⚠️ `state: created` entries (00-break-glass-account.yaml) are no-ops once the
# object exists, so a blueprint CANNOT repair an existing account's membership.
# That is why Phase 2 asserts break-glass explicitly.
echo "── Phase 1: apply blueprints ───────────────────────────────────────────"
BLUEPRINTS=$($KUBECTL exec -n "$NS" "$WORKER" -- sh -c 'ls /blueprints/mounted/*/*.yaml 2>/dev/null' 2>/dev/null | tr -d '\r' || true)
if [[ -z "$BLUEPRINTS" ]]; then
  echo "  ⚠️  no mounted blueprints found — is apps-authentik-manifests synced?"
else
  while IFS= read -r bp; do
    [[ -n "$bp" ]] || continue
    if [[ "$MODE" == "apply" ]]; then
      if $KUBECTL exec -n "$NS" "$WORKER" -- ak apply_blueprint "$bp" >/dev/null 2>&1; then
        echo "  ✅ applied  $bp"
      else
        echo "  ❌ FAILED   $bp"
      fi
    else
      echo "  would apply  $bp"
    fi
  done <<< "$BLUEPRINTS"
fi
echo

# ── PHASE 2 — organisational membership from users.yaml ──────────────────────
echo "── Phase 2: project users.yaml authentik_groups ────────────────────────"
PLAN_JSON=$(python3 - "$USERS_YAML" <<'PY'
import json, sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
plan = {}
for username, cfg in (doc.get("users") or {}).items():
    groups = [g for g in ((cfg or {}).get("authentik_groups") or []) if isinstance(g, str)]
    if groups:
        plan[username] = groups
# The break-glass recovery admin is declared in a blueprint rather than in
# users.yaml, and its `state: created` entry cannot repair an existing account.
# Assert it here so a restore always leaves a working way back in.
plan.setdefault("break-glass", []).append("authentik Admins")
print(json.dumps(plan))
PY
)
echo "  roster declares: $(echo "$PLAN_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(v) for v in d.values()), "memberships across", len(d), "principals")')"

APPLY_FLAG="False"; [[ "$MODE" == "apply" ]] && APPLY_FLAG="True"
if [[ "$MODE" == "verify" ]]; then
  echo "  (skipped — verify-only)"
else
  ak_shell "
import json
from authentik.core.models import User, Group
plan = json.loads('''$PLAN_JSON''')
apply = $APPLY_FLAG
for username, groups in plan.items():
    u = User.objects.filter(username=username).first()
    if not u:
        print('  MISSING USER  ' + username + ' - declared in git, absent from Authentik'); continue
    for gname in groups:
        g = Group.objects.filter(name=gname).first()
        if not g:
            print('  MISSING GROUP ' + gname + ' (for ' + username + ') - no blueprint creates it'); continue
        if u.groups.filter(pk=g.pk).exists():
            continue
        if apply:
            u.groups.add(g); print('  ADDED  ' + username + ' -> ' + gname)
        else:
            print('  WOULD ADD  ' + username + ' -> ' + gname)
"
fi
echo

# ── PHASE 3 — invariants. These are what nobody checked on 2026-08-15. ───────
echo "── Phase 3: verify invariants ──────────────────────────────────────────"
INVARIANTS=$(ak_shell "
from django.db import connection
from authentik.core.models import User, Group
from authentik.rbac.models import Role
fail = []
c = connection.cursor()
c.execute('select count(*) from authentik_core_user_groups')
rows = c.fetchone()[0]
print('  memberships in DB        : %d' % rows)
if rows == 0:
    fail.append('authentik_core_user_groups is EMPTY - every group-gated app denies everyone')

svc = User.objects.filter(username='svc-infraweaver-console').first()
if not svc:
    fail.append('service account svc-infraweaver-console is missing')
else:
    n = svc.groups.count()
    print('  console SA groups        : %d %s' % (n, list(svc.groups.values_list('name', flat=True))))
    if n == 0:
        fail.append('svc-infraweaver-console is in NO group - it will get HTTP 403 on every call')

r = Role.objects.filter(name='role-infraweaver-console').first()
if not r:
    fail.append('role-infraweaver-console is missing')
else:
    n = r.rolemodelpermission_set.count()
    print('  console role permissions : %d' % n)
    if n == 0:
        fail.append('role-infraweaver-console has 0 permissions - restore lost the permission join table')

bg = User.objects.filter(username='break-glass').first()
if not bg:
    fail.append('break-glass account is missing')
elif not bg.groups.filter(name='authentik Admins').exists():
    fail.append('break-glass is not in authentik Admins - there is no way back in')
else:
    print('  break-glass              : in authentik Admins (active=%s, dormant by design)' % bg.is_active)

admins = Group.objects.filter(name='authentik Admins').first()
n = admins.users.count() if admins else 0
print('  authentik Admins members : %d' % n)
if n == 0:
    fail.append('authentik Admins is EMPTY - nobody can administer Authentik')

for f in fail:
    print('  FAIL: ' + f)
print('INVARIANTS_FAILED=%d' % len(fail))
")
echo "$INVARIANTS"
FAILED=$(echo "$INVARIANTS" | sed -n 's/.*INVARIANTS_FAILED=\([0-9]*\).*/\1/p' | tail -1)
FAILED="${FAILED:-1}"
echo

# ── PHASE 4 — what this script cannot restore, and how to finish ─────────────
echo "── Phase 4: console-owned projection groups (NOT restored here) ────────"
cat <<'NOTE'
  wordpress-<site>-access and storage-* groups are derived by the console from
  users.yaml `role_assignments`, not declared in git as membership lists.

    storage-*   : restored automatically by the users-reconcile CronJob
                  (infraweaver-console, every 5 min). Force it now with:
                    kubectl create job -n infraweaver-console reconcile-now \
                      --from=cronjob/users-reconcile

    wordpress-* : NO fleet-wide re-run exists. Re-sync each site:
                    POST /api/wordpress/sites/<site>/access
                  or open each site's Access tab in the console once.

  Verify afterwards with the roster-drift endpoint, which now reports MISSING
  memberships as well as unexpected ones.
NOTE
echo

if [[ "$FAILED" != "0" ]]; then
  echo "═══ RESULT: $FAILED invariant(s) FAILED ═══"
  [[ "$MODE" == "dry-run" ]] && echo "    (dry run — re-run with --apply to fix what is fixable)"
  exit 1
fi
echo "═══ RESULT: all invariants pass ═══"
