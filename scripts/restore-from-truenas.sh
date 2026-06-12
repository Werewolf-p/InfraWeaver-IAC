#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# restore-from-truenas.sh — Restore persistent Longhorn volumes from TrueNAS NFS
#
# WHEN TO RUN:
#   After a full cluster redeploy (new cluster, wiped nodes), BEFORE deploying
#   apps. This ensures stateful apps (OneDev, Vaultwarden, n8n, wiki, etc.)
#   start with their previous data instead of blank volumes.
#
# WHAT IT DOES:
#   1. Port-forwards the Longhorn API from the freshly deployed cluster
#   2. Lists all available backups on TrueNAS NFS for each known volume
#   3. For each volume with a backup, creates a Longhorn RestoreVolume job
#   4. Waits for each restore to complete
#   5. The restored PVCs are then bound when ArgoCD syncs the apps
#
# USAGE:
#   export KUBECONFIG=~/.kube/config-platform-productie
#   bash scripts/restore-from-truenas.sh
#
#   # Restore only specific volumes:
#   bash scripts/restore-from-truenas.sh --volumes "onedev-data,vaultwarden-data"
#
#   # Dry run (list available backups, don't restore):
#   bash scripts/restore-from-truenas.sh --dry-run
#
# REQUIREMENTS:
#   - kubectl configured for the target cluster
#   - Longhorn deployed and NFS backup target reachable
#   - jq installed
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="restore-from-truenas"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
fail() { echo -e "${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $*${NC}"; }

DRY_RUN=false
VOLUMES_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --volumes) VOLUMES_FILTER="$2"; shift 2 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# ── All volumes annotated for truenas-backup ──────────────────────────────────
# Update this list when adding new persistent apps.
ALL_VOLUMES=(
  "onedev-data"
  "vaultwarden-data"
  "n8n-data"
  "minio-velero-data"
  "data-wiki-postgresql-0"   # wiki Helm chart PVC name
)

# Apply filter if provided
if [ -n "$VOLUMES_FILTER" ]; then
  IFS=',' read -ra ALL_VOLUMES <<< "$VOLUMES_FILTER"
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || fail "kubectl not found"
command -v jq &>/dev/null || fail "jq not found"

KB="${KUBECONFIG:-$HOME/.kube/config}"
KT="kubectl --kubeconfig=$KB"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Longhorn → TrueNAS Restore for Fresh Cluster Deploy ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ── Wait for Longhorn to be ready ─────────────────────────────────────────────
info "Waiting for Longhorn manager to be ready..."
$KT rollout status deployment/longhorn-manager -n longhorn-system --timeout=300s || \
  fail "Longhorn manager not ready — ensure Longhorn is deployed before running this script"
ok "Longhorn manager is ready"

# ── Port-forward Longhorn API ─────────────────────────────────────────────────
LONGHORN_PORT=9500
LH_PF_PID=""

