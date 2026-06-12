#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for the local developer stack" >&2
  exit 1
fi

COMPOSE_CMD=(docker compose)
if ! docker compose version >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
fi

MODE="${1:-detached}"
if [ "$MODE" = "foreground" ]; then
  "${COMPOSE_CMD[@]}" up --build console api mock
else
  "${COMPOSE_CMD[@]}" up --build -d console api mock
  bash scripts/health-check.sh
  cat <<'MSG'

InfraWeaver dev stack is up.
- Console: http://localhost:3000
- API:     http://localhost:3001/health
- Mock:    http://localhost:4010/health.json

Use `make logs` to tail output.
MSG
fi
