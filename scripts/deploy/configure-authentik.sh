#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/configure-authentik.sh — Set Authentik admin privileges, groups, and SSO providers
#
# Usage: ENV_NAME=productie bash scripts/deploy/configure-authentik.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Cleanup on exit
SETUP_PF_PID=""
cleanup() {
  [[ -n "${SETUP_PF_PID:-}" ]] && kill "$SETUP_PF_PID" 2>/dev/null || true
  rm -f /tmp/ak_groups.py /tmp/authentik-pf-setup.log /tmp/users.yaml /tmp/ak_token.py
}
trap cleanup EXIT
KB=~/.kube/config-platform-${ENV_NAME:?ENV_NAME required}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"

# Wait for Authentik worker to be ready — replaces separate ArgoCD health check + rollout
# Directly polls the deployment readyReplicas (10s intervals, up to 12 minutes).
# Faster than waiting for ArgoCD app health first (saves the ArgoCD health loop overhead).
echo "==> Waiting for Authentik worker deployment to be ready..."
$KT wait deployment/authentik-worker -n authentik \
  --for=condition=Available --timeout=1200s
# Also wait for the pod itself to be Ready (Available != pod Ready)
$KT wait pod -n authentik -l app.kubernetes.io/component=worker \
  --for=condition=Ready --timeout=120s 2>/dev/null || true
echo "  ✅ Authentik worker ready"

# Wait for all users defined in users.yaml to be created (parallel checks).
# Blueprints create users async; worker may be ready before users exist.
_wait_for_user() {
  local username="$1"
  echo "==> Waiting for ${username} user to be created by blueprint..."
  for i in $(seq 1 60); do
    # Use | tail -1 to strip ak shell JSON boot logs from stdout,
    # keeping only the final print() output ("yes" or "no")
    USER_EXISTS=$($KT exec -n authentik deploy/authentik-worker -c worker -- ak shell -c \
      "from authentik.core.models import User; print('yes' if User.objects.filter(username='${username}').exists() else 'no')" \
      2>/dev/null | tail -1 || echo "no")
    [ "$USER_EXISTS" = "yes" ] && echo "  ✅ ${username} user found" && return 0
    echo "  [${i}/60] ${username} exists: no"
    sleep 10
  done
  echo "  ⚠️ ${username} user not found after timeout — continuing anyway"
  return 1
}
# Launch all user checks in parallel
# Base64-encoded Python avoids YAML column-0 parsing issues in block scalars.
_ALL_USERS_PY="aW1wb3J0IHlhbWwKdXNlcnMgPSB5YW1sLnNhZmVfbG9hZChvcGVuKCJ1c2Vycy55YW1sIikpWyJ1c2VycyJdCmZvciB1IGluIHVzZXJzOgogICAgcHJpbnQodSkK"
declare -a USER_WAIT_PIDS=()
for _uname in $(echo "$_ALL_USERS_PY" | base64 -d | python3); do
  _wait_for_user "$_uname" &
  USER_WAIT_PIDS+=($!)
done
# Wait for all parallel checks to complete
for _pid in "${USER_WAIT_PIDS[@]}"; do
  wait "$_pid" || true
