#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — Wire up Onedev as the authoritative git source for ArgoCD
#
# USAGE:
#   bash scripts/bootstrap.sh [--dry-run]
#
# What this does:
#   1. Regenerates admin-config.yaml from users.yaml (keeps config in sync)
#   2. Deploys Onedev to the cluster (idempotent kubectl apply)
#   3. Runs setup-onedev.sh to create the infraweaver service account + token
#   4. Adds the 'onedev' remote and mirrors the current branch
#   5. Switches the ArgoCD root ApplicationSet source from GitHub to Onedev
#   6. Commits and pushes all changes
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - OpenBao initialized and unsealed (run deploy/bootstrap-openbao.sh first)
#   - VAULT_TOKEN and OPENBAO_ADDR set (or defaults to http://127.0.0.1:8200)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="bootstrap"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

ONEDEV_URL="${ONEDEV_URL:-http://onedev.onedev.svc.cluster.local}"
ONEDEV_EXTERNAL_URL="${ONEDEV_EXTERNAL_URL:-https://onedev.${BASE_DOMAIN}}"
ONEDEV_PROJECT="${ONEDEV_PROJECT:-InfraWeaver-platform}"
ONEDEV_NAMESPACE="${ONEDEV_NAMESPACE:-onedev}"
CONSOLE_NAMESPACE="${CONSOLE_NAMESPACE:-infraweaver-console}"
CONSOLE_DEPLOYMENT="${CONSOLE_DEPLOYMENT:-infraweaver-console}"
APPSET_ROOT="kubernetes/bootstrap/applicationset-root.yaml"

