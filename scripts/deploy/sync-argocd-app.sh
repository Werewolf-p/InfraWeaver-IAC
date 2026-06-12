#!/usr/bin/env bash
set -euo pipefail

: "${APP_NAME:?APP_NAME is required}"
# Default to ~/.kube/config; expand ~ for callers that pass KUBECONFIG=~/.kube/config
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
KUBECONFIG="${KUBECONFIG/#\~/${HOME}}"

APP_NAMESPACE="${APP_NAMESPACE:-argocd}"
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-300}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-}"
DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-}"

KT=(kubectl --kubeconfig "$KUBECONFIG" --insecure-skip-tls-verify)
DEADLINE=$(( $(date +%s) + SYNC_TIMEOUT_SECONDS ))

echo "==> Hard-refreshing ArgoCD app: ${APP_NAME}"
"${KT[@]}" annotate application "$APP_NAME" -n "$APP_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

echo "==> Triggering ArgoCD sync: ${APP_NAME}"
"${KT[@]}" patch application "$APP_NAME" -n "$APP_NAMESPACE" --type=merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncStrategy":{"hook":{"force":false}}}}}' >/dev/null

LAST_STATUS="Unknown"
LAST_HEALTH="Unknown"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  LAST_STATUS=$("${KT[@]}" get application "$APP_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  LAST_HEALTH=$("${KT[@]}" get application "$APP_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  echo "  → ${APP_NAME}: sync=${LAST_STATUS} health=${LAST_HEALTH}"
  if [ "$LAST_STATUS" = "Synced" ] && [ "$LAST_HEALTH" = "Healthy" ]; then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

if [ "$LAST_STATUS" != "Synced" ] || [ "$LAST_HEALTH" != "Healthy" ]; then
  echo "❌ ArgoCD app ${APP_NAME} did not become Synced/Healthy within ${SYNC_TIMEOUT_SECONDS}s" >&2
  exit 1
fi

echo "✅ ArgoCD app ${APP_NAME} is Synced/Healthy"

if [ -n "$DEPLOYMENT_NAME" ] && [ -n "$DEPLOYMENT_NAMESPACE" ]; then
  echo "==> Waiting for rollout: deployment/${DEPLOYMENT_NAME} (${DEPLOYMENT_NAMESPACE})"
  "${KT[@]}" rollout status "deployment/${DEPLOYMENT_NAME}" -n "$DEPLOYMENT_NAMESPACE" --timeout="${ROLLOUT_TIMEOUT_SECONDS}s"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ArgoCD Sync"
    echo "- App: \`${APP_NAME}\`"
    echo "- Final status: \`${LAST_STATUS}/${LAST_HEALTH}\`"
    if [ -n "$DEPLOYMENT_NAME" ] && [ -n "$DEPLOYMENT_NAMESPACE" ]; then
      echo "- Rollout: \`deployment/${DEPLOYMENT_NAME}\` in \`${DEPLOYMENT_NAMESPACE}\`"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