done
echo "==> Setting user group memberships..."
# Dynamic: reads from users.yaml (authentik_groups per user) — no hardcoded usernames.
# Base64-encoded Python avoids YAML column-0 parsing issues in block scalars.
# Script reads authentik_groups from users.yaml; sets is_superuser for 'authentik Admins'.
_GROUPS_PY="aW1wb3J0IHlhbWwKZnJvbSBhdXRoZW50aWsuY29yZS5tb2RlbHMgaW1wb3J0IFVzZXIsIEdyb3VwCgp3aXRoIG9wZW4oJy90bXAvdXNlcnMueWFtbCcsICdyJykgYXMgZjoKICAgIHVzZXJzX2RhdGEgPSB5YW1sLnNhZmVfbG9hZChmKQoKZm9yIHVzZXJuYW1lLCB1c2VyX2NmZyBpbiB1c2Vyc19kYXRhLmdldCgndXNlcnMnLCB7fSkuaXRlbXMoKToKICAgIHRyeToKICAgICAgICB1c2VyID0gVXNlci5vYmplY3RzLmdldCh1c2VybmFtZT11c2VybmFtZSkKICAgIGV4Y2VwdCBVc2VyLkRvZXNOb3RFeGlzdDoKICAgICAgICBwcmludCgnV0FSTjogVXNlciAnICsgdXNlcm5hbWUgKyAnIG5vdCBmb3VuZCwgc2tpcHBpbmcnKQogICAgICAgIGNvbnRpbnVlCgogICAgZ3JvdXBzID0gdXNlcl9jZmcuZ2V0KCdhdXRoZW50aWtfZ3JvdXBzJywgW10pCiAgICBmb3IgZ3JvdXBfbmFtZSBpbiBncm91cHM6CiAgICAgICAgZ3JwLCBfID0gR3JvdXAub2JqZWN0cy5nZXRfb3JfY3JlYXRlKG5hbWU9Z3JvdXBfbmFtZSkKICAgICAgICBncnAudXNlcnMuYWRkKHVzZXIpCiAgICAgICAgcHJpbnQoJ09LOiBBZGRlZCAnICsgdXNlcm5hbWUgKyAnIHRvICcgKyBncm91cF9uYW1lKQoKICAgIGlmICdhdXRoZW50aWsgQWRtaW5zJyBpbiBncm91cHM6CiAgICAgICAgdXNlci5pc19zdXBlcnVzZXIgPSBUcnVlCiAgICAgICAgdXNlci5zYXZlKCkKICAgICAgICBwcmludCgnT0s6IFNldCAnICsgdXNlcm5hbWUgKyAnIGFzIHN1cGVydXNlcicpCg=="
# Two fast atomic execs using deploy/ target — avoids stale pod name issue.
# deploy/authentik-worker resolves to the current live pod each time.
# users.yaml carries ${ADMIN_USERNAME}/${ADMIN_NAME}/${ADMIN_EMAIL} placeholders for
# the owner entry. Substitute them first — otherwise the group-sync looks up a user
# literally named "${ADMIN_USERNAME}", skips the owner, and never adds them to
# platform-admins (so the console grants no admin role and shows no active cluster).
envsubst '${ADMIN_USERNAME} ${ADMIN_NAME} ${ADMIN_EMAIL}' < users.yaml | $KT exec -i -n authentik deploy/authentik-worker -c worker -- sh -c 'cat > /tmp/users.yaml'
echo "$_GROUPS_PY" | base64 -d | \
  $KT exec -i -n authentik deploy/authentik-worker -c worker -- \
  sh -c 'cat > /tmp/ak_groups.py && ak shell < /tmp/ak_groups.py' 2>&1 | tail -10
echo "✅ User group memberships set"

# Generate recovery links for all users with send_recovery_email: true
# Stores AUTHENTIK_{USERNAME_UPPER}_RECOVERY_LINK in $GITHUB_ENV for email step
echo "==> Configuring recovery flow and generating password recovery links..."
_AK_PY="ZnJvbSBhdXRoZW50aWsuY29yZS5tb2RlbHMgaW1wb3J0IFRva2VuLCBUb2tlbkludGVudHMsIFVzZXIKZnJvbSBhdXRoZW50aWsuYnJhbmRzLm1vZGVscyBpbXBvcnQgQnJhbmQKZnJvbSBhdXRoZW50aWsuZmxvd3MubW9kZWxzIGltcG9ydCBGbG93LCBGbG93RGVzaWduYXRpb24KCmZsb3csIF8gPSBGbG93Lm9iamVjdHMuZ2V0X29yX2NyZWF0ZShzbHVnPSJkZWZhdWx0LXJlY292ZXJ5LWZsb3ciLCBkZWZhdWx0cz17Im5hbWUiOiAiRGVmYXVsdCBSZWNvdmVyeSBGbG93IiwgInRpdGxlIjogIkFjY291bnQgUmVjb3ZlcnkiLCAiZGVzaWduYXRpb24iOiBGbG93RGVzaWduYXRpb24uUkVDT1ZFUll9KQpmb3IgYnJhbmQgaW4gQnJhbmQub2JqZWN0cy5hbGwoKToKICAgIGJyYW5kLmZsb3dfcmVjb3ZlcnkgPSBmbG93CiAgICBicmFuZC5zYXZlKCkKClRva2VuLm9iamVjdHMuZmlsdGVyKGlkZW50aWZpZXI9ImdoLWFjdGlvbnMtYXBpLXRva2VuIikuZGVsZXRlKCkKYWRtaW4gPSBVc2VyLm9iamVjdHMuZ2V0KHVzZXJuYW1lPSJha2FkbWluIikKdCA9IFRva2VuLm9iamVjdHMuY3JlYXRlKGlkZW50aWZpZXI9ImdoLWFjdGlvbnMtYXBpLXRva2VuIiwgdXNlcj1hZG1pbiwgZGVzY3JpcHRpb249IkdpdEh1YiBBY3Rpb25zIEFQSSB0b2tlbiIsIGludGVudD1Ub2tlbkludGVudHMuSU5URU5UX0FQSSwgZXhwaXJpbmc9RmFsc2UpCnByaW50KCJUT0tFTjoiICsgdC5rZXkpCg=="
# Single atomic exec: write script and run it in one connection to avoid stale pod name.
AUTHENTIK_ADMIN_TOKEN=$(echo "$_AK_PY" | base64 -d | \
  $KT exec -i -n authentik deploy/authentik-worker -c worker -- \
  sh -c 'cat > /tmp/ak_token.py && ak shell < /tmp/ak_token.py' \
  2>&1 | grep "^TOKEN:" | sed 's/TOKEN://' || echo "")
