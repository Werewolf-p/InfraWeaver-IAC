#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Resolved 2026-08-19 by the operator: `access_level` is a STALE requirement.
#
# The open question was whether the four users without it were broken data or a
# superseded contract. It is the contract. `access_level` is read in exactly one
# way everywhere it appears — `== "admin"` (configure-authentik.sh:98,
# generate-admin-config.sh:40, send-deploy-email.py:153/194) — so its absence
# already means "not an admin", which is both the intended state for these users
# and the fail-safe direction. Authority now lives in `role_assignments`.
#
# It was also never one contract: this file called the valid set
# {admin, user, readonly}, users.example.yaml documents `admin | viewer`, and
# send-welcome-email.py:48 defaults to `platform-user`. Three vocabularies for
# one field is itself the evidence that it stopped being load-bearing.
#
# So: `email` is required, `access_level` is optional and still validated when
# present (a typo must not silently confer or drop admin). Absence is legal.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-users-yaml.sh — Validate users.yaml schema
#
# Required per user: email. Optional: access_level (validated when present).
# A WordPress site role must be backed by a matching role_assignment scope.
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

REQUIRED_FIELDS = ['email']
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

    # `wordpress_site_roles` only REMEMBERS the exact WordPress role; the grant
    # that authorises it is the role_assignment. An entry without one is inert
    # (the addon clamps it to the audited tier), so this is not a privilege hole
    # — it is drift, and it reads to a human as access that was never granted.
    scopes = {a.get('scope') for a in cfg.get('role_assignments') or [] if isinstance(a, dict)}
    for site in (cfg.get('wordpress_site_roles') or {}):
        if f'/wordpress/sites/{site}' not in scopes:
            print(f"  ❌ User '{username}': wordpress_site_roles['{site}'] has no matching "
                  f"role_assignment scope '/wordpress/sites/{site}'")
            errors += 1

if errors == 0:
    print(f"✅ users.yaml validation passed ({len(users)} user(s))")
    sys.exit(0)
else:
    print(f"\n❌ users.yaml validation failed: {errors} error(s)")
    sys.exit(1)
PYEOF
