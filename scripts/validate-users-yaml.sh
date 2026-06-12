#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-users-yaml.sh — Validate users.yaml schema
#
# Required fields per user: username, email, access_level
# Valid access_levels: admin, user, readonly
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="validate-users-yaml"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USERS_FILE="users.yaml"

if [[ ! -f "$USERS_FILE" ]]; then
  echo "ERROR: $USERS_FILE not found"
  exit 1
fi

echo "==> Validating $USERS_FILE..."

python3 << 'PYEOF'
import yaml, sys

REQUIRED_FIELDS = ['email', 'access_level']
VALID_ACCESS_LEVELS = {'admin', 'user', 'readonly', 'operator', 'platform-user'}

try:
    data = yaml.safe_load(open('users.yaml'))
except yaml.YAMLError as e:
    print(f"❌ YAML parse error: {e}")
    sys.exit(1)

if not isinstance(data, dict) or 'users' not in data:
    print("❌ users.yaml must have a top-level 'users' key")
    sys.exit(1)

users = data['users']
if not isinstance(users, dict):
    print("❌ users.yaml 'users' must be a mapping")
    sys.exit(1)

errors = 0
for username, cfg in users.items():
    if not isinstance(cfg, dict):
        print(f"  ❌ User '{username}': config must be a mapping, got {type(cfg).__name__}")
        errors += 1
        continue
    
    for field in REQUIRED_FIELDS:
        if field not in cfg:
            print(f"  ❌ User '{username}': missing required field '{field}'")
            errors += 1
    
    al = cfg.get('access_level', '')
    if al and al not in VALID_ACCESS_LEVELS:
        print(f"  ❌ User '{username}': invalid access_level '{al}' (must be one of: {', '.join(sorted(VALID_ACCESS_LEVELS))})")
        errors += 1
    
    email = cfg.get('email', '')
    if email and '@' not in email:
        print(f"  ❌ User '{username}': invalid email '{email}'")
        errors += 1

if errors == 0:
    print(f"✅ users.yaml validation passed ({len(users)} user(s))")
    sys.exit(0)
else:
    print(f"\n❌ users.yaml validation failed: {errors} error(s)")
    sys.exit(1)
PYEOF
