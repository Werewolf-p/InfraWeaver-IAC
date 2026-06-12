#!/usr/bin/env bash
set -euo pipefail

WEBHOOK="${DISCORD_WEBHOOK_URL:-${DISCORD_WEBHOOK:-}}"
[ -z "$WEBHOOK" ] && exit 0
: "${DISCORD_TITLE:?DISCORD_TITLE is required}"

export DISCORD_WEBHOOK_URL="$WEBHOOK"
export DISCORD_DESCRIPTION="${DISCORD_DESCRIPTION:-}"
export DISCORD_COLOR="${DISCORD_COLOR:-3447003}"
export DISCORD_FIELDS_JSON="${DISCORD_FIELDS_JSON:-[]}"
export DISCORD_FOOTER="${DISCORD_FOOTER:-InfraWeaver deploy flow}"

python3 <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

webhook = os.environ["DISCORD_WEBHOOK_URL"]
try:
    fields = json.loads(os.environ.get("DISCORD_FIELDS_JSON", "[]"))
    if not isinstance(fields, list):
        fields = []
except Exception:
    fields = []

try:
    color = int(os.environ.get("DISCORD_COLOR", "3447003"))
except ValueError:
    color = 3447003

payload = {
    "embeds": [
        {
            "title": os.environ["DISCORD_TITLE"],
            "description": os.environ.get("DISCORD_DESCRIPTION", ""),
            "color": color,
            "fields": fields,
            "footer": {"text": os.environ.get("DISCORD_FOOTER", "InfraWeaver deploy flow")},
        }
    ]
}

data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(
    webhook,
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=15):
        pass
except urllib.error.HTTPError as exc:
    print(f"[notify-discord] warning: webhook returned HTTP {exc.code}", file=sys.stderr)
except Exception as exc:
    print(f"[notify-discord] warning: {exc}", file=sys.stderr)
PY