run() {
  if $DRY_RUN; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

require_cmd kubectl git python3

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     InfraWeaver — Onedev Bootstrap                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

$DRY_RUN && warn "DRY RUN — no changes will be made"

# ── 0. Regenerate admin-config.yaml from users.yaml ──────────────────────────
log "Step 0: Regenerating onedev admin-config.yaml from users.yaml..."
if ! $DRY_RUN; then
  bash "$(dirname "${BASH_SOURCE[0]}")/generate-admin-config.sh"
  git_commit_if_changed "chore(onedev): regenerate admin-config.yaml from users.yaml" \
    "kubernetes/catalog/onedev/manifests/admin-config.yaml" \
    || log "admin-config.yaml unchanged"
else
  bash "$(dirname "${BASH_SOURCE[0]}")/generate-admin-config.sh" --check \
    || warn "[dry-run] admin-config.yaml would be updated from users.yaml"
fi

# ── 1. Deploy Onedev ──────────────────────────────────────────────────────────
log "Step 1: Deploy Onedev to cluster..."

ONEDEV_MANIFEST_DIR="kubernetes/catalog/onedev/manifests"
if [[ -d "$ONEDEV_MANIFEST_DIR" ]]; then
  # Create namespace first (needed for secrets below)
  run kubectl create namespace "$ONEDEV_NAMESPACE" --dry-run=client -o yaml \
    | kubectl apply -f -

  # Pre-create onedev-admin-secret directly from OpenBao
  # (ExternalSecrets CRDs may not be installed yet on first deploy)
  if [[ -n "${VAULT_TOKEN:-}" ]] && ! $DRY_RUN; then
    _BAO_ADDR="${OPENBAO_ADDR:-}"
    _BAO_PF=""
    # Open a fresh port-forward to OpenBao if needed (test reachability first)
    if [[ -z "$_BAO_ADDR" ]] || echo "$_BAO_ADDR" | grep -q "svc.cluster.local" || \
       ! curl -s --connect-timeout 2 "$_BAO_ADDR/v1/sys/health" &>/dev/null; then
      _BAO_POD=$(kubectl get pod -n openbao -l app.kubernetes.io/name=openbao \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1 || true)
      if [[ -n "$_BAO_POD" ]]; then
        kubectl port-forward -n openbao "pod/${_BAO_POD}" 19200:8200 &
        _BAO_PF=$!
        sleep 3
        _BAO_ADDR="http://127.0.0.1:19200"
      fi
    fi

    _ONEDEV_ADMIN_PASS=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
      "${_BAO_ADDR}/v1/secret/data/platform/onedev" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('admin-password',''))" \
      2>/dev/null || echo "")
    _ONEDEV_ADMIN_EMAIL=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
      "${_BAO_ADDR}/v1/secret/data/platform/onedev" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('admin-email','admin@infraweaver.local'))" \
      2>/dev/null || echo "admin@infraweaver.local")

    [[ -n "$_BAO_PF" ]] && { kill "$_BAO_PF" 2>/dev/null || true; wait "$_BAO_PF" 2>/dev/null || true; }

    if [[ -n "$_ONEDEV_ADMIN_PASS" ]]; then
      kubectl create secret generic onedev-admin-secret \
        -n "$ONEDEV_NAMESPACE" \
        --from-literal=admin-login="admin" \
        --from-literal=admin-password="$_ONEDEV_ADMIN_PASS" \
        --from-literal=admin-email="$_ONEDEV_ADMIN_EMAIL" \
        --dry-run=client -o yaml | kubectl apply -f -
      log "onedev-admin-secret created/updated from OpenBao"
    else
      warn "Could not read onedev admin password from OpenBao — Onedev may not start correctly"
    fi
  fi

  # Apply core manifests — split multi-doc files to skip CRD-dependent resources
  # (ExternalSecret, IngressRoute, VaultAuth depend on CRDs installed by ArgoCD later)
  for _MFILE in "$ONEDEV_MANIFEST_DIR"/*.yaml; do
    _MNAME=$(basename "$_MFILE")
    if grep -q "ExternalSecret\|IngressRoute\|VaultAuth" "$_MFILE" 2>/dev/null; then
      log "Filtering $_MNAME — applying only core k8s types (skipping ExternalSecret/IngressRoute)..."
      # Extract individual YAML docs, skip those with CRD-dependent kinds
      python3 - "$_MFILE" << 'PYEOF' | kubectl apply --server-side -f - 2>/dev/null \
        || warn "Partial apply of $_MNAME had issues"
import sys, re

path = sys.argv[1]
content = open(path).read()
skip_kinds = {'ExternalSecret', 'IngressRoute', 'VaultAuth', 'ClusterSecretStore'}
docs = [d for d in re.split(r'^---\s*$', content, flags=re.MULTILINE) if d.strip()]
for doc in docs:
    m = re.search(r'^\s*kind:\s*(\S+)', doc, re.MULTILINE)
    if m and m.group(1) in skip_kinds:
        continue
    if doc.strip():
        print('---')
        print(doc)
PYEOF
    else
      run kubectl apply -f "$_MFILE" --server-side || warn "Failed to apply $_MNAME"
    fi
  done
  ok "Onedev core manifests applied"

  # Wait for Onedev to be ready (best-effort)
  if ! $DRY_RUN; then
    log "Waiting for Onedev pod to be ready (up to 5 min)..."
    kubectl wait --for=condition=ready pod \
      -l app.kubernetes.io/name=onedev \
      -n "$ONEDEV_NAMESPACE" \
      --timeout=300s 2>/dev/null \
      || warn "Onedev pod not ready yet — continuing anyway"
  fi
else
  warn "No manifests found at $ONEDEV_MANIFEST_DIR — skipping Onedev deployment"
  warn "Apply Onedev manually before running this script, or create $ONEDEV_MANIFEST_DIR"
fi

# ── 1b. Create infraweaver service account + access token ────────────────────
log "Step 1b: Setting up infraweaver service account in Onedev..."
if ! $DRY_RUN; then
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    # Create a fresh OpenBao port-forward for setup-onedev.sh
    _SETUP_BAO_ADDR=""
    _SETUP_BAO_PF=""
    _SETUP_BAO_POD=$(kubectl get pod -n openbao -l app.kubernetes.io/name=openbao \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1 || true)
    if [[ -n "$_SETUP_BAO_POD" ]]; then
      kubectl port-forward -n openbao "pod/${_SETUP_BAO_POD}" 19201:8200 &
      _SETUP_BAO_PF=$!
      sleep 3
      _SETUP_BAO_ADDR="http://127.0.0.1:19201"
    fi

    ENV_NAME="${ENV_NAME:-productie}" \
    OPENBAO_ADDR="${_SETUP_BAO_ADDR:-http://127.0.0.1:8200}" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    bash "$(dirname "${BASH_SOURCE[0]}")/setup-onedev.sh" \
      || warn "setup-onedev.sh failed — Onedev token may need to be set manually"

    [[ -n "$_SETUP_BAO_PF" ]] && { kill "$_SETUP_BAO_PF" 2>/dev/null || true; wait "$_SETUP_BAO_PF" 2>/dev/null || true; }
  else
    warn "VAULT_TOKEN not set — skipping setup-onedev.sh (run manually: VAULT_TOKEN=... bash scripts/setup-onedev.sh)"
  fi
else
  log "[dry-run] Would run setup-onedev.sh to create infraweaver service account"
fi

# Read the Onedev infraweaver token from OpenBao (needed for git push auth)
ONEDEV_TOKEN=""
if [[ -n "${VAULT_TOKEN:-}" ]]; then
  _TOKEN_BAO_ADDR=""
  _TOKEN_BAO_PF=""
  _TOKEN_BAO_POD=$(kubectl get pod -n openbao -l app.kubernetes.io/name=openbao \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1 || true)
  if [[ -n "$_TOKEN_BAO_POD" ]]; then
    kubectl port-forward -n openbao "pod/${_TOKEN_BAO_POD}" 19202:8200 &
    _TOKEN_BAO_PF=$!
    sleep 3
    ONEDEV_TOKEN=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
      "http://127.0.0.1:19202/v1/secret/data/platform/infraweaver-console" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('data',{}).get('onedev-token',''))" \
      2>/dev/null || echo "")
    [[ -n "$_TOKEN_BAO_PF" ]] && { kill "$_TOKEN_BAO_PF" 2>/dev/null || true; wait "$_TOKEN_BAO_PF" 2>/dev/null || true; }
  fi
fi

# ── 2. Mirror repo to Onedev ──────────────────────────────────────────────────
log "Step 2: Mirror repository to Onedev..."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Current branch: $CURRENT_BRANCH"

# Use port-forward to Onedev for git push (external DNS may not be ready yet)
_ONEDEV_PF=""
_ONEDEV_LOCAL_URL=""
# Wait for onedev service before attempting git push (it may still be deploying)
_OD_SVC_WAIT=0
until kubectl get svc onedev -n "$ONEDEV_NAMESPACE" &>/dev/null; do
  _OD_SVC_WAIT=$((_OD_SVC_WAIT + 1))
  [[ $_OD_SVC_WAIT -ge 18 ]] && break
  log "  Waiting for onedev service (${_OD_SVC_WAIT}/18)..."
  sleep 10
done
_ONEDEV_SVC=$(kubectl get svc onedev -n "$ONEDEV_NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$_ONEDEV_SVC" ]]; then
  kubectl port-forward svc/onedev 19300:80 -n "$ONEDEV_NAMESPACE" &
  _ONEDEV_PF=$!
  sleep 3
  if [[ -n "$ONEDEV_TOKEN" ]]; then
    _ONEDEV_LOCAL_URL="http://infraweaver:${ONEDEV_TOKEN}@localhost:19300/${ONEDEV_PROJECT}"
  else
    _ONEDEV_LOCAL_URL="http://localhost:19300/${ONEDEV_PROJECT}"
  fi
fi

# Set/update the remote to use local port-forward for initial push
if git remote | grep -q "^onedev$"; then
  if [[ -n "$_ONEDEV_LOCAL_URL" ]]; then
    run git remote set-url onedev "$_ONEDEV_LOCAL_URL"
  fi
else
  ONEDEV_REMOTE_URL="${_ONEDEV_LOCAL_URL:-${ONEDEV_EXTERNAL_URL}/${ONEDEV_PROJECT}}"
  run git remote add onedev "$ONEDEV_REMOTE_URL"
  ok "Added remote 'onedev' → $ONEDEV_REMOTE_URL"
fi

# Unshallow the clone so Onedev doesn't reject the push with "shallow update not allowed"
if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
  log "  Unshallowing repository (required for Onedev push)..."
  run git fetch --unshallow origin 2>/dev/null || run git fetch --unshallow 2>/dev/null || \
    warn "  Could not unshallow — push may fail"
fi

# Commit all substituted files (generate-from-env.sh changes) before pushing
log "  Committing any env-substituted files before push..."
if ! $DRY_RUN; then
  git config user.email "deploy@infraweaver.local" 2>/dev/null || true
  git config user.name "InfraWeaver Deploy" 2>/dev/null || true
  if ! git diff --quiet || ! git diff --cached --quiet; then
    # Stage all modified tracked files (excluding generated secrets)
    git add -A -- ':!envs/*/generated/'
    git diff --cached --quiet || \
      git commit -m "chore: apply generate-from-env.sh substitutions [skip ci]" 2>/dev/null || true
    ok "  Committed env-substituted files"
  else
    log "  No uncommitted changes to commit"
  fi
