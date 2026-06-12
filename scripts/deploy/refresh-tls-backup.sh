#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/refresh-tls-backup.sh — Backup LE-issued TLS secrets for restore
#
# Usage:
#   ENV_NAME=productie bash scripts/deploy/refresh-tls-backup.sh [--no-wait]
#   KB=/path/to/kubeconfig bash scripts/deploy/refresh-tls-backup.sh --no-wait
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NO_WAIT=false
for arg in "$@"; do
  case "$arg" in
    --no-wait) NO_WAIT=true ;;
    *)
      echo "Usage: ENV_NAME=productie bash scripts/deploy/refresh-tls-backup.sh [--no-wait]" >&2
      exit 1
      ;;
  esac
done

ENV_NAME="${ENV_NAME:-productie}"
KB="${KB:-$HOME/.kube/config-platform-${ENV_NAME}}"
NAMESPACE="traefik"
BACKUP_DIR="${BACKUP_DIR:-/opt/platform-tls-backup}"
mkdir -p "$BACKUP_DIR"

for cmd in kubectl python3 openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Required command not found: $cmd" >&2
    exit 1
  }
done
python3 -c 'import yaml' >/dev/null 2>&1 || {
  echo "python3 yaml module not available" >&2
  exit 1
}

CERT_LIST_JSON=$(kubectl --kubeconfig "$KB" --insecure-skip-tls-verify get certificates -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
mapfile -t CERT_ROWS < <(python3 - "$CERT_LIST_JSON" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"items": []}

for item in data.get("items", []):
    metadata = item.get("metadata") or {}
    spec = item.get("spec") or {}
    name = (metadata.get("name") or "").strip()
    secret_name = (spec.get("secretName") or "").strip()
    if name and secret_name:
        print(f"{name}\t{secret_name}")
PY
)

if [[ ${#CERT_ROWS[@]} -eq 0 ]]; then
  echo "==> No Certificate resources found in ${NAMESPACE}; nothing to back up"
  exit 0
fi

echo "==> Discovered ${#CERT_ROWS[@]} Certificate resources in ${NAMESPACE}"

wait_for_certificate() {
  local cert_name="$1"
  local ready=""
  local reason=""

  echo "==> Waiting for cert ${cert_name} to be ready (up to 15 min)..."
  for i in $(seq 1 90); do
    ready=$(kubectl --kubeconfig "$KB" --insecure-skip-tls-verify get certificate \
      "$cert_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$ready" == "True" ]]; then
      echo "  ✅ ${cert_name} is ready"
      return 0
    fi

    reason=$(kubectl --kubeconfig "$KB" --insecure-skip-tls-verify get certificate \
      "$cert_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Issuing")].reason}' 2>/dev/null || echo "")
    if [[ "$reason" == "Failed" ]]; then
      echo "  ⚠ ${cert_name} issuance failed (likely LE rate limit) — continuing without backup wait"
      return 1
    fi

    echo "  Waiting for ${cert_name} ($i/90)..."
    sleep 10
  done

  echo "  ⚠ ${cert_name} did not become ready in time — continuing"
  return 1
}

secret_issuer() {
  python3 - "$1" <<'PY'
import base64
import json
import subprocess
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    print("unknown")
    raise SystemExit(0)

cert_b64 = ((data.get("data") or {}).get("tls.crt") or "").strip()
if not cert_b64:
    print("missing tls.crt")
    raise SystemExit(0)

try:
    cert_pem = base64.b64decode(cert_b64)
except Exception:
    print("invalid tls.crt")
    raise SystemExit(0)

result = subprocess.run(
    ["openssl", "x509", "-noout", "-issuer"],
    input=cert_pem,
    capture_output=True,
    check=False,
)
issuer = (result.stdout or result.stderr).decode(errors="replace").strip()
print(issuer or "unknown")
PY
}

sanitize_secret() {
  python3 - "$1" <<'PY'
import json
import sys
import yaml

secret = json.loads(sys.argv[1])
metadata = secret.setdefault("metadata", {})
for key in (
    "resourceVersion",
    "uid",
    "managedFields",
    "ownerReferences",
    "creationTimestamp",
    "selfLink",
    "generation",
):
    metadata.pop(key, None)
metadata["namespace"] = "traefik"
secret.pop("status", None)
sys.stdout.write(yaml.safe_dump(secret, sort_keys=False))
PY
}

if [[ "$NO_WAIT" == "false" ]]; then
  for cert_row in "${CERT_ROWS[@]}"; do
    IFS=$'\t' read -r cert_name _secret_name <<< "$cert_row"
    wait_for_certificate "$cert_name" || true
  done
else
  echo "==> --no-wait enabled; skipping readiness waits"
fi

echo "==> Saving available TLS secret backups..."
for cert_row in "${CERT_ROWS[@]}"; do
  IFS=$'\t' read -r cert_name secret_name <<< "$cert_row"
  ready=$(kubectl --kubeconfig "$KB" --insecure-skip-tls-verify get certificate \
    "$cert_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$ready" != "True" ]]; then
    echo "  ⚠ ${cert_name} is not Ready — attempting to back up existing secret ${secret_name} if present"
  fi

  SECRET_JSON=$(kubectl --kubeconfig "$KB" --insecure-skip-tls-verify get secret \
    "$secret_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "")
  if [[ -z "$SECRET_JSON" ]]; then
    echo "  ⚠ ${secret_name} not available for backup"
    continue
  fi

  CERT_ISSUER=$(secret_issuer "$SECRET_JSON")
  issuer_lc=$(printf '%s' "$CERT_ISSUER" | tr '[:upper:]' '[:lower:]')
  if [[ "$issuer_lc" == *"let"* ]] || [[ "$issuer_lc" == *"isrg"* ]] || [[ "$issuer_lc" == *"letsencrypt"* ]]; then
    sanitize_secret "$SECRET_JSON" > "$BACKUP_DIR/${secret_name}.yaml"
    echo "  ✅ Backup updated: ${secret_name} (issuer: ${CERT_ISSUER})"
  else
    echo "  ⚠ ${secret_name} issuer is not Let's Encrypt (${CERT_ISSUER}) — skipping"
  fi
done