cleanup() {
  [ -n "$LH_PF_PID" ] && kill "$LH_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

info "Starting Longhorn API port-forward on :$LONGHORN_PORT ..."
$KT port-forward -n longhorn-system svc/longhorn-frontend $LONGHORN_PORT:80 &>/dev/null &
LH_PF_PID=$!
sleep 3

LH_API="http://localhost:$LONGHORN_PORT/v1"

# Verify API is reachable
curl -sf "$LH_API" -o /dev/null || fail "Longhorn API not reachable on port $LONGHORN_PORT"
ok "Longhorn API reachable"

# ── Check backup target ───────────────────────────────────────────────────────
info "Checking backup target status..."
BT_STATUS=$(curl -sf "$LH_API/settings/backup-target" | jq -r '.value' 2>/dev/null || echo "")
if [ -z "$BT_STATUS" ] || [ "$BT_STATUS" = "null" ]; then
  fail "Longhorn backup target is not configured. Set backupTarget in Longhorn values.yaml."
fi
ok "Backup target: $BT_STATUS"

# ── List and restore backups ──────────────────────────────────────────────────
echo ""
info "Available backups on TrueNAS:"
echo ""

RESTORED=0
SKIPPED=0

for VOL_NAME in "${ALL_VOLUMES[@]}"; do
  echo "── $VOL_NAME ──────────────────────────────────────────"

  # List backups for this volume from Longhorn API
  BACKUPS=$(curl -sf "$LH_API/backupvolumes/$VOL_NAME/backups" 2>/dev/null | \
    jq -r '.data | sort_by(.snapshotCreatedAt) | last | "\(.name) (\(.snapshotCreatedAt // "unknown date"))"' \
    2>/dev/null || echo "")

  if [ -z "$BACKUPS" ] || [ "$BACKUPS" = "null null" ]; then
    warn "  No backups found for $VOL_NAME — will start with empty volume"
    ((SKIPPED++)) || true
    continue
  fi

  echo "  Latest backup: $BACKUPS"

  # Get the backup URL for restore
  BACKUP_URL=$(curl -sf "$LH_API/backupvolumes/$VOL_NAME/backups" 2>/dev/null | \
    jq -r '.data | sort_by(.snapshotCreatedAt) | last | .url' 2>/dev/null || echo "")

  if [ -z "$BACKUP_URL" ] || [ "$BACKUP_URL" = "null" ]; then
    warn "  Could not determine backup URL — skipping $VOL_NAME"
    ((SKIPPED++)) || true
    continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    info "  [dry-run] Would restore from: $BACKUP_URL"
    continue
  fi

  # Check if volume already exists (previous restore or manual creation)
  EXISTING=$(curl -sf "$LH_API/volumes/$VOL_NAME" 2>/dev/null | jq -r '.name' 2>/dev/null || echo "")
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    warn "  Volume $VOL_NAME already exists — skipping restore (delete it first if you want a fresh restore)"
    ((SKIPPED++)) || true
    continue
  fi

  # Create the restore job via Longhorn API
  info "  Restoring $VOL_NAME from backup..."
  RESTORE_RESULT=$(curl -sf -X POST "$LH_API/volumes" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$VOL_NAME\",
      \"fromBackup\": \"$BACKUP_URL\",
      \"numberOfReplicas\": 3,
      \"dataLocality\": \"best-effort\",
      \"accessMode\": \"rwo\"
    }" 2>/dev/null | jq -r '.name' 2>/dev/null || echo "")

  if [ -z "$RESTORE_RESULT" ] || [ "$RESTORE_RESULT" = "null" ]; then
    warn "  Restore API call failed for $VOL_NAME — check Longhorn UI manually"
    ((SKIPPED++)) || true
    continue
  fi

  ok "  Restore started for $VOL_NAME"
  ((RESTORED++)) || true
done

# ── Wait for restores to complete ─────────────────────────────────────────────
if [ "$RESTORED" -gt 0 ] && [ "$DRY_RUN" = "false" ]; then
  echo ""
  info "Waiting for $RESTORED restore(s) to complete (timeout: 10 minutes)..."
  TIMEOUT=600
  ELAPSED=0
  INTERVAL=15

  while [ $ELAPSED -lt $TIMEOUT ]; do
    ALL_READY=true
    for VOL_NAME in "${ALL_VOLUMES[@]}"; do
      STATUS=$(curl -sf "$LH_API/volumes/$VOL_NAME" 2>/dev/null | \
        jq -r '.state' 2>/dev/null || echo "unknown")
      if [ "$STATUS" != "detached" ] && [ "$STATUS" != "attached" ]; then
        ALL_READY=false
        break
      fi
    done

    if [ "$ALL_READY" = "true" ]; then
      break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "  ... still restoring (${ELAPSED}s elapsed)"
  done

  if [ "$ALL_READY" = "true" ]; then
    ok "All volumes restored successfully"
  else
    warn "Some volumes may still be restoring — check Longhorn UI before deploying apps"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════╗"
echo "║       Restore Summary          ║"
echo "╚═══════════════════════════════╝"
if [ "$DRY_RUN" = "true" ]; then
  echo "  Mode: DRY RUN (no changes made)"
else
  echo "  Restored: $RESTORED volume(s)"
  echo "  Skipped:  $SKIPPED volume(s)"
fi
echo ""
info "Next step: trigger ArgoCD sync for apps — they will bind to restored PVCs"
info "  argocd app sync catalog-onedev-manifests catalog-vaultwarden-manifests catalog-n8n-manifests"
echo ""
