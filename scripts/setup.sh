#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup.sh — first-run wizard for a fresh InfraWeaver fork.
#
# Prompts for the handful of values a forker must set, writes them into .env
# (seeded from .env.example), and optionally runs generate-from-env.sh to
# substitute the ${PLACEHOLDERS} throughout kubernetes/, envs/ and users.yaml.
#
# Re-runnable: existing .env values are shown as defaults and kept on empty input.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
EXAMPLE_FILE="$REPO_DIR/.env.example"

cyan() { printf '\033[36m%s\033[0m\n' "$1"; }
bold() { printf '\033[1m%s\033[0m\n' "$1"; }

[[ -f "$EXAMPLE_FILE" ]] || { echo "ERROR: .env.example missing"; exit 1; }
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  cyan "Created .env from .env.example"
fi

# current_value KEY → echoes existing value from .env (empty if unset)
current_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }

# set_kv KEY VALUE → upsert KEY=VALUE in .env (value left as-is, no quoting)
set_kv() {
  local key="$1" val="$2"
  if grep -q "^$key=" "$ENV_FILE"; then
    # Use a Python helper to avoid sed metacharacter issues in URLs/values.
    KEY="$key" VAL="$val" python3 - "$ENV_FILE" <<'PY'
import os, sys
p=sys.argv[1]; key=os.environ["KEY"]; val=os.environ["VAL"]
lines=open(p).read().splitlines()
out=[]
done=False
for ln in lines:
    if ln.startswith(key+"=") and not done:
        out.append(f"{key}={val}"); done=True
    else:
        out.append(ln)
open(p,"w").write("\n".join(out)+"\n")
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# ask PROMPT KEY → prompt with current value as default, store result
ask() {
  local prompt="$1" key="$2" cur ans
  cur="$(current_value "$key")"
  read -rp "$prompt [${cur:-unset}]: " ans || true
  ans="${ans:-$cur}"
  set_kv "$key" "$ans"
}

bold "InfraWeaver setup — press Enter to keep the shown default."
echo

cyan "1) Domain & identity"
ask "Base domain (apps served at *.<domain>)"            BASE_DOMAIN
ask "Admin email (also Let's Encrypt acct)"  ADMIN_EMAIL
ask "Admin username (Authentik login)"       ADMIN_USERNAME
ask "Cluster name"                            K8S_CLUSTER_NAME
echo

cyan "2) Git repos & image registry"
ask "Infra repo URL (ArgoCD source)"          INFRA_REPO_URL
ask "Platform/code repo URL"                  GIT_REPO_URL
ask "GitHub org/owner"                        GITHUB_ORG
ask "Image registry (e.g. ghcr.io/your-org)"  IMAGE_REGISTRY
# Derive GITHUB_REPO (org/repo slug) from GIT_REPO_URL when possible.
gru="$(current_value GIT_REPO_URL)"
slug="$(printf '%s' "$gru" | sed -E 's#^https?://[^/]+/##; s#\.git$##')"
[[ -n "$slug" && "$slug" == */* ]] && set_kv GITHUB_REPO "$slug"
echo

cyan "3) Secrets (OpenBao/ESO + DNS provider)"
ask "DNS provider (cloudflare|route53|azure|digitalocean|hetzner|none)" DNS_PROVIDER
echo "  → Put DNS/API tokens and other SECRETS directly in .env (kept gitignored),"
echo "    or seed them into OpenBao with scripts/seed-openbao-*.sh."
echo

bold "Saved to $ENV_FILE"
echo
read -rp "Run scripts/generate-from-env.sh now to substitute placeholders? [y/N]: " go || true
if [[ "${go:-}" =~ ^[Yy]$ ]]; then
  bash "$REPO_DIR/scripts/generate-from-env.sh"
else
  echo "Skipped. Run it later with: bash scripts/generate-from-env.sh"
fi

echo
bold "Next steps:"
cat <<'NEXT'
  1. Fill remaining secrets in .env (or OpenBao):  PROXMOX_API_TOKEN, GITHUB_PAT, DNS token, DEPLOYER_SSH_KEY
  2. Edit envs/<env>/cluster.yaml + terraform.tfvars with your node topology
  3. bash scripts/generate-from-env.sh        # if not already run
  4. Follow README "Fork & deploy" for the bootstrap sequence
NEXT
