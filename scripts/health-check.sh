#!/usr/bin/env bash
set -euo pipefail

check() {
  local name="$1"
  local url="$2"
  if curl -fsS --max-time 10 "$url" >/dev/null; then
    echo "✅ ${name}: ${url}"
  else
    echo "❌ ${name}: ${url}" >&2
    return 1
  fi
}

check "console" "http://localhost:3000/api/health"
check "api" "http://localhost:3001/health"
check "mock" "http://localhost:4010/health.json"
