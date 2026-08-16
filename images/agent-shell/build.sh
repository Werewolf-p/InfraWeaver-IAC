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
#
# ⚠️ `ttyd --version` IS NOT ENOUGH AND NEVER WAS. It parses argv and exits
# before libwebsockets builds its context, so it passed happily on the image
# published 2026-08-15 whose ttyd could not start at ALL (the runtime stage was
# missing libwebsockets-evlib-uv; see the Dockerfile). The verify below BINDS A
# PORT and makes a real request, which is the smallest check that catches it.
# Do not weaken it back to a version print.
echo "=== [2/3] verify ==="
docker run --rm --entrypoint sh "${REF}" -c '
  set -e
  ttyd --version
  echo "ttyd commit: $(cat /usr/local/share/ttyd.commit)"
  tmux -V
  asciinema --version
  command -v vim >/dev/null || { echo "no vim in image"; exit 1; }
  command -v nano >/dev/null || { echo "no nano in image"; exit 1; }
  test "$(id -u)" = "1000" || { echo "image does not run as uid 1000"; exit 1; }
  # Real start: this is the check that would have caught the evlib_uv gap.
  /usr/local/bin/ttyd -p 7699 -i 127.0.0.1 true &
  TP=$!
  i=0
  while [ $i -lt 20 ]; do curl -fsS -o /dev/null http://127.0.0.1:7699/ && break; i=$((i+1)); sleep 0.5; done
  curl -fsS -o /dev/null http://127.0.0.1:7699/ || { echo "ttyd did not serve a request"; exit 1; }
  kill $TP
  echo "ttyd smoke test OK (served 127.0.0.1:7699)"
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
