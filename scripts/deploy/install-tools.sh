#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy/install-tools.sh — Install required toolchain: tofu, talosctl, kubectl, helm, sops, age
#
# Usage: ENV_NAME=productie bash scripts/deploy/install-tools.sh
# Called by: .github/workflows/full-redeploy.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${ENV_NAME:?Usage: ENV_NAME=productie bash $0}"
if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
  sudo dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none || true
  sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null 2>&1 || true
  sudo swapon /swapfile 2>/dev/null || true
fi
command -v tofu || (
  TOFU_VER=1.8.5
  cd /tmp
  curl -fsSL -O "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VER}/tofu_${TOFU_VER}_linux_amd64.tar.gz"
  curl -fsSL -O "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VER}/tofu_${TOFU_VER}_SHA256SUMS"
  sha256sum --ignore-missing -c "tofu_${TOFU_VER}_SHA256SUMS"
  sudo tar -xzf "tofu_${TOFU_VER}_linux_amd64.tar.gz" -C /usr/local/bin/ tofu
  sudo chmod +x /usr/local/bin/tofu
)
command -v sops || (sudo curl -fsSL -o /usr/local/bin/sops \
  https://github.com/getsops/sops/releases/download/v3.10.2/sops-v3.10.2.linux.amd64 && \
  sudo chmod +x /usr/local/bin/sops)
command -v age || (curl -fsSL -o /tmp/age.tar.gz \
  https://github.com/FiloSottile/age/releases/download/v1.1.1/age-v1.1.1-linux-amd64.tar.gz && \
  sudo tar -xzf /tmp/age.tar.gz -C /usr/local/bin/ --strip-components=1 age/age age/age-keygen)
command -v helm || (
  HELM_VER=v3.16.3
  cd /tmp
  curl -fsSL -O "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"
  curl -fsSL -o "helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum" \
    "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum"
  echo "$(awk '{print $1}' "helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum")  helm-${HELM_VER}-linux-amd64.tar.gz" | sha256sum -c -
  sudo tar -xzf "helm-${HELM_VER}-linux-amd64.tar.gz" -C /usr/local/bin/ --strip-components=1 linux-amd64/helm
)
# talosctl: download from GitHub releases first (no Docker Hub needed).
# If binary fails to execute (AMD64 v2 CPU feature issue), build from source via Go (not Docker).
if ! talosctl version --client >/dev/null 2>&1; then
  TALOS_VER=$(grep 'talos_version' envs/$ENV_NAME/cluster.yaml | awk '{print $2}' | tr -d '"')
  echo "Downloading talosctl ${TALOS_VER} from GitHub releases..."
  sudo curl -fsSL -o /usr/local/bin/talosctl \
    "https://github.com/siderolabs/talos/releases/download/${TALOS_VER}/talosctl-linux-amd64"
  sudo chmod +x /usr/local/bin/talosctl
  if ! talosctl version --client >/dev/null 2>&1; then
    echo "talosctl binary not functional (AMD64 v2 issue). Building with GOAMD64=v1 via Go..."
    command -v go || (
      GO_VER=1.22.3
      curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
      sudo tar -C /usr/local -xzf /tmp/go.tar.gz
      export PATH=$PATH:/usr/local/go/bin
    )
    export PATH=$PATH:/usr/local/go/bin
    git clone --depth=1 --branch ${TALOS_VER} https://github.com/siderolabs/talos.git /tmp/talos-src 2>&1 | tail -3
    cd /tmp/talos-src && GOAMD64=v1 go build -o /usr/local/bin/talosctl ./cmd/talosctl/
    sudo chmod +x /usr/local/bin/talosctl
    cd -
  fi
fi
talosctl version --client
command -v kubectl || (K8S_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
  sudo curl -fsSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl" && \
  sudo chmod +x /usr/local/bin/kubectl)
mkdir -p ~/.terraform.d/plugin-cache
echo 'plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"' > ~/.tofurc
tofu version

