#!/usr/bin/env bash
# scripts/deploy/seed-user-secrets.sh
# Called by: .github/workflows/apply-changes.yml
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"

KB=~/.kube/config-platform-${ENV_NAME}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"
ROOT_TOKEN=$($KT get secret openbao-unseal -n openbao -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")
if [ -z "$ROOT_TOKEN" ]; then
  echo "Could not get OpenBao root token — skipping seed"
  exit 0
fi
BAO_POD=$($KT get pod -n openbao -l app.kubernetes.io/name=openbao --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$BAO_POD" ]; then
  echo "No running OpenBao pod found — skipping seed"
  exit 0
fi
$KT port-forward -n openbao "pod/${BAO_POD}" 8200:8200 > /tmp/bao-pf.log 2>&1 &
BAO_PF_PID=$!
sleep 4
LOCAL_OPENBAO="http://localhost:8200"
bash scripts/deploy/seed-openbao-authentik.sh "$LOCAL_OPENBAO" "$ROOT_TOKEN"
if [ -n "$SMTP_PASSWORD" ]; then
  EXISTING_DATA=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" \
    "${LOCAL_OPENBAO}/v1/secret/data/platform/authentik" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('data',{}).get('data',{})))" \
    2>/dev/null || echo "{}")
  SMTP_PATCHED=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['smtp-username']=sys.argv[2]; d['smtp-password']=sys.argv[3]; d['smtp-from']=sys.argv[2]; d['smtp-host']='smtp-mail.outlook.com'; d['smtp-port']='587'; print(json.dumps({'data': d}))" \
    "$EXISTING_DATA" "$SMTP_USERNAME" "$SMTP_PASSWORD" 2>/dev/null || echo "")
  if [ -n "$SMTP_PATCHED" ]; then
    curl -s -X POST "${LOCAL_OPENBAO}/v1/secret/data/platform/authentik" \
      -H "X-Vault-Token: $ROOT_TOKEN" -H "Content-Type: application/json" \
      -d "$SMTP_PATCHED" > /dev/null
    echo "==> SMTP credentials updated in OpenBao"
  fi
fi
kill $BAO_PF_PID 2>/dev/null || true
echo "✅ OpenBao secrets seeded/patched" >> $GITHUB_STEP_SUMMARY
