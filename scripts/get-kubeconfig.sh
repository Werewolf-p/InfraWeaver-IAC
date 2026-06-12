#!/usr/bin/env bash
# =============================================================================
# scripts/get-kubeconfig.sh
#
# Exports the kubeconfig for a Talos cluster from OpenTofu state.
#
# Usage:
#   ./scripts/get-kubeconfig.sh ontwikkel              # prints to stdout
#   ./scripts/get-kubeconfig.sh productie              # prints to stdout
#   ./scripts/get-kubeconfig.sh ontwikkel merge        # merges into ~/.kube/config
#   ./scripts/get-kubeconfig.sh ontwikkel /some/path   # writes to custom path
#
# Prerequisites:
#   - tofu       in PATH
#   - sops       in PATH (for secrets)
#   - kubectl    in PATH (for merge mode)
#   - SOPS_AGE_KEY_FILE set, or age key reachable via default sops config
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/terraform"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ENVIRONMENT="${1:-}"
OUTPUT_MODE="${2:-stdout}"  # stdout | merge | <file-path>

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $0 <environment> [stdout|merge|/path/to/kubeconfig]"
  echo "  environment: ontwikkel | productie"
  echo "  output:      stdout (default) | merge | /custom/path"
  exit 1
fi

if [[ "$ENVIRONMENT" != "ontwikkel" && "$ENVIRONMENT" != "productie" ]]; then
  echo "ERROR: environment must be 'ontwikkel' or 'productie'" >&2
  exit 1
fi

ENV_DIR="$REPO_ROOT/envs/$ENVIRONMENT"
BACKEND_HCL="$ENV_DIR/backend.hcl"
GENERATED_DIR="$ENV_DIR/generated"
GENERATED_KUBECONFIG="$GENERATED_DIR/kubeconfig"

# ---------------------------------------------------------------------------
# Fast path: use pre-written generated kubeconfig if it exists
# ---------------------------------------------------------------------------
if [[ -f "$GENERATED_KUBECONFIG" ]]; then
  echo "==> Using pre-written kubeconfig from $GENERATED_KUBECONFIG" >&2
  KUBECONFIG_CONTENT="$(cat "$GENERATED_KUBECONFIG")"
else
  echo "==> Generated kubeconfig not found; extracting from Terraform state..." >&2

  # Ensure state dir exists
  STATE_PATH=$(grep '^path' "$BACKEND_HCL" | awk '{print $3}' | tr -d '"')
  STATE_DIR="$(dirname "$(eval echo "$STATE_PATH")")"
  mkdir -p "$STATE_DIR"

  # Load secrets so tofu can authenticate
  SECRETS_FILE="$ENV_DIR/secrets.sops.yaml"
  if [[ -f "$SECRETS_FILE" ]]; then
    echo "==> Decrypting secrets via SOPS..." >&2
    # shellcheck disable=SC2046
    export $(sops --decrypt --output-type dotenv "$SECRETS_FILE" | grep -v '^#' | xargs)
  else
    echo "WARN: $SECRETS_FILE not found; assuming env vars are already set." >&2
  fi

  # Re-initialize to pick up the backend config (safe to run multiple times)
  (cd "$TERRAFORM_DIR" && \
    tofu init -backend-config="$BACKEND_HCL" -reconfigure -input=false \
      >/dev/null 2>&1) \
  || { echo "ERROR: tofu init failed" >&2; exit 1; }

  # Extract kubeconfig from state output (sensitive output requires -raw)
  KUBECONFIG_CONTENT=$(
    cd "$TERRAFORM_DIR" && \
    tofu output \
      -state="$(eval echo "$STATE_PATH")" \
      -raw kubeconfig 2>/dev/null
  ) || {
    echo "ERROR: Could not read 'kubeconfig' output from Terraform state." >&2
    echo "       Run: tofu apply -target=module.talos_cluster first." >&2
    exit 1
  }

  if [[ -z "$KUBECONFIG_CONTENT" ]]; then
    echo "ERROR: kubeconfig output is empty. Is the cluster deployed?" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Output modes
# ---------------------------------------------------------------------------
case "$OUTPUT_MODE" in

  stdout)
    echo "$KUBECONFIG_CONTENT"
    ;;

  merge)
    echo "==> Merging kubeconfig into ~/.kube/config..." >&2
    mkdir -p ~/.kube

    # Write to a temp file for merging
    TMPFILE=$(mktemp)
    trap 'rm -f "$TMPFILE"' EXIT
    echo "$KUBECONFIG_CONTENT" > "$TMPFILE"
    chmod 0600 "$TMPFILE"

    # Use kubectl config merge
    if KUBECONFIG="$TMPFILE:${HOME}/.kube/config" kubectl config view \
        --flatten > "${HOME}/.kube/config.tmp" 2>/dev/null; then
      mv "${HOME}/.kube/config.tmp" "${HOME}/.kube/config"
      chmod 0600 "${HOME}/.kube/config"
      echo "==> Merged. Active context:"
      kubectl config current-context
    else
      echo "ERROR: kubectl config merge failed." >&2
      rm -f "${HOME}/.kube/config.tmp"
      exit 1
    fi
    ;;

  /*)
    # Absolute path — write directly
    OUTPUT_FILE="$OUTPUT_MODE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    echo "$KUBECONFIG_CONTENT" > "$OUTPUT_FILE"
    chmod 0600 "$OUTPUT_FILE"
    echo "==> Kubeconfig written to $OUTPUT_FILE" >&2
    ;;

  *)
    echo "ERROR: Unknown output mode '$OUTPUT_MODE'." >&2
    echo "       Use: stdout | merge | /absolute/path" >&2
    exit 1
    ;;

esac
