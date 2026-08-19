#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ THIS VALIDATOR HAS NEVER RUN, AND IT CURRENTLY FAILS. Read before wiring it.
#
# Proposed for deletion 2026-08-19 as a "zero-caller validator". REFUSED: it was
# run, and it found four real disagreements in a file that is on the deploy path
# (scripts/deploy/set-user-passwords.sh:27, scripts/deploy/configure-authentik.sh:98)
# AND is named as the access register in docs/compliance/information-security-policy.md.
# Deleting it would have deleted the only thing that can see them.
#
# MEASURED 2026-08-19 — `bash scripts/validate-users-yaml.sh` exits 1 with:
#     User 'sindala':        missing required field 'access_level'
#     User 'koen1':          missing required field 'access_level'
#     User 'zonnevaarwater': missing required field 'access_level'
#     User 'Yona':           missing required field 'access_level'
#   4 of the 5 users in users.yaml omit it. All four DO carry `role_assignments`,
#   the newer RBAC shape, and configure-authentik.sh only reads access_level to
#   detect `admin` — so absence behaves as "not an admin", which may well be the
#   intended state.
#
# SO THE OPEN QUESTION IS NOT "is the data broken" BUT "is this contract stale":
# either `access_level` is still required (fix the four entries) or
# `role_assignments` superseded it (drop it from REQUIRED_FIELDS here). That is
# an access-control decision for the operator, not something to guess, which is
# why this file is neither deleted nor wired into pre-push/CI yet. Wiring it
# unresolved would block every push in the repo.
# ─────────────────────────────────────────────────────────────────────────────
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
