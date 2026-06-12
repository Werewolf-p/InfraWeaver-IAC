#!/usr/bin/env bash
# =============================================================================
# redeploy-local.sh — InfraWeaver Full Local Redeployment
#
# USAGE:
#   # Explicit confirmation required:
#   CONFIRM=DESTROY bash scripts/redeploy-local.sh
#
#   # Or interactive:
#   bash scripts/redeploy-local.sh
#
# WHAT THIS DOES:
#   1. Backs up .env and users.yaml to /tmp/iw-redeploy-backup-<timestamp>/
#   2. Destroys all cluster VMs (9300-9312) on Proxmox via SSH
#   3. Runs tofu destroy for cluster state
#   4. Clears terraform state for cluster + platform_bootstrap modules
#   5. Runs deploy-local.sh to provision everything from scratch
#
# PRESERVED:
#   - .env file
#   - users.yaml
#   - envs/<env>/cluster.yaml (node definitions)
#
# DESTROYED:
#   - All Talos cluster VMs (9310-9312 + any 9300-9302)
#   - All Kubernetes state (namespaces, PVCs, secrets)
#   - OpenBao data (keys regenerated on redeploy)
#
# NOTE: Do NOT use this to remove the init VM (9001) or the runner (9100)
#       those are excluded.
# =============================================================================
set -euo pipefail

SCRIPT_NAME="redeploy-local"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# shellcheck source=scripts/lib.sh
source "scripts/lib.sh"

