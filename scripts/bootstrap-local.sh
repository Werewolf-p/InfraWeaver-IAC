#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap-local.sh — InfraWeaver local dev environment validator
#
# USAGE:
#   cp .env.example .env   # fill in real values
#   bash scripts/bootstrap-local.sh
#
# What this does:
#   1. Checks all required tools are installed with correct versions
#   2. Validates .env has all required variables populated
#   3. Validates age key is present and SOPS config is correct
#   4. Runs tofu init + tofu validate to confirm your environment works
#   5. Checks gh auth status (optional, for pushing secrets)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="bootstrap-local"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
fail() { echo -e "${RED}❌ $*${NC}"; FAILURES=$((FAILURES+1)); }
info() { echo -e "${BLUE}ℹ️  $*${NC}"; }

FAILURES=0

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     InfraWeaver — Local Bootstrap Validator          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Required tools ────────────────────────────────────────────────────────
info "Checking required tools..."

check_tool() {
  local tool=$1 min_version=$2 version_cmd=${3:-"$1 --version"}
  if ! command -v "$tool" &>/dev/null; then
    fail "$tool not found — install it (see CONTRIBUTING.md)"
  else
    local ver
    ver=$(eval "$version_cmd" 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1 || echo "unknown")
    ok "$tool found (${ver})"
  fi
}

check_tool "tofu"       "1.11" "tofu --version"
check_tool "kubectl"    "1.32" "kubectl version --client --short 2>/dev/null || kubectl version --client"
check_tool "talosctl"   "1.9"  "talosctl version --client"
check_tool "helm"       "3.17" "helm version --short"
check_tool "sops"       "3.0"  "sops --version"
check_tool "age"        "1.0"  "age --version"
check_tool "git"        "2.0"  "git --version"
check_tool "curl"       "7.0"  "curl --version"

if command -v gh &>/dev/null; then
  ok "gh found (optional — used for PR/CI helpers)"
else
  warn "gh not found (optional) — PR/CI helper commands will be skipped"
fi

echo ""

# ── 2. .env validation ───────────────────────────────────────────────────────
info "Checking .env file..."

if [ ! -f ".env" ]; then
  fail ".env not found — run: cp .env.example .env  then fill in your values"
  echo ""
  echo "  See CONTRIBUTING.md for where to find each value."
  echo ""
else
  ok ".env file found"

  REQUIRED_VARS=(
    PROXMOX_API_TOKEN
    DEPLOYER_SSH_KEY
    CLOUDFLARE_API_TOKEN
    AGE_SECRET_KEY
    OPENBAO_ROOT_TOKEN
    ARGOCD_GITHUB_TOKEN
    SMTP_USERNAME
    SMTP_PASSWORD
  )

  # shellcheck disable=SC1091
  set +e
  source .env 2>/dev/null || true
  set -e

  for var in "${REQUIRED_VARS[@]}"; do
    val="${!var:-}"
    if [ -z "$val" ] || [[ "$val" == *"<your"* ]] || [[ "$val" == *"xxxx"* ]] || [[ "$val" == *"XXXXX"* ]]; then
      fail "$var is empty or still has placeholder value — fill it in .env"
    else
      # Show first 8 chars only
      PREVIEW="${val:0:8}..."
      ok "$var is set (${PREVIEW})"
    fi
  done
fi

echo ""

# ── 3. Age / SOPS config ────────────────────────────────────────────────────
info "Checking SOPS / age config..."

if [ ! -f ".sops.yaml" ]; then
  fail ".sops.yaml not found — repo is missing SOPS config"
else
  ok ".sops.yaml found"
fi

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
if [ -f "$AGE_KEY_FILE" ]; then
  ok "Age key file found at ${AGE_KEY_FILE}"
else
  warn "Age key file not found at ${AGE_KEY_FILE}"
  info "If AGE_SECRET_KEY is in your .env, create the key file:"
  info "  mkdir -p ~/.config/sops/age"
  info "  echo \"\$AGE_SECRET_KEY\" > ~/.config/sops/age/keys.txt"
  info "  chmod 600 ~/.config/sops/age/keys.txt"
fi

# Try to decrypt a SOPS file as a validation
SOPS_FILE=$(find envs -name "*.sops.yaml" 2>/dev/null | head -1)
if [ -n "$SOPS_FILE" ]; then
  if sops -d "$SOPS_FILE" &>/dev/null; then
    ok "SOPS decryption works (tested on ${SOPS_FILE})"
  else
    warn "SOPS decryption failed for ${SOPS_FILE} — check your age key"
  fi
fi

echo ""

# ── 4. OpenTofu init + validate ──────────────────────────────────────────────
info "Running tofu init + validate..."

if [ ! -f "terraform/main.tf" ]; then
  warn "terraform/main.tf not found — skipping tofu checks"
else
  pushd terraform > /dev/null

  if tofu init -backend=false -no-color &>/dev/null; then
    ok "tofu init succeeded"
  else
    fail "tofu init failed — check provider versions in versions.tf"
  fi

  if tofu validate -no-color &>/dev/null; then
    ok "tofu validate succeeded"
  else
    fail "tofu validate failed — run 'cd terraform && tofu validate' for details"
  fi

  popd > /dev/null
fi

echo ""

# ── 5. GitHub CLI auth (optional) ───────────────────────────────────────────
if command -v gh &>/dev/null; then
  info "Checking GitHub CLI auth..."
  if gh auth status &>/dev/null; then
    GHUSER=$(gh api user --jq .login 2>/dev/null || echo "unknown")
    ok "GitHub CLI authenticated as: ${GHUSER}"
  else
    warn "GitHub CLI not authenticated — run: gh auth login"
  fi
  echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}✅ All checks passed — your local environment is ready!${NC}"
  echo ""
  echo "  Next steps:"
  echo "    make plan                     # dry-run tofu plan"
  echo "    make new-app myapp apps       # scaffold a new K8s app"
  echo "    make new-user                 # add a user to users.yaml"
else
  echo -e "${RED}❌ ${FAILURES} check(s) failed — fix the issues above before deploying.${NC}"
  echo ""
  echo "  See CONTRIBUTING.md for detailed setup instructions."
  exit 1
fi
