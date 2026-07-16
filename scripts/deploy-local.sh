#!/usr/bin/env bash
# =============================================================================
# deploy-local.sh — InfraWeaver Full Local Deployment
#
# USAGE:
#   # Option 1: via web UI (recommended for first-timers)
#   python3 scripts/init/server.py   # open http://localhost:8080
#
#   # Option 2: direct terminal
#   cp .env.example .env && nano .env
#   bash scripts/deploy-local.sh
#
#   # Option 3: with explicit env file
#   ENV_FILE=/path/to/.env bash scripts/deploy-local.sh
#
# WHAT THIS DOES (full local deployment pipeline):
#   1.  Install required tools (tofu, talosctl, kubectl, helm, sops, age)
#   2.  Set up SSH key from DEPLOYER_SSH_KEY env var
#   3.  Provision Talos cluster VMs on Proxmox via OpenTofu
#   4.  Bootstrap the Talos cluster + save kubeconfig/talosconfig
#   5.  Fix CoreDNS startup race condition
#   6.  Deploy ArgoCD + bootstrap ApplicationSet
#   7.  Bootstrap local-path-provisioner storage
#   8.  Bootstrap OpenBao + ExternalSecrets
#   9.  Ensure DNS records (Cloudflare only)
#   10. Apply MetalLB IP pool + Traefik middleware
#   11. Configure TLS certificate issuers
#   13. Fix ingress-nginx admission webhook
#   14. Patch cluster CoreDNS for internal zones
#   15. Configure Authentik (admin privileges + user passwords)
#   16. Configure OIDC for ArgoCD and OpenBao
#   17. Run post-deploy tests
#   18. Send deployment summary email
#
# PREREQUISITES:
#   - .env file with required values (see .env.example)
#   - SSH access to Proxmox host (DEPLOYER_SSH_KEY in .env)
#   - This script can be run from the InfraWeaver repo root
#
# SECRETS:
#   All secrets read from .env — no SOPS/age key required for local deploy.
#   The .env is NOT committed to git (see .gitignore).
# =============================================================================
set -euo pipefail

SCRIPT_NAME="deploy-local"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# shellcheck source=scripts/lib.sh
source "scripts/lib.sh"

RUNNER_OVERRIDE=""
cleanup() {
  [[ -n "${RUNNER_OVERRIDE:-}" ]] && rm -f "$RUNNER_OVERRIDE"
}
trap cleanup EXIT

# ── Load .env ────────────────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  log "Loading environment from $ENV_FILE"
  # Use Python to emit bash $'...' exports — handles multi-line values (SSH keys etc.)
  # shellcheck disable=SC1090,SC2046
  eval "$(python3 - "$ENV_FILE" << 'PYEOF'
import sys, re

def bash_ansi_quote(s):
    """Encode any string as bash $'...' literal so eval handles newlines/special chars."""
    out = []
    for c in s:
        if   c == '\n': out.append('\\n')
        elif c == '\r': out.append('\\r')
        elif c == '\t': out.append('\\t')
        elif c == '\\': out.append('\\\\')
        elif c == "'":  out.append("\\'")
        else:           out.append(c)
    return "$'" + ''.join(out) + "'"

def decode_dq_escapes(s):
    """Decode standard escape sequences inside double-quoted .env values.
    Handles \\n → newline, \\t → tab, \\r → CR, \\\\ → backslash, \\" → quote.
    This mirrors the behaviour of bash's $'...' ANSI-C strings and dotenv spec."""
    return (s
        .replace('\\n', '\n')
        .replace('\\t', '\t')
        .replace('\\r', '\r')
        .replace('\\"', '"')
        .replace('\\\\', '\\'))

path = sys.argv[1]
content = open(path).read()
# Match KEY="..." including multi-line quoted values, and KEY=unquoted
for m in re.finditer(
    r'^([A-Za-z_][A-Za-z0-9_]*)=((?:"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|[^\n]*))',
    content, re.MULTILINE
):
    k, v = m.group(1), m.group(2).strip()
    is_dq = v.startswith('"') and v.endswith('"')
    is_sq = v.startswith("'") and v.endswith("'")
    if is_dq or is_sq:
        v = v[1:-1]
    if is_dq:
        v = decode_dq_escapes(v)
    print(f'export {k}={bash_ansi_quote(v)}')
PYEOF
  )"
  ok "Loaded $ENV_FILE"
else
  warn ".env not found at $ENV_FILE"
  warn "Run: cp .env.example .env && nano .env"
  die "Aborting — no .env file"
fi

# ── Validate required vars ────────────────────────────────────────────────────
DNS_PROVIDER="${DNS_PROVIDER:-cloudflare}"
# GITHUB_REPO, GIT_REPO_URL, SMTP_USERNAME, SMTP_PASSWORD are optional integrations
REQUIRED_VARS=(ADMIN_EMAIL PROXMOX_API_TOKEN DEPLOYER_SSH_KEY DNS_PROVIDER)
MISSING=()
is_missing_value() {
  local val="$1"
  [[ -z "$val" || "$val" == *"<your"* || "$val" == *"xxxx"* || "$val" == *"yourdomain.com"* || "$val" == *"your-org/your-repo"* ]]
}
for v in "${REQUIRED_VARS[@]}"; do
  val="${!v:-}"
  if is_missing_value "$val"; then
    MISSING+=("$v")
  fi
done
case "$DNS_PROVIDER" in
  cloudflare)
    PROVIDER_REQUIRED=(CLOUDFLARE_API_TOKEN)
    ;;
  route53)
    PROVIDER_REQUIRED=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
    ;;
  azure)
    PROVIDER_REQUIRED=(AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID AZURE_RESOURCE_GROUP)
    ;;
  digitalocean)
    PROVIDER_REQUIRED=(DIGITALOCEAN_TOKEN)
    ;;
  hetzner)
    PROVIDER_REQUIRED=(HETZNER_DNS_API_KEY)
    ;;
  none)
    PROVIDER_REQUIRED=()
    ;;
  *)
    die "Invalid DNS_PROVIDER '$DNS_PROVIDER' (expected: cloudflare|route53|azure|digitalocean|hetzner|none)"
    ;;
esac
for v in "${PROVIDER_REQUIRED[@]}"; do
  val="${!v:-}"
  if is_missing_value "$val"; then
    MISSING+=("$v")
  fi
done
if [[ "${ENABLE_EXTERNAL_DNS:-false}" == "true" && "$DNS_PROVIDER" != "cloudflare" ]]; then
  die "ENABLE_EXTERNAL_DNS=true requires DNS_PROVIDER=cloudflare"
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "Missing required .env values: ${MISSING[*]}
Edit $ENV_FILE and fill in all required fields."
fi

ENV_NAME="${ENV_NAME:-productie}"
LETSENCRYPT_ENV="${LETSENCRYPT_ENV:-production}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
if [[ -z "${BASE_DOMAIN:-}" ]]; then
  err "BASE_DOMAIN not set — ensure .env is configured (run the init website)"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     InfraWeaver — Local Platform Deployment                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log "Environment   : $ENV_NAME"
log "Domain        : $BASE_DOMAIN"
log "LE env        : $LETSENCRYPT_ENV"
log "Repo          : $REPO_DIR"
echo ""

# ── Step 1: Install tools ─────────────────────────────────────────────────────
log "Step 1: Installing required tools..."
ENV_NAME="$ENV_NAME" bash scripts/deploy/install-tools.sh
ok "Tools installed"