echo "AUTHENTIK_ADMIN_TOKEN=${AUTHENTIK_ADMIN_TOKEN}" >> "${GITHUB_ENV:-/dev/null}"
# Also persist to temp file for local deploys (GITHUB_ENV is /dev/null locally)
if [ -n "${IW_AUTH_ENV_FILE:-}" ]; then
  echo "export AUTHENTIK_ADMIN_TOKEN=${AUTHENTIK_ADMIN_TOKEN}" >> "$IW_AUTH_ENV_FILE"
fi

$KT port-forward svc/authentik-server -n authentik 8089:80 > /tmp/authentik-pf-setup.log 2>&1 &
SETUP_PF_PID=$!
sleep 4

# Generate NON-EXPIRING recovery / password-set links for ADMIN users. DYNAMIC:
# covers every users.yaml entry with access_level: admin + send_recovery_email
# (not hardcoded to any one owner). Non-admin users get their own welcome email.
#
# Done entirely via `ak shell` — NO /recovery/ API call and NO dependency on the
# port-forward/admin API token, all of which were failure points that previously
# left "⚠ Recovery link unavailable — log in as akadmin" in the deploy email.
# Each link is backed by a Token(intent=RECOVERY, expiring=False) → it NEVER
# expires, so the owner can set their password from the welcome email at any time.
# Base64-encoded Python avoids YAML column-0 parsing issues in block scalars.
_ADMIN_USERS_PY="aW1wb3J0IHlhbWwKdXNlcnMgPSB5YW1sLnNhZmVfbG9hZChvcGVuKCJ1c2Vycy55YW1sIikpWyJ1c2VycyJdCmZvciB1LCBkIGluIHVzZXJzLml0ZW1zKCk6CiAgICBpZiBkLmdldCgiYWNjZXNzX2xldmVsIikgPT0gImFkbWluIiBhbmQgZC5nZXQoInNlbmRfcmVjb3ZlcnlfZW1haWwiKToKICAgICAgICBwcmludCh1KQo="
_ADMIN_USERS_B64=$(echo "$_ADMIN_USERS_PY" | base64 -d | python3 -c \
  "import sys,json,base64; print(base64.b64encode(json.dumps([l.strip() for l in sys.stdin if l.strip()]).encode()).decode())" 2>/dev/null || echo "")
