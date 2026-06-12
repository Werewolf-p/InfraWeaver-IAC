#!/usr/bin/env bash
set -euo pipefail

: "${SMOKE_URL:?SMOKE_URL is required}"

SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-180}"
SMOKE_INTERVAL_SECONDS="${SMOKE_INTERVAL_SECONDS:-10}"
SMOKE_EXPECTED_STATUS="${SMOKE_EXPECTED_STATUS:-200}"
SMOKE_INSECURE="${SMOKE_INSECURE:-false}"

CURL_ARGS=(--silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 10)
if [ "$SMOKE_INSECURE" = "true" ]; then
  CURL_ARGS=(-k "${CURL_ARGS[@]}")
fi

DEADLINE=$(( $(date +%s) + SMOKE_TIMEOUT_SECONDS ))
LAST_STATUS="000"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  LAST_STATUS=$(curl "${CURL_ARGS[@]}" "$SMOKE_URL" 2>/dev/null || echo "000")
  echo "  → ${SMOKE_URL} returned HTTP ${LAST_STATUS}"
  if [ "$LAST_STATUS" = "$SMOKE_EXPECTED_STATUS" ]; then
    echo "✅ Smoke test passed for ${SMOKE_URL}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "### Smoke Test"
        echo "- URL: \`${SMOKE_URL}\`"
        echo "- Status: \`${LAST_STATUS}\`"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  sleep "$SMOKE_INTERVAL_SECONDS"
done

echo "❌ Smoke test failed for ${SMOKE_URL}; expected HTTP ${SMOKE_EXPECTED_STATUS}, got ${LAST_STATUS}" >&2
exit 1
