#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/set-user-passwords.sh — Force-set Authentik user passwords from Kubernetes secrets
#
# Usage: ENV_NAME=productie bash scripts/deploy/set-user-passwords.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Cleanup on exit
PF_PID=""
cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
  rm -f /tmp/ak_setpw.py
}
trap cleanup EXIT
KB=~/.kube/config-platform-${ENV_NAME:?ENV_NAME required}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"

# Idempotent password force-set: reads ALL users from users.yaml dynamically.
# Derives the K8s secret key name as "<username>-password".
# Passwords are base64-encoded in the Python script — never appear in ps aux.
echo "==> Force-setting user passwords from authentik-secrets K8s secret (dynamic)..."

# Build list of usernames from users.yaml (one-liner avoids YAML 0-indent issue)
USER_PW_PAIRS=$(python3 -c "import yaml; d=yaml.safe_load(open('users.yaml')); print(' '.join(d.get('users', {}).keys()))")

# Build Python script dynamically: read each user's password from K8s secret
PY_PAIRS="["
HAS_ANY=false
for USERNAME in $USER_PW_PAIRS; do
  SECRET_KEY="${USERNAME}-password"
  PW=$($KT get secret authentik-secrets -n authentik \
    -o jsonpath="{.data.${SECRET_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [ -n "$PW" ]; then
    PW_B64=$(printf '%s' "$PW" | base64 | tr -d '\n')
    PY_PAIRS="${PY_PAIRS}(\"${USERNAME}\", \"${PW_B64}\"),"
    HAS_ANY=true
  else
    echo "  SKIP: no password in authentik-secrets for ${USERNAME}"
  fi
done
PY_PAIRS="${PY_PAIRS}]"

if [ "$HAS_ANY" = "false" ]; then
  echo "⚠️ No user passwords found in authentik-secrets — skipping force-set"
else
  # Write ak_setpw.py via printf (heredoc at col-0 breaks YAML block scalars)
  {
    printf 'import base64\n'
    printf 'from authentik.core.models import User\n'
    printf 'pairs = %s\n' "${PY_PAIRS}"
    printf 'for u, pb64 in pairs:\n'
    printf '    if not pb64:\n'
    printf '        print("SKIP: no password for " + u)\n'
    printf '        continue\n'
    printf '    try:\n'
    printf '        obj = User.objects.get(username=u)\n'
    printf '        obj.set_password(base64.b64decode(pb64).decode())\n'
    printf '        obj.save()\n'
    printf '        print("OK: Password set for " + u)\n'
    printf '    except User.DoesNotExist:\n'
    printf '        print("WARN: User " + u + " not found, skipping")\n'
  } > /tmp/ak_setpw.py
  # Single atomic exec: write script and run it — avoids stale pod name issue.
  cat /tmp/ak_setpw.py | \
    $KT exec -i -n authentik deploy/authentik-worker -c worker -- \
    sh -c 'cat > /tmp/ak_setpw.py && ak shell < /tmp/ak_setpw.py' 2>&1 | tail -10
  rm -f /tmp/ak_setpw.py
  echo "✅ User passwords force-set"
fi

