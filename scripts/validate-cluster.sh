#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-cluster.sh — Pre-flight checks before running tofu apply
#
# USAGE:
#   bash scripts/validate-cluster.sh [--env <env>] [--fix]
#
# OPTIONS:
#   --env <env>   Environment to validate (default: productie)
#   --fix         Print fix instructions for each failed check
#   --quiet       Only print failures (no progress output)
#
# CHECKS PERFORMED:
#   1. cluster.yaml exists and is valid YAML
#   2. SSH connectivity to each PVE node in pve_nodes
#   3. Deployer SSH key exists on each PVE node (~/.ssh/authorized_keys)
#   4. Required datastores exist on each PVE node
#   5. Terraform/OpenTofu state backend reachable
#   6. Required tools installed (tofu, kubectl, talosctl, yq)
#   7. Kubeconfig connectivity (if cluster already exists)
#
# EXIT CODES:
#   0 — all checks passed
#   1 — one or more checks failed
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_NAME="validate-cluster"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
ENV="${ENV_NAME:-productie}"
FIX=false
QUIET=false
PASS=0
FAIL=0
WARN=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)   ENV="$2"; shift 2 ;;
    --fix)   FIX=true; shift ;;
    --quiet) QUIET=true; shift ;;
    -h|--help)
      sed -n '/^# USAGE/,/^# EXIT/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

CLUSTER_YAML="envs/${ENV}/cluster.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SSH_KEY="${HOME}/.ssh/deployer_ed25519"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { PASS=$((PASS+1)); $QUIET || echo -e "  ${GREEN}✅ PASS${NC}  $*"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}❌ FAIL${NC}  $*"; }
warn() { WARN=$((WARN+1)); echo -e "  ${YELLOW}⚠️  WARN${NC}  $*"; }
info() { $QUIET || echo -e "       $*"; }
header() { $QUIET || echo -e "\n${YELLOW}── $* ──${NC}"; }

cd "$REPO_ROOT"

echo "═══════════════════════════════════════════════════════"
echo "  InfraWeaver Pre-flight Validator"
echo "  Environment : ${ENV}"
echo "  Cluster YAML: ${CLUSTER_YAML}"
echo "═══════════════════════════════════════════════════════"

# ── 1. Required tools ─────────────────────────────────────────────────────────
header "Required tools"

for tool in tofu kubectl talosctl yq python3; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool $(command -v "$tool")"
  else
    fail "$tool not found in PATH"
    if $FIX; then
      case $tool in
        tofu)      info "Install: curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh" ;;
        kubectl)   info "Install: https://kubernetes.io/docs/tasks/tools/" ;;
        talosctl)  info "Install: curl -sL https://talos.dev/install | sh" ;;
        yq)        info "Install: snap install yq  OR  pip3 install yq" ;;
        python3)   info "Install: apt install python3" ;;
      esac
    fi
  fi
done

# ── 2. cluster.yaml exists and is parseable ───────────────────────────────────
header "Cluster configuration (${CLUSTER_YAML})"

if [ ! -f "$CLUSTER_YAML" ]; then
  fail "cluster.yaml not found: ${CLUSTER_YAML}"
  if $FIX; then
    info "Create it by copying: cp envs/productie/cluster.yaml envs/${ENV}/cluster.yaml"
  fi
  echo ""
  echo "Cannot continue without cluster.yaml — aborting remaining checks."
  exit 1
fi

if python3 -c "import yaml; yaml.safe_load(open('${CLUSTER_YAML}'))" 2>/dev/null; then
  ok "cluster.yaml is valid YAML"
else
  fail "cluster.yaml has YAML syntax errors"
  python3 -c "import yaml; yaml.safe_load(open('${CLUSTER_YAML}'))" 2>&1 | head -5
  exit 1
fi

# Parse pve_nodes and datastore from cluster.yaml using python
PVE_NODES_JSON=$(python3 - <<'PYEOF'
import yaml, json, sys
with open("${CLUSTER_YAML}") as f:
    data = yaml.safe_load(f)
pve = data.get("pve_nodes", {})
ds = data.get("talos_image_datastore", "local-lvm")
print(json.dumps({"pve_nodes": pve, "datastore": ds}))
PYEOF
)

