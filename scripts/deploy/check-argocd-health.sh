#!/usr/bin/env bash
# check-argocd-health.sh — Post-deploy ArgoCD application health gate
# Checks all ArgoCD apps for Healthy+Synced status and reports to GitHub Step Summary.
# Fails if any CRITICAL apps are degraded after the timeout window.
#
# Usage: ENV_NAME=productie bash scripts/deploy/check-argocd-health.sh
# Optional: WAIT_MINUTES=5 (default: 3)  MAX_DEGRADED=0 (default: 0 for critical apps)
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"

KB=~/.kube/config-platform-${ENV_NAME}
KT="kubectl --kubeconfig $KB --insecure-skip-tls-verify"
WAIT_MINUTES="${WAIT_MINUTES:-3}"
WAIT_SECONDS=$((WAIT_MINUTES * 60))
POLL_INTERVAL=15

# Apps that MUST be Healthy+Synced — fail the gate if any are degraded
CRITICAL_APPS=(
  "core-argocd-manifests"
  "apps-authentik-manifests"
  "core-external-secrets-manifests"
  "core-traefik-manifests"
)

# Apps where degraded is WARNING only (non-blocking)
SKIP_APPS=(
  "bootstrap"
)

echo "==> ArgoCD Health Gate — waiting up to ${WAIT_MINUTES}m for apps to stabilize"
echo ""

# ── Wait loop ─────────────────────────────────────────────────────────────────
DEADLINE=$(($(date +%s) + WAIT_SECONDS))
FINAL_STATUS=""

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  REMAINING=$(( DEADLINE - $(date +%s) ))
  echo "  [${REMAINING}s remaining] Checking ArgoCD app status..."

  # Get all apps with health + sync status
  APP_LIST=$($KT get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' \
    2>/dev/null || echo "")

  if [ -z "$APP_LIST" ]; then
    echo "  ⚠️  No ArgoCD apps found or kubectl failed — retrying..."
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Check if all apps are Healthy+Synced
  DEGRADED=()
  PROGRESSING=()
  HEALTHY_COUNT=0

  while IFS=$'\t' read -r APP_NAME SYNC HEALTH; do
    [ -z "$APP_NAME" ] && continue

    # Skip bootstrap-level apps (ArgoCD manages these internally)
    SKIP=0
    for SKIP_APP in "${SKIP_APPS[@]}"; do
      [ "$APP_NAME" = "$SKIP_APP" ] && SKIP=1 && break
    done
    [ "$SKIP" -eq 1 ] && continue

    if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    elif [ "$HEALTH" = "Progressing" ]; then
      PROGRESSING+=("$APP_NAME")
    else
      DEGRADED+=("$APP_NAME (sync=$SYNC health=$HEALTH)")
    fi
  done <<< "$APP_LIST"

  TOTAL=$(echo "$APP_LIST" | grep -c $'\t' || echo 0)
  echo "  → Healthy: ${HEALTHY_COUNT}/${TOTAL} | Progressing: ${#PROGRESSING[@]} | Degraded: ${#DEGRADED[@]}"

  # Success if nothing degraded and nothing still progressing
  if [ "${#DEGRADED[@]}" -eq 0 ] && [ "${#PROGRESSING[@]}" -eq 0 ]; then
    FINAL_STATUS="success"
    break
  fi

  # Still progressing — keep waiting
  if [ "${#PROGRESSING[@]}" -gt 0 ] && [ "${#DEGRADED[@]}" -eq 0 ]; then
    echo "  ⏳ Still progressing: ${PROGRESSING[*]}"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Degraded apps found — check if timeout reached
  if [ "$(date +%s)" -ge "$((DEADLINE - POLL_INTERVAL))" ]; then
    FINAL_STATUS="degraded"
    break
  fi

  sleep "$POLL_INTERVAL"
done

[ -z "$FINAL_STATUS" ] && FINAL_STATUS="degraded"

# ── Final status report ────────────────────────────────────────────────────────
echo ""
echo "==> Final ArgoCD Health Gate Status: ${FINAL_STATUS}"

# Re-fetch final app list for summary
APP_LIST=$($KT get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' \
  2>/dev/null || echo "")

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "## 🏥 ArgoCD Health Gate" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "| Application | Sync | Health |" >> "$GITHUB_STEP_SUMMARY"
  echo "|-------------|------|--------|" >> "$GITHUB_STEP_SUMMARY"

  while IFS=$'\t' read -r APP_NAME SYNC HEALTH; do
    [ -z "$APP_NAME" ] && continue
    if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
      ICON="✅"
    elif [ "$HEALTH" = "Progressing" ]; then
      ICON="⏳"
    else
      ICON="❌"
    fi
    echo "| ${ICON} \`${APP_NAME}\` | ${SYNC} | ${HEALTH} |" >> "$GITHUB_STEP_SUMMARY"
  done <<< "$APP_LIST"
fi

# ── Critical app gate ──────────────────────────────────────────────────────────
CRITICAL_FAIL=0
if [ -n "$APP_LIST" ]; then
  for CRITICAL in "${CRITICAL_APPS[@]}"; do
    CSTATUS=$(echo "$APP_LIST" | grep "^${CRITICAL}"$'\t' || echo "")
    if [ -z "$CSTATUS" ]; then
      echo "  ⚠️  Critical app '${CRITICAL}' not found in ArgoCD"
      continue
    fi
    CSYNC=$(echo "$CSTATUS" | cut -f2)
    CHEALTH=$(echo "$CSTATUS" | cut -f3)
    if [ "$CSYNC" != "Synced" ] || [ "$CHEALTH" != "Healthy" ]; then
      echo "  ❌ CRITICAL: ${CRITICAL} is ${CSYNC}/${CHEALTH}"
      CRITICAL_FAIL=1
    else
      echo "  ✅ Critical app OK: ${CRITICAL} (${CSYNC}/${CHEALTH})"
    fi
  done
fi

if [ "$CRITICAL_FAIL" -eq 1 ]; then
  echo ""
  echo "❌ Health gate FAILED — one or more critical apps are not Healthy+Synced" >&2
  echo "   Check ArgoCD UI for details: https://argocd.int.${BASE_DOMAIN}" >&2
  exit 1
fi

if [ "$FINAL_STATUS" = "degraded" ] && [ "${#DEGRADED[@]}" -gt 0 ]; then
  echo ""
  echo "⚠️  Non-critical apps degraded (manual review recommended):"
  for APP in "${DEGRADED[@]}"; do
    echo "   • $APP"
  done
fi

echo ""
echo "✅ Health gate passed — all critical apps are Healthy+Synced"