fi

run git push onedev "$CURRENT_BRANCH":main --force 2>&1 | grep -v "^remote:" | head -10 \
  || run git push onedev "$CURRENT_BRANCH":main 2>&1 | grep -v "^remote:" | head -10 \
  || warn "git push to Onedev failed — repo mirroring may need manual completion"
ok "Branch '$CURRENT_BRANCH' pushed to Onedev as 'main'"

[[ -n "$_ONEDEV_PF" ]] && { kill "$_ONEDEV_PF" 2>/dev/null || true; wait "$_ONEDEV_PF" 2>/dev/null || true; }

# Update remote to external URL (for future pushes after DNS is working)
if git remote | grep -q "^onedev$" && [[ -n "${ONEDEV_TOKEN:-}" ]]; then
  _EXT_URL="${ONEDEV_EXTERNAL_URL}/${ONEDEV_PROJECT}"
  PROTO="${_EXT_URL%%://*}"; REST="${_EXT_URL#*://}"
  run git remote set-url onedev "${PROTO}://infraweaver:${ONEDEV_TOKEN}@${REST}" \
    && log "Remote 'onedev' updated to external URL with auth token"
fi

# ── 3b. Create ArgoCD repo creds secret directly (bypass ESO chicken-and-egg) ─
# ExternalSecret for this lives in kubernetes/core/argocd/manifests/onedev-repo-creds.yaml
# but ESO itself is deployed by ArgoCD — so we must seed the secret directly first.
if [[ -n "${ONEDEV_TOKEN:-}" ]]; then
  log "Step 3b: Seeding ArgoCD repo credentials secret for Onedev..."
  if ! $DRY_RUN; then
    kubectl create secret generic argocd-onedev-repo-creds \
      --namespace argocd \
      --from-literal=type=git \
      --from-literal=url="http://onedev.${ONEDEV_NAMESPACE}.svc.cluster.local/${ONEDEV_PROJECT}" \
      --from-literal=username=infraweaver \
      --from-literal=password="${ONEDEV_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    kubectl label secret argocd-onedev-repo-creds -n argocd \
      argocd.argoproj.io/secret-type=repository --overwrite 2>/dev/null || true
    ok "ArgoCD repo creds seeded (argocd-onedev-repo-creds)"
  else
    log "[dry-run] Would create argocd-onedev-repo-creds secret in argocd namespace"
  fi