# Replace ${CLUSTER_YAML} in the heredoc
PVE_NODES_JSON=$(python3 -c "
import yaml, json, sys
with open('${CLUSTER_YAML}') as f:
    data = yaml.safe_load(f)
pve = data.get('pve_nodes', {})
ds = data.get('talos_image_datastore', 'local-lvm')
print(json.dumps({'pve_nodes': pve, 'datastore': ds}))
")

PVE_NODE_NAMES=$(echo "$PVE_NODES_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d['pve_nodes'].keys()))")
DATASTORE=$(echo "$PVE_NODES_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['datastore'])")

PVE_COUNT=$(echo "$PVE_NODE_NAMES" | grep -c . || true)
ok "Parsed ${PVE_COUNT} PVE node(s): $(echo "$PVE_NODE_NAMES" | tr '\n' ' ')"
ok "Talos image datastore: ${DATASTORE}"

# ── 3. SSH key exists locally ─────────────────────────────────────────────────
header "SSH deployer key"

if [ -f "$SSH_KEY" ]; then
  ok "Deployer key found: ${SSH_KEY}"
  PERMS=$(stat -c "%a" "$SSH_KEY" 2>/dev/null || stat -f "%A" "$SSH_KEY" 2>/dev/null)
  if [ "$PERMS" = "600" ] || [ "$PERMS" = "0600" ]; then
    ok "Deployer key permissions: ${PERMS}"
  else
    warn "Deployer key permissions ${PERMS} — should be 600"
    if $FIX; then info "Fix: chmod 600 ${SSH_KEY}"; fi
  fi
else
  fail "Deployer key not found: ${SSH_KEY}"
  if $FIX; then
    info "Generate: ssh-keygen -t ed25519 -f ${SSH_KEY} -N ''"
    info "Then copy to each PVE node: ssh-copy-id -i ${SSH_KEY}.pub root@<pve_ip>"
  fi
fi

# ── 4. SSH connectivity to each PVE node ─────────────────────────────────────
header "PVE node SSH connectivity"

while IFS= read -r node_name; do
  [ -z "$node_name" ] && continue

  NODE_IP=$(echo "$PVE_NODES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['pve_nodes'].get('${node_name}', ''))
")

  if [ -z "$NODE_IP" ]; then
    warn "No IP found for PVE node ${node_name}"
    continue
  fi

  info "Testing SSH to ${node_name} (${NODE_IP})..."
  if SSH_OUT=$(ssh -n -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    "root@${NODE_IP}" "echo ok" 2>&1); then
    ok "SSH to ${node_name} (${NODE_IP}) — connected"

    # Check datastore exists on this node
    DS_CHECK=$(ssh -n -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "root@${NODE_IP}" \
      "pvesm list '${DATASTORE}' &>/dev/null && echo exists || echo missing" 2>/dev/null || echo "unknown")

    if [ "$DS_CHECK" = "exists" ]; then
      ok "Datastore '${DATASTORE}' exists on ${node_name}"
    elif [ "$DS_CHECK" = "missing" ]; then
      fail "Datastore '${DATASTORE}' NOT found on ${node_name}"
      if $FIX; then
        info "Check available datastores: ssh root@${NODE_IP} pvesm status"
        info "Update 'talos_image_datastore' in ${CLUSTER_YAML} to match"
      fi
    else
      warn "Could not verify datastore on ${node_name} (pvesm not available?)"
    fi
  else
    fail "SSH to ${node_name} (${NODE_IP}) failed: ${SSH_OUT}"
    if $FIX; then
      info "Check: 1) IP is correct in ${CLUSTER_YAML}"
      info "       2) Deployer key is in /root/.ssh/authorized_keys on ${NODE_IP}"
      info "       3) Port 22 is open: nc -zv ${NODE_IP} 22"
    fi
  fi
done <<< "$PVE_NODE_NAMES"

# ── 5. Terraform backend reachable ────────────────────────────────────────────
header "Terraform/OpenTofu backend"

BACKEND_FILE="terraform/backend.tf"
if [ -f "$BACKEND_FILE" ]; then
  BACKEND_TYPE=$(grep -oP 'backend\s+"\K[^"]+' "$BACKEND_FILE" 2>/dev/null || echo "local")
  ok "Backend type: ${BACKEND_TYPE}"

  if [ "$BACKEND_TYPE" = "s3" ] || grep -q "http" "$BACKEND_FILE" 2>/dev/null; then
    BACKEND_ADDR=$(grep -oP 'address\s*=\s*"\K[^"]+' "$BACKEND_FILE" 2>/dev/null || echo "")
    if [ -n "$BACKEND_ADDR" ]; then
      if curl -sf --max-time 5 "$BACKEND_ADDR" &>/dev/null; then
        ok "Backend address reachable: ${BACKEND_ADDR}"
      else
        warn "Backend address not reachable: ${BACKEND_ADDR} (may require VPN)"
      fi
    fi
  fi
else
  warn "No backend.tf found — using local state (not recommended for team use)"
  if $FIX; then
    info "Consider adding a remote backend: https://opentofu.org/docs/language/settings/backends/"
  fi
fi

# ── 6. Kubeconfig connectivity (if cluster exists) ────────────────────────────
header "Kubernetes cluster connectivity"

KUBECONFIG_PATH="${HOME}/.kube/config-platform-${ENV}"
if [ ! -f "$KUBECONFIG_PATH" ]; then
  warn "Kubeconfig not found: ${KUBECONFIG_PATH} (expected if cluster not yet deployed)"
  if $FIX; then
    info "After deploying, run: bash scripts/get-kubeconfig.sh"
  fi
else
  if kubectl --kubeconfig="$KUBECONFIG_PATH" cluster-info &>/dev/null 2>&1; then
    NODE_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | wc -l || echo "?")
    ok "Cluster reachable — ${NODE_COUNT} node(s)"

    READY_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    if [ "$READY_COUNT" = "$NODE_COUNT" ]; then
      ok "All ${NODE_COUNT} node(s) Ready"
    else
      warn "${READY_COUNT}/${NODE_COUNT} nodes Ready — some nodes may be NotReady"
    fi
  else
    warn "Cluster not reachable via ${KUBECONFIG_PATH} (may require VPN / cluster may be down)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}${PASS} passed${NC} · ${YELLOW}${WARN} warnings${NC} · ${RED}${FAIL} failed${NC}"
echo "═══════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "❌ Pre-flight FAILED — fix the issues above before running tofu apply"
  echo "   Re-run with --fix for fix instructions"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "⚠️  Pre-flight passed with warnings — review above before proceeding"
  exit 0
else
  echo ""
  echo "✅ Pre-flight PASSED — safe to run tofu apply"
  exit 0
fi
