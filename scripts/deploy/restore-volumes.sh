#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/restore-volumes.sh — Restore TLS secrets and PVC backups
# during deploy-local.sh when RESTORE_ENABLED=true.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="restore-volumes"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

RESTORE_ENABLED="${RESTORE_ENABLED:-false}"
RESTORE_TLS="${RESTORE_TLS:-false}"
RESTORE_VOLUMES="${RESTORE_VOLUMES:-}"
KUBECONFIG="${KB_FILE:-$HOME/.kube/config-platform-${ENV_NAME:-productie}}"
export KUBECONFIG

BACKUP_DIR="/opt/platform-tls-backup"

require_cmd kubectl python3 bash
python3 -c 'import yaml' >/dev/null 2>&1 || die "python3 yaml module not available"

if [[ "$RESTORE_ENABLED" != "true" ]]; then
  log "RESTORE_ENABLED=false — skipping restore"
  exit 0
fi

if [[ "$RESTORE_TLS" != "true" && -z "$RESTORE_VOLUMES" ]]; then
  log "No TLS secrets or PVC volumes requested for restore"
  exit 0
fi

restore_tls_secret() {
  local backup_file="$1"
  local secret_name
  secret_name="$(basename "$backup_file" .yaml)"

  log "Restoring TLS secret: $secret_name"
  python3 - "$backup_file" <<'PY' | kubectl apply -f - >/dev/null
from pathlib import Path
import sys
import yaml

backup_file = Path(sys.argv[1])
data = yaml.safe_load(backup_file.read_text())
if not isinstance(data, dict):
    raise SystemExit(f"Invalid Kubernetes manifest: {backup_file}")
metadata = data.setdefault("metadata", {})
for key in ("resourceVersion", "uid", "creationTimestamp"):
    metadata.pop(key, None)
metadata["namespace"] = "traefik"
sys.stdout.write(yaml.safe_dump(data, sort_keys=False))
PY
  sleep 2
  ok "TLS secret restored: $secret_name"
}

if [[ "$RESTORE_TLS" == "true" ]]; then
  log "Checking TLS backups in $BACKUP_DIR ..."
  kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  shopt -s nullglob
  backup_files=("$BACKUP_DIR"/*.yaml)
  shopt -u nullglob

  if [[ ${#backup_files[@]} -eq 0 ]]; then
    warn "No TLS backup files found in $BACKUP_DIR"
  else
    for backup_file in "${backup_files[@]}"; do
      restore_tls_secret "$backup_file"
    done
  fi
else
  log "RESTORE_TLS=false — skipping TLS restore"
fi

if [[ -n "$RESTORE_VOLUMES" ]]; then
  log "Restoring PVC volumes: $RESTORE_VOLUMES"
  bash scripts/restore-from-truenas.sh --volumes "$RESTORE_VOLUMES"
  ok "PVC volume restore requested"
else
  log "RESTORE_VOLUMES is empty — skipping PVC restore"
fi

ok "Restore workflow finished"