# ── Step 2: Set up SSH key ────────────────────────────────────────────────────
log "Step 2: Setting up SSH key..."
mkdir -p ~/.ssh
# DEPLOYER_SSH_KEY may be a file path or the actual key content
if [[ -f "$DEPLOYER_SSH_KEY" ]]; then
  # If same file, skip copy (file path == ~/.ssh/deployer_ed25519)
  if [[ "$(realpath "$DEPLOYER_SSH_KEY" 2>/dev/null)" != "$(realpath ~/.ssh/deployer_ed25519 2>/dev/null)" ]]; then
    cp "$DEPLOYER_SSH_KEY" ~/.ssh/deployer_ed25519
  fi
elif [[ "$DEPLOYER_SSH_KEY" == *"BEGIN"* ]]; then
  printf '%s\n' "$DEPLOYER_SSH_KEY" > ~/.ssh/deployer_ed25519
else
  die "DEPLOYER_SSH_KEY must be a file path or PEM-encoded private key"
fi
chmod 600 ~/.ssh/deployer_ed25519
ok "SSH key configured at ~/.ssh/deployer_ed25519"

# Generate public key from private key (needed for authorized_keys)
ssh-keygen -y -f ~/.ssh/deployer_ed25519 > ~/.ssh/deployer_ed25519.pub 2>/dev/null || true
DEPLOYER_PUBKEY=$(cat ~/.ssh/deployer_ed25519.pub 2>/dev/null || true)

# ── Collect all unique Proxmox node SSH IPs ───────────────────────────────────
# PVE_NODES format: "proxmox:10.1.0.3,microserver:10.1.0.3"
# The bpg/proxmox provider resolves ACTUAL node IPs from the Proxmox cluster API
# and uses them for SSH (e.g. microserver may be at 10.1.0.4 even if PVE_NODES
# lists 10.1.0.3).  Query the real IPs here so we can install the SSH key on all.
PVE_API_HOST="${PROXMOX_HOST:-}"
PROXMOX_TOKEN_VALUE="${PROXMOX_API_TOKEN:-}"

declare -A SEEN_IPS
ALL_NODE_IPS=()

# Always include the API host
if [[ -n "$PVE_API_HOST" ]]; then
  SEEN_IPS["$PVE_API_HOST"]=1
  ALL_NODE_IPS+=("$PVE_API_HOST")
fi

# Only add cluster API IPs if PVE_NODES is NOT explicitly set.
# When PVE_NODES is set, use only those IPs to avoid SSH failures for offline nodes.
if [[ -z "${PVE_NODES:-}" && -n "$PVE_API_HOST" && -n "$PROXMOX_TOKEN_VALUE" ]]; then
  CLUSTER_IPS=$(python3 - <<PYEOF 2>/dev/null
import urllib.request, urllib.parse, ssl, json, sys
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
url = "https://${PVE_API_HOST}:8006/api2/json/cluster/status"
req = urllib.request.Request(url, headers={"Authorization": "PVEAPIToken=${PROXMOX_TOKEN_VALUE}"})
try:
    data = json.loads(urllib.request.urlopen(req, context=ctx, timeout=8).read())
    for n in (data.get("data") or []):
        if n.get("type") == "node" and n.get("ip"):
            print(n["ip"])
except Exception as e:
    pass
PYEOF
  )
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    if [[ -z "${SEEN_IPS[$ip]+x}" ]]; then
      SEEN_IPS["$ip"]=1
      ALL_NODE_IPS+=("$ip")
    fi
  done <<< "$CLUSTER_IPS"
fi

# Fall back to IPs listed in PVE_NODES
if [[ -n "${PVE_NODES:-}" ]]; then
  IFS=',' read -ra _pve_entries <<< "$PVE_NODES"
  for _entry in "${_pve_entries[@]}"; do
    _ip="${_entry#*:}"
    [[ -z "$_ip" || -n "${SEEN_IPS[$_ip]+x}" ]] && continue
    SEEN_IPS["$_ip"]=1
    ALL_NODE_IPS+=("$_ip")
  done
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/deployer_ed25519"
SSH_FAILURES=()

for NODE_IP in "${ALL_NODE_IPS[@]}"; do
  LOCAL_IPS=$(hostname -I 2>/dev/null || true)
  if echo "$LOCAL_IPS" | grep -qw "$NODE_IP"; then
    # Running ON this Proxmox node — add key directly
    if [[ -n "$DEPLOYER_PUBKEY" ]]; then
      grep -v "infraweaver-deployer" ~/.ssh/authorized_keys > /tmp/_iw_ak 2>/dev/null && \
        mv /tmp/_iw_ak ~/.ssh/authorized_keys 2>/dev/null || true
      echo "$DEPLOYER_PUBKEY" >> ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
      ok "Deployer key added to local authorized_keys on $NODE_IP"
    fi
  fi

  if ssh $SSH_OPTS root@"$NODE_IP" echo "ssh-ok" &>/dev/null; then
    ok "SSH to Proxmox node $NODE_IP verified ✓"
  else
    warn "SSH to Proxmox node $NODE_IP failed — the bpg/proxmox provider needs SSH for VM disk import."
    warn "  Fix: run 'Setup Proxmox User' in the wizard to auto-install the deployer key,"
    warn "  or manually: ssh root@$NODE_IP \"echo '$DEPLOYER_PUBKEY' >> ~/.ssh/authorized_keys\""
    SSH_FAILURES+=("$NODE_IP")
  fi
done

