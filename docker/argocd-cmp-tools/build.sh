#!/usr/bin/env bash
# build.sh — build & push the argocd-cmp-tools sidecar image to ghcr.io.
# (design: docs/gitops-cmp-substitution.md §5.1)
#
# Apps build externally to ghcr.io (no in-cluster CI). Run on a host with docker
# + a ghcr.io login (gh auth token works: `gh auth token | docker login ghcr.io
# -u <user> --password-stdin`).
#
#   docker/argocd-cmp-tools/build.sh [--push]
#
# ARGOCD_VERSION is auto-detected from the deployed argo-cd chart appVersion when
# helm is available, so the sidecar's argocd image matches the repo-server.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-ghcr.io/werewolf-p/argocd-cmp-envsubst}"
TAG="${TAG:-latest}"
CHART_VERSION="${CHART_VERSION:-9.5.*}"

# Resolve the argocd appVersion that chart 9.5.* deploys, so the image lines up.
ARGOCD_VERSION="${ARGOCD_VERSION:-}"
if [[ -z "$ARGOCD_VERSION" ]] && command -v helm >/dev/null 2>&1; then
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null 2>&1 || true
  ARGOCD_VERSION="$(helm show chart argo/argo-cd --version "$CHART_VERSION" 2>/dev/null \
    | awk '/^appVersion:/ {gsub(/"/,"",$2); print $2}')"
fi
if [[ -z "$ARGOCD_VERSION" ]]; then
  echo "==> could not auto-detect appVersion; using Dockerfile default" >&2
  BUILD_ARG=()
else
  [[ "$ARGOCD_VERSION" == v* ]] || ARGOCD_VERSION="v${ARGOCD_VERSION}"
  echo "==> argo-cd chart $CHART_VERSION -> argocd $ARGOCD_VERSION"
  BUILD_ARG=(--build-arg "ARGOCD_VERSION=${ARGOCD_VERSION}")
fi

echo "==> building ${IMAGE}:${TAG}"
docker build "${BUILD_ARG[@]}" -t "${IMAGE}:${TAG}" "$HERE"

# Sanity-check the built image actually carries the intended argocd version, so a
# bad base never gets pinned silently.
BUILT_VERSION="$(docker run --rm --entrypoint argocd "${IMAGE}:${TAG}" version --client --short 2>/dev/null | awk '{print $2}')"
echo "==> built image reports argocd ${BUILT_VERSION:-<unknown>}"

if [[ "${1:-}" == "--push" ]]; then
  echo "==> pushing ${IMAGE}:${TAG}"
  docker push "${IMAGE}:${TAG}"
  # Emit the published digest so the pin in values.yaml can never drift from what
  # was actually pushed (a stale/unpublished pin breaks the repo-server sidecar pull).
  DIGEST="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE}:${TAG}" \
    | grep -F "${IMAGE}@" | head -1)"
  echo "==> pushed. Pin this digest in core/argocd/values.yaml repoServer.extraContainers:"
  echo "    image: ${DIGEST:-${IMAGE}:${TAG} (digest unavailable — run: docker inspect --format '{{index .RepoDigests 0}}' ${IMAGE}:${TAG})}"
else
  LOCAL_ID="$(docker inspect --format '{{.Id}}' "${IMAGE}:${TAG}" 2>/dev/null)"
  echo "==> built (not pushed; local id ${LOCAL_ID}). Re-run with --push to publish to ghcr.io."
fi
