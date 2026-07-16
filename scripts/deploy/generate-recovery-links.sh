#!/usr/bin/env bash
# scripts/deploy/generate-recovery-links.sh
# Called by: .github/workflows/apply-changes.yml
#
# Generates a NON-EXPIRING ("infinite duration") Authentik recovery / password-set
# link for each newly-detected platform user. Each link is backed by a
# Token(intent=RECOVERY, expiring=False) bound to the default-recovery-flow, so the
# user can set their password from the welcome email at any time — no akadmin
# break-glass reset needed. Done entirely via `ak shell` (no port-forward and no
# /recovery/ API endpoint, which mints a SHORT-LIVED token and was a failure point).
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"
: "${BASE_DOMAIN:?BASE_DOMAIN is required to build recovery links}"

KB=~/.kube/config-platform-${ENV_NAME}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"
NEW_USERS='${{ needs.detect.outputs.new_users }}'
if [ "$NEW_USERS" = "[]" ] || [ -z "$NEW_USERS" ]; then
  echo "==> No new users — skipping recovery link generation"
  echo 'links_json={}' >> $GITHUB_OUTPUT
  exit 0
fi

# Pass the JSON user list into ak shell base64-encoded; mint one permanent token
# per user and print "RECOVERY<TAB>username<TAB>key" lines we parse below.
_USERS_B64=$(printf '%s' "$NEW_USERS" | base64 -w0)
RECOVERY_OUT=$(cat <<PYEOF | $KT exec -i -n authentik deploy/authentik-worker -c worker -- sh -c 'cat > /tmp/ak_recovery.py && ak shell < /tmp/ak_recovery.py' 2>/dev/null || echo ""
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
for username in json.loads(base64.b64decode("${_USERS_B64}").decode()):
    u = User.objects.filter(username=username).first()
    if not u:
        continue
    # FlowToken (not a bare Token) so the pending user is baked into the plan and
    # the final UserWriteStage can set the password; expiring=False = never expires.
    req = RequestFactory().get("/")
    req.session = import_module(settings.SESSION_ENGINE).SessionStore()
    req.user = AnonymousUser()
    planner = FlowPlanner(flow)
    planner.allow_empty_flows = True
    plan = planner.plan(req, {PLAN_CONTEXT_PENDING_USER: u})
    ident = "welcome-recovery-" + username
    FlowToken.objects.filter(identifier=ident).delete()
    # Email-pickled plan (anti-scanner consent + preserves pending user) and a
    # non-expiring, non-revoking token so the link never expires. Verified working.
    t = FlowToken.objects.create(identifier=ident, user=u, flow=flow, _plan=pickle_flow_token_for_email(plan), revoke_on_execution=False, expiring=False)
    print("RECOVERY\t" + username + "\t" + t.key)
PYEOF
)

LINKS_JSON="{}"
while IFS=$'\t' read -r _tag _username _key; do
  [ "$_tag" = "RECOVERY" ] || continue
  [ -n "$_key" ] || continue
  LINK="https://auth.${BASE_DOMAIN}/if/flow/default-recovery-flow/?flow_token=${_key}"
  echo "==> Permanent (non-expiring) recovery link generated for ${_username}"
  LINKS_JSON=$(echo "$LINKS_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); d['${_username}']='${LINK}'; print(json.dumps(d))")
done <<< "$RECOVERY_OUT"

echo "links_json=${LINKS_JSON}" >> $GITHUB_OUTPUT
echo "✅ Recovery links generated for: $(echo "$NEW_USERS" | python3 -c "import sys,json; print(', '.join(json.loads(sys.stdin.read())))")" >> $GITHUB_STEP_SUMMARY