if [[ ${#SSH_FAILURES[@]} -gt 0 ]]; then
  warn "SSH verification failed for: ${SSH_FAILURES[*]}"
  warn "Deployment will likely fail at VM disk creation. Fix SSH access first."
fi

# ── Step 3: Set TF variables from .env ───────────────────────────────────────
log "Step 3: Preparing Terraform variables..."
export TF_VAR_proxmox_api_token="$PROXMOX_API_TOKEN"
# bpg/proxmox provider also reads these native env vars directly.
# Setting them here ensures the provider always has credentials even if the
# TF_VAR path is skipped, and avoids "No ticket" errors in sub-scripts.
export PROXMOX_VE_ENDPOINT="https://${PROXMOX_HOST}:8006/"
export PROXMOX_VE_API_TOKEN="$PROXMOX_API_TOKEN"
export PROXMOX_VE_INSECURE="true"
if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
  export TF_VAR_cloudflare_api_token="${CLOUDFLARE_API_TOKEN:-}"
else
  unset TF_VAR_cloudflare_api_token 2>/dev/null || true
fi
unset TF_VAR_github_runner_token 2>/dev/null || true
GITHUB_INTEGRATION_ENABLED=false
if [[ -n "${GITHUB_PAT:-}" && -n "${RUNNER_REGISTRATION_TOKEN:-}" && "${RUNNER_REGISTRATION_TOKEN:-}" != placeholder* ]]; then
  export TF_VAR_github_runner_token="$RUNNER_REGISTRATION_TOKEN"
  GITHUB_INTEGRATION_ENABLED=true
fi
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# Pre-flight: warn if disk is too full before downloading providers + deploying.
# OpenTofu providers + deployment workspace need ≥ 4 GB free.
_FREE_KB=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
_FREE_GB=$(( ${_FREE_KB:-0} / 1024 / 1024 ))
if (( _FREE_GB < 4 )); then
  warn "Low disk space: only ${_FREE_GB} GB free in \$HOME (${HOME})."
  warn "OpenTofu provider cache + deployment artifacts need ≥ 4 GB."
  warn "Consider: 'tofu providers mirror /tmp/providers && export TF_PLUGIN_CACHE_DIR=/tmp/providers'"
  warn "Or resize this VM's disk in Proxmox (recommended: 60 GB)."
  # Attempt to clean stale /tmp provider downloads before aborting
  rm -f /tmp/terraform-provider* /tmp/tofu-provider* 2>/dev/null || true
  _FREE_KB=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  _FREE_GB=$(( ${_FREE_KB:-0} / 1024 / 1024 ))
  if (( _FREE_GB < 2 )); then
    die "Not enough disk space (${_FREE_GB} GB free). Resize the init VM disk and retry."
  fi
fi

STATE_DIR=~/.tofu/state/platform-"$ENV_NAME"
mkdir -p "$STATE_DIR"
ok "TF_VARs set"

# ── Step 3a: Substitute .env placeholders into tfvars/yaml templates ─────────
log "Step 3a: Substituting .env placeholders into config templates..."
echo "STAGE:generate"
bash "${REPO_DIR}/scripts/generate-from-env.sh"
python3 "${REPO_DIR}/scripts/generate-forward-auth-blueprint.py" || warn "forward-auth blueprint generation had issues (continuing)"
ok "Step 3a: Templates substituted"

# ── Step 4: Deploy Platform (Terraform) ──────────────────────────────────────
if [[ "${SKIP_TERRAFORM:-false}" == "true" ]]; then
  log "Step 4: SKIPPED (SKIP_TERRAFORM=true — cluster already running)"
  KB_FILE=~/.kube/config-platform-"$ENV_NAME"
  mkdir -p ~/.kube "envs/$ENV_NAME/generated"
  # Ensure kubeconfig is available
  if [ ! -f "$KB_FILE" ] && [ -f "envs/$ENV_NAME/generated/kubeconfig" ]; then
    cp "envs/$ENV_NAME/generated/kubeconfig" "$KB_FILE"
  fi
else
log "Step 4: Deploying platform via OpenTofu (this takes 10–15 minutes)..."
echo "STAGE:opentofu"

KB_FILE=~/.kube/config-platform-"$ENV_NAME"
mkdir -p ~/.kube "envs/$ENV_NAME/generated"

cd terraform

tofu init \
  -backend-config="path=$STATE_DIR/terraform.tfstate" \
  -reconfigure 2>&1

VARS=""
[[ -f "../envs/$ENV_NAME/terraform.tfvars" ]]       && VARS="$VARS -var-file=../envs/$ENV_NAME/terraform.tfvars"
[[ -f "../envs/$ENV_NAME/services.auto.tfvars" ]]   && VARS="$VARS -var-file=../envs/$ENV_NAME/services.auto.tfvars"

# Migrate: remove old SSH-based null_resources from state if present
for old_resource in \
  'module.talos_cluster.null_resource.download_talos_image' \
  'module.talos_cluster.null_resource.import_talos_disk'; do
  if tofu state list 2>/dev/null | grep -qF "$old_resource"; then
    log "Migrating: removing stale SSH-based resource from state: $old_resource"
    tofu state rm "$old_resource" 2>/dev/null || true
  fi
done

# Pre-Stage 1: delete any stale Talos images from PVE nodes when starting fresh.
# This ensures proxmox_download_file (overwrite=false) can download cleanly on a
# first run or after a tofu destroy.  Skipped when state already has the resource.
if ! tofu state list 2>/dev/null | grep -q "proxmox_download_file"; then
  log "Fresh deployment — removing any stale Talos images from PVE nodes..."
  _IFS_SAVE="$IFS"; IFS=','
  for node_spec in $PVE_NODES; do
    NODE_NAME="${node_spec%%:*}"
    NODE_IP="${node_spec##*:}"
    log "  Cleaning images from $NODE_NAME ($NODE_IP)..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i ~/.ssh/deployer_ed25519 root@"$NODE_IP" \
        'rm -f /var/lib/vz/template/iso/talos-*.img && echo "  cleaned"' 2>/dev/null \
      || warn "  Could not clean images from $NODE_NAME (non-fatal)"
  done
  IFS="$_IFS_SAVE"
fi

# Stage 1: provision Talos cluster VMs
log "==> Stage 1: provisioning Talos cluster VMs on Proxmox..."
# shellcheck disable=SC2086
tofu apply $VARS -target=module.talos_cluster -target=local_sensitive_file.kubeconfig -target=local_sensitive_file.talosconfig -auto-approve 2>&1
ok "Stage 1: Talos VMs provisioned"

# Save configs
tofu output -raw kubeconfig > "$KB_FILE" 2>/dev/null || true
mkdir -p "$REPO_DIR/generated"
cp "$KB_FILE" "$REPO_DIR/generated/kubeconfig" 2>/dev/null || true
chmod 600 "$KB_FILE" 2>/dev/null || true
tofu output -raw talosconfig > "../envs/$ENV_NAME/generated/talosconfig" 2>/dev/null || true
# Save talosconfig to GitHub Secrets so CI can apply machineconfig changes
if [[ -n "${GITHUB_PAT:-}" ]] && [[ -n "${GITHUB_REPO:-}" ]] && \
   [[ -f "../envs/$ENV_NAME/generated/talosconfig" ]]; then
  log "Saving TALOSCONFIG to GitHub Secrets (TALOSCONFIG_PRODUCTIE)..."
  GH_TOKEN="$GITHUB_PAT" gh secret set "TALOSCONFIG_PRODUCTIE" \
    --body "$(cat ../envs/$ENV_NAME/generated/talosconfig)" \
    --repo "$GITHUB_REPO" 2>/dev/null \
    && log "  ✅ TALOSCONFIG_PRODUCTIE saved to GitHub Secrets" \
    || warn "  Failed to save talosconfig to GitHub Secrets (GITHUB_PAT may be expired — update manually)"
elif [[ -f "../envs/$ENV_NAME/generated/talosconfig" ]]; then
  # GITHUB_PAT is empty — the apply-machineconfig workflow uses the LOCAL file on the
  # management-host runner directly, so this is non-fatal. The workflow reads from:
  #   $HOME/InfraWeaver-platform/envs/<env>/generated/talosconfig
  # which is this file. No GitHub Secret is required as long as the workflow runs on
  # the management-host runner. The secret is only needed as a fallback.
  log "  ℹ GITHUB_PAT not set — talosconfig saved locally only (workflow will use local path)"
  log "  To also save to GitHub Secrets (fallback), set GITHUB_PAT in .env"
fi
chmod 600 "../envs/$ENV_NAME/generated/talosconfig" 2>/dev/null || true

# Wait for Kubernetes API before Stage 2a — Talos bootstrap can take 5-8 min.
log "==> Waiting for Kubernetes API to become ready (up to 10 min)..."
_k8s_ready=0
for _i in $(seq 1 60); do
  if kubectl --kubeconfig "$KB_FILE" get nodes --request-timeout=5s >/dev/null 2>&1; then
    log "✅ Kubernetes API is ready"
    _k8s_ready=1
    break
  fi
  log "  Kubernetes API not ready yet ($_i/60), waiting 10s..."
  sleep 10
done
if [ "$_k8s_ready" -eq 0 ]; then
  warn "Kubernetes API did not become ready in 10 min — Stage 2a may fail"
fi

# Stage 2a: install ArgoCD namespace + Helm (gets CRDs registered)
log "==> Stage 2a: installing ArgoCD namespace + Helm chart..."
# shellcheck disable=SC2086
for _stage2a_attempt in 1 2 3; do
_stage2a_exit=0
tofu apply $VARS \
  -target='module.platform_bootstrap[0].kubernetes_namespace.argocd' \
  -target='module.platform_bootstrap[0].helm_release.argocd' \
  -auto-approve 2>&1 || _stage2a_exit=$?
  if [[ "$_stage2a_exit" -eq 0 ]]; then break; fi
  warn "Stage 2a attempt ${_stage2a_attempt}/3 failed (transient error) — retrying in 20s..."
  sleep 20
done
if [[ "$_stage2a_exit" -ne 0 ]]; then
  # Helm provider sometimes crashes ("Plugin did not respond") even when install succeeded
  # Check if ArgoCD pods are actually running
  _argocd_pods=$(kubectl --kubeconfig "$KB_FILE" get pods -n argocd --no-headers 2>/dev/null | grep "Running" 2>/dev/null | wc -l || echo "0")
  _argocd_pods=${_argocd_pods//[^0-9]/}
  _argocd_pods=${_argocd_pods:-0}
  if [[ "$_argocd_pods" -ge 5 ]]; then
    warn "==> Helm provider crashed but ArgoCD has ${_argocd_pods} running pods — importing TF state..."
    tofu import $VARS "module.platform_bootstrap[0].kubernetes_namespace.argocd" "argocd" 2>&1 | grep -E "Import|Error|warn" || true
    tofu import $VARS "module.platform_bootstrap[0].helm_release.argocd" "argocd/argocd" 2>&1 | grep -E "Import|Error|warn" || true
    warn "==> TF state imported — continuing"
  else
    die "Stage 2a failed: ArgoCD install failed (only ${_argocd_pods} pods running)"
  fi
fi
ok "Stage 2a: ArgoCD Helm installed"

# Wait for ArgoCD CRDs
log "==> Waiting for ArgoCD CRDs to register..."
for crd in appprojects.argoproj.io applications.argoproj.io applicationsets.argoproj.io; do
  for i in $(seq 1 36); do
    kubectl --kubeconfig "$KB_FILE" wait --for=condition=Established "crd/$crd" --timeout=5s 2>/dev/null \
      && log "  ✅ $crd ready" && break
    log "  waiting for $crd ($i/36)..."
    sleep 5
  done
done

# Stage 2b: full platform bootstrap
# Build homelab-ansible Docker image only when optional GitHub integration is enabled
SKIP_RUNNERS=true
if [[ "$GITHUB_INTEGRATION_ENABLED" != "true" ]]; then
  log "==> GitHub integration not configured — skipping optional GitHub runner provisioning"
else
  SKIP_RUNNERS=false
  log "==> GitHub integration detected — building homelab-ansible image for optional runner provisioning..."
  if docker images -q homelab-ansible:latest 2>/dev/null | grep -q .; then
    ok "homelab-ansible:latest already present"
  elif docker build -t homelab-ansible:latest "$REPO_DIR/ansible" 2>&1; then
    ok "homelab-ansible image built"
  else
    log "⚠️  homelab-ansible image build failed — skipping optional GitHub runner provisioning"
    SKIP_RUNNERS=true
  fi
fi

STAGE2B_VARS="$VARS"
if [[ "$SKIP_RUNNERS" == "true" ]]; then
  RUNNER_OVERRIDE="../envs/$ENV_NAME/generated/github-runners.disabled.auto.tfvars"
  printf 'github_runners = {}\n' > "$RUNNER_OVERRIDE"
  STAGE2B_VARS="$VARS -var-file=$RUNNER_OVERRIDE"
fi

log "==> Stage 2b: full platform bootstrap..."
# shellcheck disable=SC2086
tofu apply $STAGE2B_VARS -auto-approve 2>&1
ok "Stage 2b: Platform bootstrap complete"

cd "$REPO_DIR"
ok "Step 4: Platform deployed"
fi # end SKIP_TERRAFORM

# ── Step 5: Fix CoreDNS startup race ──────────────────────────────────────────
log "Step 5: Fixing CoreDNS startup race condition..."
log "==> Waiting for Flannel DaemonSet..."
for i in $(seq 1 30); do
  DESIRED=$(kubectl --kubeconfig "$KB_FILE" get ds kube-flannel -n kube-system \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  READY=$(kubectl --kubeconfig "$KB_FILE" get ds kube-flannel -n kube-system \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  if [[ "$DESIRED" -gt 0 && "$READY" -eq "$DESIRED" ]]; then
    log "  Flannel ready: $READY/$DESIRED"
    break
  fi
  log "  Flannel $READY/$DESIRED ($i/30)..."
  sleep 10
done
sleep 10

# ── Step 5a: Fix Flannel public-ip (Talos VIP conflict) ──────────────────────
# Talos adds a shared VIP (e.g. 10.0.0.200) to eth0 on ALL control-plane nodes.
# Flannel auto-detects this VIP as the node's public-ip, breaking VXLAN tunnels
# because all nodes advertise the same IP. Fix: inject --public-ip=$(NODE_IP)
# using the downward API status.hostIP so each node uses its real IP.
log "Step 5a: Fixing Flannel public-ip (Talos VIP conflict)..."
FLANNEL_HAS_FIX=$(kubectl --kubeconfig "$KB_FILE" get ds kube-flannel -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")
if [[ "$FLANNEL_HAS_FIX" != *'--public-ip=$(NODE_IP)'* ]]; then
  log "  Patching kube-flannel DaemonSet with --public-ip=\$(NODE_IP)..."
  kubectl --kubeconfig "$KB_FILE" patch daemonset kube-flannel -n kube-system --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--ip-masq","--kube-subnet-mgr","--public-ip=$(NODE_IP)"]},
    {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NODE_IP","valueFrom":{"fieldRef":{"fieldPath":"status.hostIP"}}}}
  ]' 2>/dev/null && log "  ✅ Flannel patched" || warn "  Flannel patch failed (may already be correct)"
  # Wait for flannel pods to restart
  sleep 10
  kubectl --kubeconfig "$KB_FILE" rollout status daemonset/kube-flannel -n kube-system --timeout=120s 2>/dev/null || true
else
  log "  Flannel already has --public-ip fix ✅"
fi
ok "Step 5a: Flannel public-ip fixed"

# ── Step 5b: Patch CoreDNS to use explicit upstream DNS ──────────────────────
# On Talos, /etc/resolv.conf may point to an unreachable upstream. Use explicit
# public DNS servers to ensure pods can resolve external domains immediately.
log "Step 5b: Patching CoreDNS for explicit upstream DNS..."
kubectl --kubeconfig "$KB_FILE" patch configmap coredns -n kube-system --type=merge -p \
  '{"data":{"Corefile":".:53 {\n    errors\n    health {\n        lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n        pods insecure\n        fallthrough in-addr.arpa ip6.arpa\n        ttl 30\n    }\n    forward . 1.1.1.1 8.8.8.8 {\n       max_concurrent 1000\n    }\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}' \
  2>/dev/null || warn "CoreDNS patch failed"

kubectl --kubeconfig "$KB_FILE" rollout restart deployment/coredns -n kube-system 2>/dev/null || true
kubectl --kubeconfig "$KB_FILE" rollout status deployment/coredns -n kube-system --timeout=120s 2>/dev/null || true
ok "Step 5b: CoreDNS restarted with explicit upstream"

# ── Step 5c: Configure platform from .env feature flags ──────────────────────
log "Step 5c: Configuring platform from .env feature flags..."
bash scripts/configure-platform.sh || warn "configure-platform.sh had issues (continuing)"
ok "Step 5c: Platform configured"

echo "STAGE:argocd"
# ── Step 6: Deploy ArgoCD & Bootstrap ─────────────────────────────────────────
log "Step 6: Deploy ArgoCD & bootstrap ApplicationSet..."
ENV_NAME="$ENV_NAME" bash scripts/deploy/deploy-argocd.sh
ok "Step 6: ArgoCD deployed"

# ── Step 7: Bootstrap Storage + PriorityClasses ──────────────────────────────
log "Step 7: Bootstrap local-path-provisioner storage + platform PriorityClasses..."
ENV_NAME="$ENV_NAME" bash scripts/deploy/bootstrap-storage.sh
# Apply PriorityClasses early — Longhorn and other services reference platform-standard
kubectl --kubeconfig "$KB_FILE" apply \
  -f kubernetes/core/priority-classes/manifests/priority-classes.yaml 2>/dev/null || true
ok "Step 7: Storage bootstrapped + PriorityClasses applied"

# ── Step 7a: Deploy MetalLB directly via Helm (native L2 mode, no FRR) ────────
log "Step 7a: Deploying MetalLB via Helm..."
helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
helm repo update metallb 2>/dev/null || true
# Create namespace with privileged PodSecurity (MetalLB speaker needs NET_RAW, hostNetwork)
kubectl --kubeconfig "$KB_FILE" create namespace metallb-system --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB_FILE" apply -f -
kubectl --kubeconfig "$KB_FILE" label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null || true
# Pin chart version to match the ArgoCD app (kubernetes/core/metallb/application.yaml).
# Leaving this unpinned installs "latest", which drifts from the ArgoCD-managed
# version and causes a downgrade/rolling-update conflict on the speaker DaemonSet.
helm --kubeconfig "$KB_FILE" upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version "0.16.1" \
  -f kubernetes/core/metallb/values.yaml \
  --timeout 5m --wait 2>&1 | tail -5 || warn "MetalLB helm install had issues — continuing"
# Delete validating webhook (can timeout during initial setup before controller is fully ready)
kubectl --kubeconfig "$KB_FILE" delete validatingwebhookconfigurations metallb-webhook-configuration 2>/dev/null || true
sleep 5
# Apply MetalLB address pool and L2 advertisement
# Use same name as ArgoCD-managed manifest (vlan3-pool) to avoid duplicates
kubectl --kubeconfig "$KB_FILE" apply -f - <<METALLB_EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan3-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_VIP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: prod-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - vlan3-pool
  nodeSelectors:
    - matchLabels:
        node-role.kubernetes.io/control-plane: ""
METALLB_EOF
ok "Step 7a: MetalLB deployed (native L2, FRR disabled)"

# ── Step 7b: Deploy Longhorn directly (before GitOps apps need storage) ──
log "Step 7b: Deploying Longhorn directly via Helm..."
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update longhorn 2>/dev/null || true
kubectl --kubeconfig "$KB_FILE" create namespace longhorn-system --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB_FILE" apply -f -
helm --kubeconfig "$KB_FILE" upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "1.7.*" \
  -f kubernetes/core/longhorn/values.yaml \
  --timeout 10m --wait 2>&1 | tail -5 || warn "Longhorn helm install had issues — continuing"
# Apply supplementary manifests (StorageClass longhorn-retain etc.)
kubectl --kubeconfig "$KB_FILE" apply -f kubernetes/core/longhorn/manifests/ 2>/dev/null || true
# Delete Longhorn validating webhook — it intercepts ALL PVC operations and blocks
# them when Longhorn controller isn't fully ready (common on fresh deploys)
kubectl --kubeconfig "$KB_FILE" delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true
ok "Step 7b: Longhorn deployed"

# ── Step 7c: Restore volumes / TLS certs ────────────────────────────────────
# Auto-enable TLS restore if backup files exist (prevents LE rate limits on redeploy)
if [[ "${RESTORE_TLS:-false}" != "true" ]]; then
  if compgen -G "/opt/platform-tls-backup/*.yaml" > /dev/null 2>&1; then
    RESTORE_TLS=true
    log "Step 7c: TLS backups found in /opt/platform-tls-backup/ — auto-enabling restore"
  fi
fi

if [[ "${RESTORE_ENABLED:-false}" == "true" ]] || [[ "${RESTORE_TLS:-false}" == "true" ]]; then
  log "Step 7c: Restoring from backup..."
  KB_FILE="$KB_FILE" ENV_NAME="$ENV_NAME" \
  RESTORE_ENABLED=true \
  RESTORE_TLS="${RESTORE_TLS:-false}" \
  RESTORE_VOLUMES="${RESTORE_VOLUMES:-}" \
    bash scripts/deploy/restore-volumes.sh
  ok "Step 7c: Restore complete"
else
  log "Step 7c: Skipping restore (no backup files found and RESTORE_ENABLED=false)"
fi

echo "STAGE:bootstrap"
# ── Step 8: Deploy OpenBao directly + Bootstrap ───────────────────────────────
log "Step 8: Deploying OpenBao directly via Helm + bootstrapping..."
helm repo add openbao https://openbao.github.io/openbao-helm 2>/dev/null || true
helm repo update openbao 2>/dev/null || true
kubectl --kubeconfig "$KB_FILE" create namespace openbao --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB_FILE" apply -f - 2>/dev/null || true
# Apply namespace/network/rbac manifests first
kubectl --kubeconfig "$KB_FILE" apply -f kubernetes/core/openbao/manifests/ \
  --server-side 2>/dev/null || true
helm --kubeconfig "$KB_FILE" upgrade --install openbao openbao/openbao \
  --namespace openbao \
  --version "0.27.2" \
  -f kubernetes/core/openbao/values.yaml \
  --timeout 5m 2>&1 | tail -5 || warn "OpenBao helm install had issues — continuing"
# Now run the bootstrap-openbao script (init, unseal, seed secrets)
ENV_NAME="$ENV_NAME" \
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
SMTP_USERNAME="$SMTP_USERNAME" \
SMTP_PASSWORD="$SMTP_PASSWORD" \
PLATFORM_GITHUB_PAT="${GITHUB_PAT:-}" \
  bash scripts/deploy/bootstrap-openbao.sh
ok "Step 8: OpenBao deployed and bootstrapped"

echo "STAGE:apps"
# ── Step 9 removed: OneDev decommissioned 2026-07-03 — GitOps source is GitHub ──

# ── Step 10: Bootstrap ExternalSecrets + TLS Restore ─────────────────────────
log "Step 10: Bootstrap ExternalSecrets + TLS restore..."
# ESO authenticates to OpenBao via kubernetes auth (role external-secrets,
# provisioned by bootstrap-openbao.sh) — no service token to pass.
ENV_NAME="$ENV_NAME" bash scripts/deploy/bootstrap-externalsecrets.sh
ok "Step 10: ExternalSecrets bootstrapped"

# ── Step 11: Ensure DNS records ───────────────────────────────────────────────
log "Step 11: Ensuring DNS records (provider: $DNS_PROVIDER)..."
if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
  ENV_NAME="$ENV_NAME" CF_TOKEN="$CLOUDFLARE_API_TOKEN" bash scripts/deploy/ensure-cloudflare-dns.sh
else
  log "  Skipping Cloudflare DNS helper for provider: $DNS_PROVIDER"
fi
ok "Step 11: DNS configured"

# ── Step 12: Apply MetalLB IP Pool + Traefik Middleware ───────────────────────
log "Step 12: Applying MetalLB IP pool + Traefik middleware..."
for i in $(seq 1 30); do
  kubectl --kubeconfig "$KB_FILE" get crd ipaddresspools.metallb.io >/dev/null 2>&1 && break
  log "  Waiting for MetalLB CRDs ($i/30)..."
  sleep 10
done
envsubst < kubernetes/core/metallb/manifests/ip-pool.yaml | kubectl --kubeconfig "$KB_FILE" apply -f - 2>/dev/null || true
kubectl --kubeconfig "$KB_FILE" label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite 2>/dev/null || true
kubectl --kubeconfig "$KB_FILE" rollout restart daemonset/metallb-speaker -n metallb-system 2>/dev/null || true
# Clean up stale ServiceL2Status objects (MetalLB v0.15-0.16 bug with immutable node fields)
kubectl --kubeconfig "$KB_FILE" delete servicel2status --all -n metallb-system 2>/dev/null || true
ok "Step 12: MetalLB + Traefik middleware applied"

# ── Step 13: Configure certificate issuers ────────────────────────────────────
log "Step 13: Configuring certificate issuers (LE: $LETSENCRYPT_ENV)..."
if [[ "$LETSENCRYPT_ENV" == "staging" ]]; then
  log "  Switching to staging LE issuers..."
  for i in $(seq 1 20); do
    kubectl --kubeconfig "$KB_FILE" --insecure-skip-tls-verify \
      get crd certificates.cert-manager.io >/dev/null 2>&1 && break
    log "  Waiting for cert-manager CRDs ($i/20)..."
    sleep 10
  done
  for cert in $(kubectl --kubeconfig "$KB_FILE" --insecure-skip-tls-verify \
    get certificate -n traefik -o name 2>/dev/null || true); do
    CURRENT=$(kubectl --kubeconfig "$KB_FILE" --insecure-skip-tls-verify get "$cert" -n traefik \
      -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
    case "$CURRENT" in
      letsencrypt-http) NEW="letsencrypt-http-staging" ;;
      letsencrypt-dns|letsencrypt-cloudflare) NEW="letsencrypt-dns-staging" ;;
      *) continue ;;
    esac
    kubectl --kubeconfig "$KB_FILE" --insecure-skip-tls-verify patch "$cert" -n traefik \
      --type=merge -p "{\"spec\":{\"issuerRef\":{\"name\":\"${NEW}\"}}}" 2>/dev/null \
      && log "  Patched $cert → $NEW" || true
  done
fi
ok "Step 13: TLS configured"


# ── Step 15: Fix ingress-nginx admission webhook ──────────────────────────────
log "Step 15: Fixing ingress-nginx admission webhook CA bundle..."
for attempt in $(seq 1 12); do
  CA_BUNDLE=$(kubectl --kubeconfig "$KB_FILE" get secret ingress-nginx-admission \
    -n ingress-nginx -o jsonpath='{.data.ca}' 2>/dev/null || true)
  if [[ -n "$CA_BUNDLE" ]]; then
    kubectl --kubeconfig "$KB_FILE" patch validatingwebhookconfiguration \
      ingress-nginx-admission --type json \
      -p "[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CA_BUNDLE\"}]" \
      2>/dev/null && log "  ✅ ingress-nginx webhook CA patched" && break
  fi
  log "  Waiting for ingress-nginx-admission secret ($attempt/12)..."
  sleep 10
done
ok "Step 15: ingress-nginx webhook patched"

# ── Step 16: Patch cluster CoreDNS for internal zones ────────────────────────
log "Step 16: Patching CoreDNS for internal zones..."
DNS_CLUSTERIP=$(kubectl --kubeconfig "$KB_FILE" get svc coredns -n dns-system \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
TRAEFIK_CLUSTERIP=$(kubectl --kubeconfig "$KB_FILE" get svc traefik -n traefik \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "$DNS_CLUSTERIP" && -n "$TRAEFIK_CLUSTERIP" ]]; then
  kubectl --kubeconfig "$KB_FILE" patch configmap coredns -n kube-system --type=merge -p \
    "{\"data\":{\"Corefile\":\".:53 {\n    errors\n    health {\n        lameduck 5s\n    }\n    ready\n    log . {\n        class error\n    }\n    prometheus :9153\n\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n        pods insecure\n        fallthrough in-addr.arpa ip6.arpa\n        ttl 30\n    }\n    forward . 1.1.1.1 8.8.8.8 {\n       max_concurrent 1000\n    }\n    cache 30 {\n       disable success cluster.local\n       disable denial cluster.local\n    }\n    loop\n    reload\n    loadbalance\n}\n\nauth.${BASE_DOMAIN}:53 {\n    errors\n    hosts {\n        ${TRAEFIK_CLUSTERIP} auth.${BASE_DOMAIN}\n    }\n}\n\n${BASE_DOMAIN}:53 {\n    errors\n    forward . ${DNS_CLUSTERIP}\n    cache 30\n}\n\nint.${BASE_DOMAIN}:53 {\n    errors\n    forward . ${DNS_CLUSTERIP}\n    cache 30\n}\n\n${CLUSTER_LOCAL_DOMAIN}:53 {\n    errors\n    forward . ${DNS_CLUSTERIP}\n    cache 30\n}\n\"}}" 2>/dev/null || true
  kubectl --kubeconfig "$KB_FILE" rollout restart deployment/coredns -n kube-system 2>/dev/null || true
  kubectl --kubeconfig "$KB_FILE" rollout status deployment/coredns -n kube-system --timeout=60s 2>/dev/null || true
  ok "Step 16: CoreDNS patched"
else
  warn "Step 16: Could not get ClusterIPs — CoreDNS patching skipped"
fi

# ── Step 16b: Pre-apply platform manifests (blueprints, ExternalSecrets) ─────
log "Step 16b: Pre-applying platform manifests (ArgoCD may not have synced yet)..."
# Authentik: blueprint ConfigMaps + media + ExternalSecrets must exist before worker starts
kubectl --kubeconfig "$KB_FILE" apply -f kubernetes/platform/authentik/manifests/ 2>/dev/null || true
# Ensure authentik-media ConfigMap exists (Helm chart should create it; belt-and-suspenders)
kubectl --kubeconfig "$KB_FILE" create configmap authentik-media -n authentik \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KB_FILE" apply -f - 2>/dev/null || true
# Apply ExternalSecrets for all platform namespaces so secrets sync before apps start
for ns_dir in kubernetes/platform/*/manifests; do
  kubectl --kubeconfig "$KB_FILE" apply -f "$ns_dir/" 2>/dev/null || true
done
ok "Step 16b: Platform manifests pre-applied"


# ── Step 16c: Fix Authentik PostgreSQL storageClass (longhorn→local-path) ────
# The GitHub values.yaml has longhorn-retain — delete the bad PVC and force a
# re-sync so local-path is used instead.
log "Step 16c: Ensuring Authentik PostgreSQL uses local-path storageClass..."
AK_PVC=$(kubectl --kubeconfig "$KB_FILE" get pvc data-authentik-postgresql-0 -n authentik \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
if [[ "$AK_PVC" == "longhorn-retain" ]]; then
  warn "  Authentik PostgreSQL PVC uses longhorn-retain — fixing to local-path..."
  # Delete StatefulSet controller (orphan pods for now)
  kubectl --kubeconfig "$KB_FILE" delete statefulset authentik-postgresql -n authentik --cascade=orphan 2>/dev/null || true
  # Delete orphaned pod FIRST so kubernetes.io/pvc-protection finalizer releases
  kubectl --kubeconfig "$KB_FILE" delete pod authentik-postgresql-0 -n authentik --force --grace-period=0 2>/dev/null || true
  # Wait for pod to actually disappear so pvc-protection finalizer is released
  for _i in $(seq 1 15); do
    if ! kubectl --kubeconfig "$KB_FILE" get pod authentik-postgresql-0 -n authentik &>/dev/null; then
      break
    fi
    sleep 2
  done
  # Now remove all PVC finalizers and force-delete
  kubectl --kubeconfig "$KB_FILE" patch pvc data-authentik-postgresql-0 -n authentik \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl --kubeconfig "$KB_FILE" delete pvc data-authentik-postgresql-0 -n authentik --force --grace-period=0 2>/dev/null || true
  # Wait for PVC to actually disappear (not just Terminating)
  for _i in $(seq 1 20); do
    if ! kubectl --kubeconfig "$KB_FILE" get pvc data-authentik-postgresql-0 -n authentik &>/dev/null; then
      break
    fi
    # If still stuck, also remove PV finalizers and Longhorn Volume CR
    PV_NAME=$(kubectl --kubeconfig "$KB_FILE" get pv --no-headers 2>/dev/null \
      | awk '/authentik\/data-authentik-postgresql-0/{print $1}' | head -1)
    if [[ -n "$PV_NAME" ]]; then
      kubectl --kubeconfig "$KB_FILE" patch pv "$PV_NAME" \
        -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
      kubectl --kubeconfig "$KB_FILE" patch volume -n longhorn-system "$PV_NAME" \
        -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
      kubectl --kubeconfig "$KB_FILE" delete volume -n longhorn-system "$PV_NAME" \
        --force --grace-period=0 2>/dev/null || true
    fi
    sleep 2
  done
  # Clean up Released Longhorn PV to avoid confusion on next run
  OLD_LH_PV=$(kubectl --kubeconfig "$KB_FILE" get pv --no-headers 2>/dev/null \
    | awk '/longhorn-retain/ && /Released/{print $1}' | head -1)
  if [[ -n "$OLD_LH_PV" ]]; then
    kubectl --kubeconfig "$KB_FILE" patch pv "$OLD_LH_PV" \
      -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl --kubeconfig "$KB_FILE" delete pv "$OLD_LH_PV" --force --grace-period=0 2>/dev/null || true
  fi
  sleep 3
  # Force ArgoCD to re-sync platform-authentik (will use local-path now)
  kubectl --kubeconfig "$KB_FILE" annotate application platform-authentik -n argocd \
    argocd.argoproj.io/refresh="normal" --overwrite 2>/dev/null || true
  sleep 5
  kubectl --kubeconfig "$KB_FILE" patch application platform-authentik -n argocd \
    --type merge -p '{"operation":{"initiatedBy":{"username":"deploy-script"},"sync":{"syncStrategy":{"hook":{}}}}}' \
    2>/dev/null || true
  # Wait for PVC to be recreated with local-path
  for i in $(seq 1 30); do
    NEW_SC=$(kubectl --kubeconfig "$KB_FILE" get pvc data-authentik-postgresql-0 -n authentik \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
    if [[ "$NEW_SC" == "local-path" ]]; then
      ok "  Authentik PostgreSQL PVC now uses local-path ✅"
      # Restart worker/server pods that may be in CrashLoopBackOff waiting for PostgreSQL
      kubectl --kubeconfig "$KB_FILE" delete pod -n authentik -l app.kubernetes.io/component=worker \
        --force --grace-period=0 2>/dev/null || true
      kubectl --kubeconfig "$KB_FILE" delete pod -n authentik -l app.kubernetes.io/component=server \
        --force --grace-period=0 2>/dev/null || true
      break
    elif [[ -n "$NEW_SC" ]]; then
      warn "  PVC recreated with $NEW_SC (unexpected)"
      break
    fi
    sleep 5
  done
else
  ok "  Authentik PostgreSQL PVC storageClass: ${AK_PVC:-local-path} ✅"
fi
ok "Step 16c: Authentik PostgreSQL storageClass verified"

# ── Step 17: Configure Authentik ──────────────────────────────────────────────
log "Step 17: Configuring Authentik..."
# Use a temp file so recovery links and tokens survive to the email step (local deploys
# don't have GITHUB_ENV flowing between subshells)
export IW_AUTH_ENV_FILE="/tmp/iw-auth-env-$ENV_NAME.sh"
rm -f "$IW_AUTH_ENV_FILE"
ENV_NAME="$ENV_NAME" IW_AUTH_ENV_FILE="$IW_AUTH_ENV_FILE" \
  bash scripts/deploy/configure-authentik.sh || warn "configure-authentik.sh failed (may retry)"
ENV_NAME="$ENV_NAME" bash scripts/deploy/set-user-passwords.sh || warn "set-user-passwords.sh failed (may retry)"
ok "Step 17: Authentik configured"

# ── Step 18: Send welcome emails ──────────────────────────────────────────────
log "Step 18: Sending welcome emails..."
ENV_NAME="$ENV_NAME" SMTP_USERNAME="$SMTP_USERNAME" SMTP_PASSWORD="$SMTP_PASSWORD" \
  bash scripts/deploy/send-welcome-emails.sh || warn "Welcome emails failed (non-fatal)"

# ── Step 19: Configure OIDC ───────────────────────────────────────────────────
log "Step 19: Configuring OIDC (ArgoCD + OpenBao)..."
ENV_NAME="$ENV_NAME" PROXMOX_API_TOKEN="$PROXMOX_API_TOKEN" \
  bash scripts/deploy/configure-oidc.sh 2>/dev/null || warn "OIDC configuration failed (may retry)"
ok "Step 19: OIDC configured"

# ── Step 19b: Deploy n8n automation platform ─────────────────────────────────
log "Step 19b: Deploying n8n automation platform with Authentik SSO..."
bash scripts/deploy/deploy-n8n.sh || warn "n8n deployment failed (non-fatal)"
ok "Step 19b: n8n deployed"

# ── Step 19c: Wait for Traefik HA to be ready ──────────────────────────────────
log "Step 19c: Waiting for Traefik pods to be ready (up to 3 min)..."
for i in $(seq 1 18); do
  READY=$(kubectl --kubeconfig "$KB_FILE" get deploy traefik -n traefik -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl --kubeconfig "$KB_FILE" get deploy traefik -n traefik -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2")
  if [[ "${READY:-0}" -ge "${DESIRED:-2}" ]]; then
    ok "Step 19c: Traefik ready ($READY/$DESIRED replicas)"
    break
  fi
  log "  Traefik $READY/$DESIRED ready ($i/18)..."
  sleep 10
done
# Verify external access works
if curl -sk -o /dev/null -w "%{http_code}" --max-time 5 --resolve "auth.${BASE_DOMAIN}:443:${VIP_ADDRESS:-${METALLB_TRAEFIK_VIP:-10.0.0.200}}" "https://auth.${BASE_DOMAIN}/" | grep -q "^[23]"; then
  ok "  External access verified via Traefik VIP"
else
  warn "  External access check failed — may need time to stabilize"
fi

echo "STAGE:postdeploy"
# ── Step 20: Post-deploy tests ────────────────────────────────────────────────
log "Step 20: Running post-deploy tests..."
bash scripts/test-post-deploy.sh "$KB_FILE" "$ENV_NAME" 2>/dev/null || warn "Post-deploy tests had failures (non-fatal)"

# ── Step 21: Send deployment summary email ────────────────────────────────────
log "Step 21: Sending deployment summary email..."

# Build list of control-plane IPs from .env NODE_X_* vars (loaded at top).
# Falls back to NODE_1_IP, then the first IP from cluster.yaml.
_cp_ips=""
for _idx in $(seq 1 "${NODE_COUNT:-3}"); do
  _ip_var="NODE_${_idx}_IP"
  _role_var="NODE_${_idx}_ROLE"
  _ip="${!_ip_var:-}"
  _role="${!_role_var:-control-plane}"
  if [[ -n "$_ip" && "$_role" == "control-plane" ]]; then
    _cp_ips="${_cp_ips:+$_cp_ips,}$_ip"
  fi
done
_cp_ips="${_cp_ips:-${NODE_1_IP:-$(grep 'ip:' envs/"$ENV_NAME"/cluster.yaml 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')}}"
CONTROLPLANE_IPS="$_cp_ips"

# Try all control-plane endpoints so a crashed cp1 doesn't block the email
_bao_token=""
_bao_unseal=""
for _api_ip in $(echo "${CONTROLPLANE_IPS}" | tr ',' ' ') ""; do
  _kb_flag="--kubeconfig $KB_FILE"
  [ -n "$_api_ip" ] && _kb_flag="--kubeconfig $KB_FILE --server=https://$_api_ip:6443 --insecure-skip-tls-verify"
  _bao_token=$(kubectl $_kb_flag get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  [ -n "$_bao_token" ] && break
done
BAO_TOKEN="${_bao_token:-unavailable}"

for _api_ip in $(echo "${CONTROLPLANE_IPS}" | tr ',' ' ') ""; do
  _kb_flag="--kubeconfig $KB_FILE"
  [ -n "$_api_ip" ] && _kb_flag="--kubeconfig $KB_FILE --server=https://$_api_ip:6443 --insecure-skip-tls-verify"
  _bao_unseal=$(kubectl $_kb_flag get secret openbao-unseal -n openbao \
    -o jsonpath='{.data.unseal_key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  [ -n "$_bao_unseal" ] && break
done
BAO_UNSEAL="${_bao_unseal:-unavailable}"

# Read Authentik admin password from OpenBao
_FIRST_CP_IP=$(echo "$CONTROLPLANE_IPS" | cut -d',' -f1)
if [ -n "$BAO_TOKEN" ] && [ "$BAO_TOKEN" != "unavailable" ]; then
  _auth_admin_pass=$(kubectl --kubeconfig "$KB_FILE" --server=https://"${_FIRST_CP_IP}":6443 \
    --insecure-skip-tls-verify exec -n openbao openbao-0 -- \
    sh -c "BAO_TOKEN='$BAO_TOKEN' bao kv get -field=admin-password secret/platform/authentik" \
    2>/dev/null || echo "")
  [ -n "$_auth_admin_pass" ] && export AUTHENTIK_ADMIN_PASS="$_auth_admin_pass"
  # Also read the akadmin bootstrap password for the break-glass section in the email
  _auth_akadmin_pass=$(kubectl --kubeconfig "$KB_FILE" --server=https://"${_FIRST_CP_IP}":6443 \
    --insecure-skip-tls-verify exec -n openbao openbao-0 -- \
    sh -c "BAO_TOKEN='$BAO_TOKEN' bao kv get -field=bootstrap-password secret/platform/authentik" \
    2>/dev/null || echo "")
  [ -n "$_auth_akadmin_pass" ] && export AUTHENTIK_AKADMIN_PASS="$_auth_akadmin_pass"
fi

# Source recovery links and tokens written by configure-authentik.sh
if [ -f "${IW_AUTH_ENV_FILE:-}" ]; then
  # shellcheck source=/dev/null
  set -a; source "$IW_AUTH_ENV_FILE"; set +a
fi

# Read the n8n owner credentials (randomly generated + persisted by deploy-n8n.sh)
# so the summary email carries the native n8n login — n8n Community has no SSO.
N8N_OWNER_PASS=$(kubectl --kubeconfig "$KB_FILE" --server=https://"${_FIRST_CP_IP}":6443 \
  --insecure-skip-tls-verify get secret n8n-owner-credentials -n n8n-prod \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
N8N_OWNER_EMAIL=$(kubectl --kubeconfig "$KB_FILE" --server=https://"${_FIRST_CP_IP}":6443 \
  --insecure-skip-tls-verify get secret n8n-owner-credentials -n n8n-prod \
  -o jsonpath='{.data.email}' 2>/dev/null | base64 -d 2>/dev/null || echo "$ADMIN_EMAIL")
export N8N_OWNER_PASS="${N8N_OWNER_PASS:-unavailable}"
export N8N_OWNER_EMAIL="${N8N_OWNER_EMAIL:-$ADMIN_EMAIL}"
export N8N_HOST="n8n.int.${BASE_DOMAIN}"

export DEPLOY_ENV="$ENV_NAME"
export DEPLOY_RUN_URL="local://${HOSTNAME:-$(hostname)}/$(date +%Y-%m-%dT%H:%M:%S)"
export BAO_TOKEN BAO_UNSEAL BASE_DOMAIN ADMIN_EMAIL ADMIN_USERNAME AUTHENTIK_AKADMIN_PASS
SMTP_USERNAME="$SMTP_USERNAME" SMTP_PASSWORD="$SMTP_PASSWORD" SMTP_TO="${SMTP_TO:-$SMTP_USERNAME}" \
  python3 scripts/send-deploy-email.py || warn "Deploy summary email failed (non-fatal)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     ✅ Deployment complete!                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
ok "Kubeconfig    : $KB_FILE"
ok "Talosconfig   : envs/$ENV_NAME/generated/talosconfig"
ok "Tofu state    : $STATE_DIR"
echo ""
log "Quick checks:"
kubectl --kubeconfig "$KB_FILE" get nodes 2>/dev/null || true
echo ""
log "Service URLs (may take a few minutes to become available):"
log "  ArgoCD     : https://argocd.int.${BASE_DOMAIN}"
log "  Console    : https://console.${BASE_DOMAIN}"
log "  Authentik  : https://auth.${BASE_DOMAIN}"
log "  Grafana    : https://grafana.int.${BASE_DOMAIN}"
echo ""
log "Deployment log: $(date)"
echo ""
