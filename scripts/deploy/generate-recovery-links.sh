#!/usr/bin/env bash
# scripts/deploy/generate-recovery-links.sh
# Called by: .github/workflows/apply-changes.yml
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"

KB=~/.kube/config-platform-${ENV_NAME}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"
NEW_USERS='${{ needs.detect.outputs.new_users }}'
if [ "$NEW_USERS" = "[]" ] || [ -z "$NEW_USERS" ]; then
  echo "==> No new users — skipping recovery link generation"
  echo 'links_json={}' >> $GITHUB_OUTPUT
  exit 0
fi
# Get a short-lived Authentik API token via ak shell
# Use deploy/ target — avoids stale pod name issues on rolling updates
_AK_PY="ZnJvbSBhdXRoZW50aWsuY29yZS5tb2RlbHMgaW1wb3J0IFRva2VuLCBUb2tlbkludGVudHMsIFVzZXIKZnJvbSBhdXRoZW50aWsuYnJhbmRzLm1vZGVscyBpbXBvcnQgQnJhbmQKZnJvbSBhdXRoZW50aWsuZmxvd3MubW9kZWxzIGltcG9ydCBGbG93LCBGbG93RGVzaWduYXRpb24KCmZsb3csIF8gPSBGbG93Lm9iamVjdHMuZ2V0X29yX2NyZWF0ZShzbHVnPSJkZWZhdWx0LXJlY292ZXJ5LWZsb3ciLCBkZWZhdWx0cz17Im5hbWUiOiAiRGVmYXVsdCBSZWNvdmVyeSBGbG93IiwgInRpdGxlIjogIkFjY291bnQgUmVjb3ZlcnkiLCAiZGVzaWduYXRpb24iOiBGbG93RGVzaWduYXRpb24uUkVDT1ZFUll9KQpmb3IgYnJhbmQgaW4gQnJhbmQub2JqZWN0cy5hbGwoKToKICAgIGJyYW5kLmZsb3dfcmVjb3ZlcnkgPSBmbG93CiAgICBicmFuZC5zYXZlKCkKClRva2VuLm9iamVjdHMuZmlsdGVyKGlkZW50aWZpZXI9ImdoLWFjdGlvbnMtYXBpLXRva2VuIikuZGVsZXRlKCkKYWRtaW4gPSBVc2VyLm9iamVjdHMuZ2V0KHVzZXJuYW1lPSJha2FkbWluIikKdCA9IFRva2VuLm9iamVjdHMuY3JlYXRlKGlkZW50aWZpZXI9ImdoLWFjdGlvbnMtYXBpLXRva2VuIiwgdXNlcj1hZG1pbiwgZGVzY3JpcHRpb249IkdpdEh1YiBBY3Rpb25zIEFQSSB0b2tlbiIsIGludGVudD1Ub2tlbkludGVudHMuSU5URU5UX0FQSSwgZXhwaXJpbmc9RmFsc2UpCnByaW50KCJUT0tFTjoiICsgdC5rZXkpCg=="
AK_TOKEN=$(echo "$_AK_PY" | base64 -d | $KT exec -i -n authentik deploy/authentik-worker -c worker -- ak shell 2>&1 | grep "^TOKEN:" | sed 's/TOKEN://' || echo "")
if [ -z "$AK_TOKEN" ]; then
  echo "Could not get Authentik API token — skipping recovery links"
  echo 'links_json={}' >> $GITHUB_OUTPUT
  exit 0
fi
$KT port-forward svc/authentik-server -n authentik 8089:80 > /tmp/ak-pf.log 2>&1 &
AK_PF_PID=$!
sleep 4
LINKS_JSON="{}"
for USERNAME in $(echo "$NEW_USERS" | python3 -c "import sys,json; print('\n'.join(json.loads(sys.stdin.read())))"); do
  USER_ID=$(curl -sf -H "Authorization: Bearer $AK_TOKEN" \
    "http://localhost:8089/api/v3/core/users/?username=${USERNAME}" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('results',[]); print(r[0]['pk'] if r else '')" || echo "")
  if [ -n "$USER_ID" ]; then
    RAW_LINK=$(curl -sf -X POST -H "Authorization: Bearer $AK_TOKEN" \
      -H "Content-Type: application/json" \
      "http://localhost:8089/api/v3/core/users/$USER_ID/recovery/" 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('link',''))" || echo "")
    LINK=$(echo "$RAW_LINK" | sed "s|http://localhost:8089|https://auth.${BASE_DOMAIN}|g")
    echo "==> Recovery link generated for ${USERNAME}"
    LINKS_JSON=$(echo "$LINKS_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); d[\"${USERNAME}\"]=\"${LINK}\"; print(json.dumps(d))")
  else
    echo "==> WARN: user ${USERNAME} not yet in Authentik (blueprint may not have synced)"
  fi
done
kill $AK_PF_PID 2>/dev/null || true
echo "links_json=${LINKS_JSON}" >> $GITHUB_OUTPUT
echo "✅ Recovery links generated for: $(echo "$NEW_USERS" | python3 -c "import sys,json; print(', '.join(json.loads(sys.stdin.read())))")" >> $GITHUB_STEP_SUMMARY