# ── Confirmation ──────────────────────────────────────────────────────────────
CONFIRM="${CONFIRM:-}"
if [[ "$CONFIRM" != "DESTROY" ]]; then
  echo ""
  echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;31m║   ⚠  FULL REDEPLOYMENT — DESTRUCTIVE OPERATION  ⚠           ║\033[0m"
  echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════╝\033[0m"
  echo ""
  echo "This will:"
  echo "  • DESTROY all cluster VMs: 9300, 9301, 9302, 9310, 9311, 9312"
  echo "  • WIPE all Kubernetes data, namespaces, PVCs, and secrets"
  echo "  • REGENERATE all passwords and tokens"
  echo "  • REDEPLOY the entire platform from scratch"
  echo ""
  echo "Preserved: .env, users.yaml, cluster.yaml"
  echo ""
  read -rp "Type DESTROY to confirm: " CONFIRM
  if [[ "$CONFIRM" != "DESTROY" ]]; then
    die "Aborting. Type exactly DESTROY to confirm."
  fi
fi

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  die "No .env file found at $ENV_FILE — cannot proceed without configuration"
fi

# shellcheck disable=SC1090,SC2046
eval "$(python3 - "$ENV_FILE" << 'PYEOF'
import sys, re

def bash_ansi_quote(s):
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
    return (s
        .replace('\\n', '\n')
        .replace('\\t', '\t')
        .replace('\\r', '\r')
        .replace('\\"', '"')
        .replace('\\\\', '\\'))

path = sys.argv[1]
content = open(path).read()
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

ENV_NAME="${ENV_NAME:-productie}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     InfraWeaver — Full Local Redeployment                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log "Environment : $ENV_NAME"
log "Started     : $(date)"
echo ""

# ── Step 1: Backup .env and users.yaml ───────────────────────────────────────
BACKUP_DIR="${REPO_DIR}/.redeploy-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$ENV_FILE" "$BACKUP_DIR/.env"
[[ -f users.yaml ]] && cp users.yaml "$BACKUP_DIR/users.yaml"
[[ -f "envs/$ENV_NAME/cluster.yaml" ]] && cp "envs/$ENV_NAME/cluster.yaml" "$BACKUP_DIR/cluster.yaml"
ok "Step 1: Backed up to $BACKUP_DIR"

# ── Step 1b: Backup TLS certs before destroying cluster ──────────────────────
log "Step 1b: Backing up TLS certs before destroy..."
KB_CURRENT="$HOME/.kube/config-platform-${ENV_NAME}"
if kubectl --kubeconfig "$KB_CURRENT" get nodes --request-timeout=5s >/dev/null 2>&1; then
  # Use --no-wait since certs are already issued on the live cluster
  ENV_NAME="$ENV_NAME" KB="$KB_CURRENT" \
    bash scripts/deploy/refresh-tls-backup.sh --no-wait 2>&1 \
    || warn "TLS backup failed — continuing (certs may need to be re-issued)"
  ok "Step 1b: TLS certs backed up to /opt/platform-tls-backup/"
else
  warn "Step 1b: Cluster not reachable — skipping TLS backup"
fi


# ── Step 3: Set up SSH key ────────────────────────────────────────────────────
log "Step 3: Setting up SSH key..."
mkdir -p ~/.ssh
if [[ -f "$DEPLOYER_SSH_KEY" ]]; then
  if [[ "$(realpath "$DEPLOYER_SSH_KEY" 2>/dev/null)" != "$(realpath ~/.ssh/deployer_ed25519 2>/dev/null)" ]]; then
    cp "$DEPLOYER_SSH_KEY" ~/.ssh/deployer_ed25519
  fi
elif [[ "$DEPLOYER_SSH_KEY" == *"BEGIN"* ]]; then
  printf '%s\n' "$DEPLOYER_SSH_KEY" > ~/.ssh/deployer_ed25519
else
  die "DEPLOYER_SSH_KEY must be a file path or PEM-encoded private key"
fi
chmod 600 ~/.ssh/deployer_ed25519
ok "SSH key ready"

# ── Step 4: Force-destroy platform VMs on Proxmox ────────────────────────────
log "Step 4: Force-destroying all platform VMs..."
PVE_IP="${PROXMOX_HOST:-}"
if [[ -z "$PVE_IP" ]]; then
  PVE_IP=$(grep 'proxmox_host:' "envs/$ENV_NAME/cluster.yaml" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)"/\1/' | xargs || true)
fi
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i ~/.ssh/deployer_ed25519"

# Gather ALL PVE node IPs from cluster.yaml pve_nodes for multi-node orphan cleanup
ALL_PVE_IPS=$(python3 -c "
import yaml, sys
try:
    with open('envs/$ENV_NAME/cluster.yaml') as f:
        c = yaml.safe_load(f)
    ips = list(c.get('pve_nodes', {}).values())
    print('\\n'.join(str(i) for i in ips if i))
except Exception:
    pass
" 2>/dev/null)
ALL_PVE_IPS=$(printf '%s\n%s' "$PVE_IP" "$ALL_PVE_IPS" | awk '!seen[$0]++ && NF' | tr '\n' ' ')
log "  PVE nodes for cleanup: $ALL_PVE_IPS"

# These are the platform cluster VMs — do NOT include 9001 (init VM), 9100 (runner), 9200 (reserved)
PLATFORM_VMIDS="9300 9301 9302 9310 9311 9312"
log "  Destroying platform VMs: $PLATFORM_VMIDS (preserving 9001, 9100, 9200)"

for VMID in $PLATFORM_VMIDS; do
  # Kill any ghost QEMU process first
  GHOST_PID=$(ssh $SSH_OPTS root@"$PVE_IP" \
    "ps aux | grep 'kvm -id $VMID ' | grep -v grep | awk '{print \$2}' | head -1" 2>/dev/null || true)
  if [[ -n "$GHOST_PID" ]]; then
    log "  Ghost QEMU PID $GHOST_PID for VM $VMID — killing..."
    ssh $SSH_OPTS root@"$PVE_IP" \
      "kill -9 $GHOST_PID 2>/dev/null; sleep 3; rm -f /var/run/qemu-server/$VMID.qmp /var/run/qemu-server/$VMID.serial0 2>/dev/null; true" || true
  fi
  if ssh $SSH_OPTS root@"$PVE_IP" "qm status $VMID" 2>/dev/null | grep -q "running\|stopped\|status"; then
    log "  Destroying VM $VMID..."
    ssh $SSH_OPTS root@"$PVE_IP" \
      "qm stop $VMID --skiplock --timeout 10 2>/dev/null; sleep 2; qm destroy $VMID --purge --skiplock 2>/dev/null" || true
    ok "  VM $VMID destroyed"
  else
    log "  VM $VMID not found on primary — orphan cleanup runs on all nodes below"
    ssh $SSH_OPTS root@"$PVE_IP" \
      "rm -f /var/run/qemu-server/$VMID.qmp /var/run/qemu-server/$VMID.serial0 2>/dev/null; true" 2>/dev/null || true
  fi
done
# ── Comprehensive orphan LVM cleanup on ALL PVE nodes ────────────────────────
# Catches stale disks left on remote nodes that qm destroy --purge misses.
log "  Running orphan LVM cleanup on all PVE nodes: $ALL_PVE_IPS"
for _pve_ip in $ALL_PVE_IPS; do
  for VMID in $PLATFORM_VMIDS; do
    ssh $SSH_OPTS root@"$_pve_ip" "
      # Stop and destroy the VM if it exists on this remote node (e.g. microserver)
      if qm status \$VMID 2>/dev/null | grep -q "running\\|stopped\\|status"; then
        qm stop \$VMID --skiplock --timeout 15 2>/dev/null || true
        sleep 2
        qm destroy \$VMID --purge --skiplock 2>/dev/null && echo "  VM \$VMID destroyed on $_pve_ip" || true
      fi
      for VG_LV in \$(lvs --noheadings -o vg_name,lv_name 2>/dev/null \
          | awk '{print \$1"/"\$2}' | grep '/vm-\${VMID}-disk'); do
        lvremove -f "\$VG_LV" 2>/dev/null \
          && echo "  Removed orphan \$VG_LV on $_pve_ip" || true
      done
      rm -f /var/run/qemu-server/\${VMID}.qmp /var/run/qemu-server/\${VMID}.serial0 2>/dev/null || true
    " 2>/dev/null || true
  done
done
ok "Step 4: Platform VMs destroyed"

# ── Step 5: Terraform destroy + state clear ───────────────────────────────────
log "Step 5: Running tofu destroy and clearing state..."
export TF_VAR_proxmox_api_token="$PROXMOX_API_TOKEN"
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

STATE_DIR=~/.tofu/state/platform-"$ENV_NAME"
mkdir -p "$STATE_DIR"

cd terraform

tofu init -backend-config="path=$STATE_DIR/terraform.tfstate" -reconfigure 2>&1 | tail -5 || true

VARS=""
[[ -f "../envs/$ENV_NAME/terraform.tfvars" ]]     && VARS="$VARS -var-file=../envs/$ENV_NAME/terraform.tfvars"
[[ -f "../envs/$ENV_NAME/services.auto.tfvars" ]] && VARS="$VARS -var-file=../envs/$ENV_NAME/services.auto.tfvars"

# Destroy only cluster + cloud-init templates (preserve runner VM state)
CLUSTER_TARGETS="-target=module.talos_cluster -target=module.cloudinit_templates"
# shellcheck disable=SC2086
tofu destroy $VARS $CLUSTER_TARGETS -auto-approve 2>&1 || warn "tofu destroy failed or no prior state — continuing"

# Clear cluster + platform_bootstrap state
tofu state rm module.talos_cluster 2>/dev/null || true
tofu state rm module.cloudinit_templates 2>/dev/null || true
tofu state list 2>/dev/null | grep 'module\.platform_bootstrap' | while read -r res; do
  tofu state rm "$res" 2>/dev/null || true
  log "  cleared: $res"
done || true

cd "$REPO_DIR"
ok "Step 5: Tofu state cleared"

# ── Step 6: Run fresh deployment ──────────────────────────────────────────────
log "Step 6: Starting fresh deployment..."
echo ""
log "=== Handing off to deploy-local.sh ==="
echo ""

ENV_FILE="$ENV_FILE" RESTORE_TLS=true bash scripts/deploy-local.sh

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
ok "Full redeployment complete!"
ok "Backup saved at: $BACKUP_DIR"
