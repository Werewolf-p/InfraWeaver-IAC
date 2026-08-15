#!/usr/bin/env bash
# Build and push the agent-shell image, then print the tag to pin in the
# manifests under kubernetes/platform/agent/manifests/.
#
# ⚠️ DOCKER_BUILDKIT=0 IS LOAD-BEARING, NOT LEGACY CRUFT.
# This host runs dockerd with the containerd snapshotter, so BuildKit emits an
# OCI image index plus an attestation manifest. Zot (registry.int) rejects both,
# measured 2026-08-15:
#
#     buildkit default          -> error from registry: provided digest did not
#                                  match uploaded content
#     buildkit --provenance=false --sbom=false
#                               -> error from registry: manifest invalid
#     DOCKER_BUILDKIT=0         -> pushes clean
#
# The legacy builder produces a Docker v2 schema2 manifest, which is what this
# registry accepts. ~/consoleup-build.sh pins the same flag for the same reason.
set -euo pipefail

REGISTRY="registry.int.example.com"
IMAGE="agent-shell"
TAG="agentshell-$(date -u +%Y%m%d-%H%M%S)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${REGISTRY}/${IMAGE}:${TAG}"

echo "=== [1/3] build ${REF} ==="
DOCKER_BUILDKIT=0 docker build -t "${REF}" "${HERE}"
echo "docker build OK"

# Fail here rather than in a pod at 3am.
echo "=== [2/3] verify ==="
docker run --rm --entrypoint sh "${REF}" -c '
  set -e
  ttyd --version
  echo "ttyd commit: $(cat /usr/local/share/ttyd.commit)"
  tmux -V
  asciinema --version
  test "$(id -u)" = "1000" || { echo "image does not run as uid 1000"; exit 1; }
'
echo "verify OK"

echo "=== [3/3] push ==="
docker push "${REF}"
echo "PUSH OK: ${REF}"
echo
echo "Pin this in kubernetes/platform/agent/manifests/terminal.yaml and"
echo "terminal-admin.yaml, then let ArgoCD roll it:"
echo
echo "    image: ${REF}"