else
  warn "No ONEDEV_TOKEN — skipping ArgoCD repo creds seed (run setup-onedev.sh first)"
fi

# OneDev is no longer the ArgoCD GitOps source — GitHub (var.git_repo_url = the
# InfraWeaver-infra repo) is authoritative. The OneDev source-switch steps below
# are kept for reference but DISABLED by default. Set ENABLE_ONEDEV_SOURCE=true
# only to intentionally revert ArgoCD's source back to OneDev.
ENABLE_ONEDEV_SOURCE="${ENABLE_ONEDEV_SOURCE:-false}"

if [[ "$ENABLE_ONEDEV_SOURCE" == "true" ]]; then
log "Step 3: Update ALL ApplicationSet files repoURL to Onedev..."

ONEDEV_CLUSTER_URL="${ONEDEV_URL}/${ONEDEV_PROJECT}"

# Update all appset files - root + core group files
_APPSET_FILES=()
for _f in "$APPSET_ROOT" \
          "kubernetes/bootstrap/appset-core.yaml" \
          "kubernetes/bootstrap/appset-core-platform.yaml" \
          "kubernetes/bootstrap/appset-core-monitoring.yaml"; do
  [[ -f "$_f" ]] && _APPSET_FILES+=("$_f")
done

if [[ ${#_APPSET_FILES[@]} -eq 0 ]]; then
  warn "No ApplicationSet files found -- skipping repoURL patch"
else
  if ! $DRY_RUN; then
    for _af in "${_APPSET_FILES[@]}"; do
      if grep -q "onedev" "$_af" 2>/dev/null; then
        ok "  $_af already references Onedev"
      else
        sed -i "s|repoURL: https://github[.]com/[^ ]*|repoURL: ${ONEDEV_CLUSTER_URL}|g" "$_af" \
          && ok "  Updated repoURL in $_af" \
          || warn "  Could not update $_af"
      fi
    done
  else
    log "[dry-run] Would replace GitHub repoURL in appset files with $ONEDEV_CLUSTER_URL"
  fi
  ok "ApplicationSet files patched to Onedev"
fi
else
  ok "Step 3 skipped — ArgoCD source is GitHub (var.git_repo_url); OneDev disconnected as source."
fi

# ── 4. Patch console Deployment env vars ─────────────────────────────────────
log "Step 4: Patch console Deployment for GIT_PROVIDER=onedev..."

CONSOLE_DEPLOYMENT_FILE="kubernetes/catalog/infraweaver-console/manifests/deployment.yaml"
if [[ -f "$CONSOLE_DEPLOYMENT_FILE" ]]; then
  if grep -q "GIT_PROVIDER.*onedev" "$CONSOLE_DEPLOYMENT_FILE" 2>/dev/null; then
    ok "GIT_PROVIDER=onedev already set in $CONSOLE_DEPLOYMENT_FILE"
  else
    if ! $DRY_RUN; then
      python3 - <<PYEOF
import re

path = '${CONSOLE_DEPLOYMENT_FILE}'
with open(path) as f:
    content = f.read()

# Replace GIT_PROVIDER: github with GIT_PROVIDER: onedev
updated = re.sub(
    r'(name:\s*GIT_PROVIDER\s*\n\s*value:\s*)github',
    r'\g<1>onedev',
    content,
)
with open(path, 'w') as f:
    f.write(updated)
print('Patched GIT_PROVIDER in ' + path)
PYEOF
    else
      log "[dry-run] Would set GIT_PROVIDER=onedev in $CONSOLE_DEPLOYMENT_FILE"
    fi
    ok "Console Deployment patched"
  fi
else
  warn "$CONSOLE_DEPLOYMENT_FILE not found — skipping Deployment patch"
fi

# ── 5. Commit and push changes ────────────────────────────────────────────────
log "Step 5: Commit bootstrap changes..."

if ! $DRY_RUN; then
  git_commit_if_changed "chore(bootstrap): switch ArgoCD + console to Onedev git source" \
    "$APPSET_ROOT" "$CONSOLE_DEPLOYMENT_FILE" \
    "kubernetes/bootstrap/appset-core.yaml" \
    "kubernetes/bootstrap/appset-core-platform.yaml" \
    "kubernetes/bootstrap/appset-core-monitoring.yaml" \
    || log "No file changes to commit (already up to date)"

  # Open port-forward to Onedev for second push
  _ONEDEV_PF2=""
  _ONEDEV_LOCAL_URL2=""
  if [[ -n "${ONEDEV_TOKEN:-}" ]]; then
    _ONEDEV_SVC2=$(kubectl get svc onedev -n "$ONEDEV_NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$_ONEDEV_SVC2" ]]; then
      kubectl port-forward svc/onedev 19301:80 -n "$ONEDEV_NAMESPACE" &>/dev/null &
      _ONEDEV_PF2=$!; sleep 4
      _ONEDEV_LOCAL_URL2="http://infraweaver:${ONEDEV_TOKEN}@localhost:19301/${ONEDEV_PROJECT}"
      git remote set-url onedev "$_ONEDEV_LOCAL_URL2" 2>/dev/null || true
    fi
  fi

  # Push to Onedev (primary)
  git push onedev "$CURRENT_BRANCH":main --force 2>/dev/null || warn "Push to onedev failed — push manually"
  # Push to in-cluster origin (Onedev via NodePort)
  git push origin "$CURRENT_BRANCH" 2>/dev/null || warn "Push to origin failed — push manually"
  # Push to GitHub (some ArgoCD apps source from github remote)
  git push github "$CURRENT_BRANCH":main 2>/dev/null || warn "Push to GitHub failed — push manually"

  [[ -n "$_ONEDEV_PF2" ]] && { kill "$_ONEDEV_PF2" 2>/dev/null || true; wait "$_ONEDEV_PF2" 2>/dev/null || true; }
fi

# ── 5b. Patch the platform Kubernetes ApplicationSet to use Onedev ──────────
# The Terraform-created 'platform' ApplicationSet uses the GitHub URL from
# terraform.tfvars. After Onedev is bootstrapped we must patch it so all
# ArgoCD Applications it manages use Onedev instead of GitHub.
log "Step 5b: Patching 'platform' ApplicationSet in Kubernetes to use Onedev..."
if ! $DRY_RUN; then
  ONEDEV_CLUSTER_URL="${ONEDEV_URL}/${ONEDEV_PROJECT}"
  if [[ "$ENABLE_ONEDEV_SOURCE" == "true" ]]; then
  # Patch the generator repoURL
  kubectl patch applicationset platform -n argocd --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/generators/0/git/repoURL\",\"value\":\"${ONEDEV_CLUSTER_URL}\"},{\"op\":\"replace\",\"path\":\"/spec/generators/0/git/revision\",\"value\":\"HEAD\"}]" \
    2>/dev/null && ok "  platform ApplicationSet generator patched to Onedev" || \
    warn "  Could not patch platform ApplicationSet generator (may not exist yet)"
  # Patch the template source repoURL
  kubectl patch applicationset platform -n argocd --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/source/repoURL\",\"value\":\"${ONEDEV_CLUSTER_URL}\"},{\"op\":\"replace\",\"path\":\"/spec/template/spec/source/targetRevision\",\"value\":\"HEAD\"}]" \
    2>/dev/null && ok "  platform ApplicationSet template patched to Onedev" || \
    warn "  Could not patch platform ApplicationSet template (may not exist yet)"
  else
    ok "  platform ApplicationSet left on GitHub (var.git_repo_url) — OneDev source patch skipped."
  fi

  # Re-apply updated bootstrap YAMLs directly so ApplicationSets pick up Onedev URL
  log "  Applying updated bootstrap ApplicationSet manifests..."
  for f in kubernetes/bootstrap/appset-core.yaml kubernetes/bootstrap/appset-core-platform.yaml \
            kubernetes/bootstrap/appset-core-monitoring.yaml \
            kubernetes/bootstrap/applicationset-root.yaml; do
    [[ -f "$f" ]] && kubectl apply -f "$f" 2>/dev/null && log "  Applied $f" || warn "  Could not apply $f"
  done
  # Wait for AppSet controller to reconcile generated Applications
  log "  Waiting for AppSet controller to reconcile..."
  sleep 10
  kubectl annotate applications -n argocd --all \
    "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null || true

  # Hard refresh ArgoCD apps to pick up new source URL
  log "  Refreshing all ArgoCD applications..."
  kubectl annotate applications -n argocd --all \
    "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null || true
  ok "ArgoCD applications refreshed"
else
  log "[dry-run] Would patch 'platform' ApplicationSet and apply bootstrap YAMLs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Bootstrap complete                               ║"
echo "╚══════════════════════════════════════════════════════╝"
ok "admin-config.yaml regenerated from users.yaml"
ok "Onedev deployed (or already running)"
ok "infraweaver service account created with access token"
ok "Repo mirrored to Onedev remote"
ok "ArgoCD ApplicationSet points to Onedev"
echo ""
log "Verify Onedev is accessible at $ONEDEV_EXTERNAL_URL"
log "Trigger ArgoCD hard-refresh if needed: argocd app sync --hard-refresh bootstrap"
echo ""