_RECOVERY_OUT=$(cat <<PYEOF | $KT exec -i -n authentik deploy/authentik-worker -c worker -- sh -c 'cat > /tmp/ak_recovery.py && ak shell < /tmp/ak_recovery.py' 2>/dev/null || echo ""
import base64, json
from importlib import import_module
from django.conf import settings
from django.test import RequestFactory
from django.contrib.auth.models import AnonymousUser
from authentik.core.models import User
from authentik.brands.models import Brand
from authentik.flows.models import Flow, FlowDesignation, FlowToken
from authentik.flows.planner import FlowPlanner, PLAN_CONTEXT_PENDING_USER
from authentik.stages.email.flow import pickle_flow_token_for_email
flow, _ = Flow.objects.get_or_create(slug="default-recovery-flow", defaults={"name": "Default Recovery Flow", "title": "Account Recovery", "designation": FlowDesignation.RECOVERY})
for brand in Brand.objects.all():
    if not brand.flow_recovery:
        brand.flow_recovery = flow
        brand.save()
for username in (json.loads(base64.b64decode("${_ADMIN_USERS_B64}").decode()) if "${_ADMIN_USERS_B64}" else []):
    u = User.objects.filter(username=username).first()
    if not u:
        continue
    # Build a real FlowPlan with the pending user baked in (same mechanism as the
    # /api/v3/core/users/{id}/recovery/ endpoint) and persist it as a NON-EXPIRING
    # FlowToken. A bare Token(intent=RECOVERY) does NOT inject the pending user, so
    # the final UserWriteStage fails with "No user found" — hence FlowToken here.
    req = RequestFactory().get("/")
    req.session = import_module(settings.SESSION_ENGINE).SessionStore()
    req.user = AnonymousUser()
    planner = FlowPlanner(flow)
    planner.allow_empty_flows = True
    plan = planner.plan(req, {PLAN_CONTEXT_PENDING_USER: u})
    ident = "welcome-recovery-" + username
    FlowToken.objects.filter(identifier=ident).delete()
    # pickle_flow_token_for_email inserts the anti-scanner consent stage AND keeps
    # the pending user across the email cold-start; revoke_on_execution=False +
    # expiring=False = the link never expires. Verified end-to-end (password set OK).
    t = FlowToken.objects.create(identifier=ident, user=u, flow=flow, _plan=pickle_flow_token_for_email(plan), revoke_on_execution=False, expiring=False)
    print("RECOVERY\t" + username + "\t" + t.key)
PYEOF
)
while IFS=$'\t' read -r _tag _username _key; do
  [ "$_tag" = "RECOVERY" ] || continue
  [ -n "$_key" ] || continue
  LINK="https://auth.${BASE_DOMAIN}/if/flow/default-recovery-flow/?flow_token=${_key}"
  ENV_VAR="AUTHENTIK_$(echo "$_username" | tr '[:lower:]' '[:upper:]')_RECOVERY_LINK"
  echo "${ENV_VAR}=${LINK}" >> "${GITHUB_ENV:-/dev/null}"
  if [ -n "${IW_AUTH_ENV_FILE:-}" ]; then
    printf 'export %s=%q\n' "$ENV_VAR" "$LINK" >> "$IW_AUTH_ENV_FILE"
  fi
  echo "✅ Recovery link generated for ${_username} (non-expiring)"
done <<< "$_RECOVERY_OUT"
kill $SETUP_PF_PID 2>/dev/null || true

# ── LDAP outpost setup: REMOVED 2026-08-07 ───────────────────────────────────
# This script used to create an Authentik LDAP provider, application and outpost
# here, and seed secret/platform/authentik-ldap-outpost in OpenBao.
#
# It was removed because the outpost was dead end-to-end, measured:
#   * Authentik held ZERO LDAP providers and no LDAP outpost object.
#   * The k8s Secret, the ExternalSecret and the OpenBao path did not exist.
#     (The backlog's "empty token" reading was an artefact — `kubectl get` wrote
#     NotFound to stderr, and sha256 of empty stdin is the empty-string hash.)
#   * The Service VIP stayed <pending> forever: outpost.yaml asked for
#     ${METALLB_LDAP_VIP}, which was never in the CMP allowlist, so the
#     placeholder could never be substituted.
#   * The Deployment sat at 0/0 for 54 days with no user-visible impact.
#   * TrueNAS — the one named consumer — has LDAP `"enable": false`, pointing at
#     the VIP that was never assigned, with a binddn for a user that does not
#     exist. TrueNAS actually authenticates through the EMBEDDED outpost's
#     forward-auth provider (`route-truenas`), which is untouched.
#
# Leaving this block would have re-created the whole dead apparatus on the next
# DR rebuild. If LDAP is ever genuinely needed, it needs more than this script:
# a real provider + outpost + token, the OpenBao path seeded, METALLB_LDAP_VIP
# added to the CMP allowlist AND scripts/emit-cmp-substitutions.sh AND the live
# ConfigMap, a MetalLB pool covering the VIP, and TrueNAS pointed at it with
# `enable: true`. See docs/BREAK-GLASS.md §10.
