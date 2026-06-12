#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# new-user.sh — Helper to add a new user to the InfraWeaver platform
#
# USAGE:
#   bash scripts/new-user.sh <username> <full-name> <email> <access-level>
#
# EXAMPLES:
#   bash scripts/new-user.sh alice "Alice Smith" alice@example.com admin
#   bash scripts/new-user.sh bob "Bob Jones" bob@example.com platform-user
#
# ACCESS LEVELS:
#   admin         → all services (openbao, argocd, grafana, longhorn, homepage)
#   platform-user → homepage, argocd (read-only)
#
# IMPORTANT: This script generates the users.yaml entry and shows you the
# remaining 4 manual steps. It does NOT modify blueprint-users.yaml,
# externalsecret.yaml, values.yaml, or seed-openbao-authentik.sh automatically.
# Those files must be updated per the 5-file checklist in users.yaml header.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USERNAME=${1:-}
FULL_NAME=${2:-}
EMAIL=${3:-}
ACCESS_LEVEL=${4:-platform-user}

if [ -z "$USERNAME" ] || [ -z "$FULL_NAME" ] || [ -z "$EMAIL" ]; then
  echo "USAGE: bash scripts/new-user.sh <username> <full-name> <email> [access-level]"
  echo "  access-level: admin | platform-user (default: platform-user)"
  echo ""
  echo "EXAMPLES:"
  echo "  bash scripts/new-user.sh alice 'Alice Smith' alice@example.com admin"
  echo "  bash scripts/new-user.sh bob 'Bob Jones' bob@example.com platform-user"
  exit 1
fi

# Validate access level
case "$ACCESS_LEVEL" in
  admin|platform-user) ;;
  *) fail "Invalid access level '${ACCESS_LEVEL}'. Must be: admin | platform-user" ;;
esac

# Validate username (lowercase alphanumeric + hyphens only)
if ! [[ "$USERNAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  fail "Username must be lowercase alphanumeric (hyphens allowed): ${USERNAME}"
fi

# Check if user already exists in users.yaml
if grep -q "^  ${USERNAME}:" users.yaml 2>/dev/null; then
  fail "User '${USERNAME}' already exists in users.yaml"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   InfraWeaver — New User Setup Helper                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Username     : ${USERNAME}"
info "Full name    : ${FULL_NAME}"
info "Email        : ${EMAIL}"
info "Access level : ${ACCESS_LEVEL}"
echo ""

# ── Generate users.yaml snippet ──────────────────────────────────────────────
if [ "$ACCESS_LEVEL" = "admin" ]; then
  GROUPS=$(cat << GEOF
      - platform-admins
      - authentik Admins       # Authentik superuser (admin UI access)
      - platform-users
GEOF
)
  ARGOCD_ROLE="admin"
  OPENBAO_POLICY="default"
  NOTES="Platform admin — full access to everything"
else
  GROUPS=$(cat << GEOF
      - platform-users
GEOF
)
  ARGOCD_ROLE="readonly"
  OPENBAO_POLICY="null"
  NOTES="Platform user — homepage, VPN, ArgoCD (read-only)"
fi

# Generate the users.yaml block
YAML_BLOCK=$(cat << YEOF

  ${USERNAME}:
    name: "${FULL_NAME}"
    email: "${EMAIL}"
    access_level: ${ACCESS_LEVEL}
    authentik_groups:
${GROUPS}
    argocd_role: ${ARGOCD_ROLE}
    openbao_policy: ${OPENBAO_POLICY}
    send_recovery_email: true
    notes: "${NOTES}"
YEOF
)

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}STEP 1: Add to users.yaml${NC}"
echo ""
echo "  Append the following block to the 'users:' section in users.yaml:"
echo ""
echo "$YAML_BLOCK"
echo ""

# ── Show remaining 4 steps ───────────────────────────────────────────────────
SECRET_VAR_UPPER=$(echo "${USERNAME}" | tr '[:lower:]-' '[:upper:]_')
SECRET_VAR="AUTHENTIK_${SECRET_VAR_UPPER}_PASSWORD"

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}STEP 2: blueprint-users.yaml${NC}"
echo "  File: kubernetes/platform/authentik/manifests/blueprint-users.yaml"
echo "  Add an entry in the 'entries:' list:"
echo ""
cat << BPEOF
    - model: authentik_core.user
      state: present
      id: user-${USERNAME}
      identifiers:
        username: ${USERNAME}
      attrs:
        name: "${FULL_NAME}"
        email: "${EMAIL}"
        is_active: true
        password: !Env ${SECRET_VAR}
BPEOF
echo ""

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}STEP 3: externalsecret.yaml${NC}"
echo "  File: kubernetes/platform/authentik/manifests/externalsecret.yaml"
echo "  Add in the 'data:' list:"
echo ""
cat << ESEOF
    - secretKey: ${USERNAME}-password
      remoteRef:
        key: secret/platform/authentik
        property: ${USERNAME}-password
ESEOF
echo ""

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}STEP 4: authentik/values.yaml${NC}"
echo "  File: kubernetes/platform/authentik/values.yaml"
echo "  Add in the 'env:' section (with optional: true):"
echo ""
cat << VALEOF
      - name: ${SECRET_VAR}
        valueFrom:
          secretKeyRef:
            name: authentik-secrets
            key: ${USERNAME}-password
            optional: true
VALEOF
echo ""

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${BLUE}STEP 5: seed-openbao-authentik.sh${NC}"
echo "  File: scripts/deploy/seed-openbao-authentik.sh"
echo "  In the INITIAL create block AND the patch-if-missing block, add:"
echo ""
cat << SEEDEOF
  # ${FULL_NAME}
  "${USERNAME}-password": "\$(openssl rand -base64 32 | tr -d '=+/')"
SEEDEOF
echo ""

echo "══════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}After editing all 5 files:${NC}"
echo "  git add users.yaml kubernetes/platform/authentik/ scripts/deploy/seed-openbao-authentik.sh"
echo "  git commit -m 'feat: add user ${USERNAME}'"
echo "  git push"
echo ""
echo -e "${BLUE}The apply-changes.yml workflow will then:${NC}"
echo "  1. Seed the user's password in OpenBao"
echo "  2. Sync Authentik groups and blueprints"
echo "  3. Send a welcome email to ${EMAIL}"
echo ""
warn "Remember: only NEWLY ADDED users receive a welcome email (not existing users)."
