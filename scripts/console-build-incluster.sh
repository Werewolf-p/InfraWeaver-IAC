#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Build and push the InfraWeaver console image FROM THE IN-CLUSTER ADMIN SHELL.
#
# This is the replacement for /home/runner/consoleup-build.sh on the operator VM.
# It is the one thing the shell could not do, and the reason the VM still existed.
#
# WHERE EACH HALF OF THE BUILD RUNS, AND WHY THE SPLIT IS WHERE IT IS
#
#   HERE (agent-admin pod)          THERE (build/buildkitd)
#   ─────────────────────           ───────────────────────
#   git clone                       docker build (Dockerfile.prebuilt)
#   npm ci            ← internet    push to Zot
#   next build        ← 4GB heap    apk add git  ← ONE allowed FQDN
#   crane mirror base ← internet
#
#   buildkitd is rootful, privileged and UNAUTHENTICATED. Everything that needs
#   the open internet is therefore done on this side of the line, where the pod
#   is unprivileged, non-root and sits behind the Authentik admin gate. buildkitd
#   gets exactly two destinations: the internal registry VIP, and the Alpine
#   package CDN. See kubernetes/core/network-policies/manifests/allowlists.yaml.
#
# USAGE
#   scripts/console-build-incluster.sh [TAG]
#   scripts/console-build-incluster.sh --bump TAG     # rewrite the 4 image pins
#
# The build has a HARD GATE: `npm run build` runs scripts/build-addon-registry.mjs
# as its prebuild step, which refuses to build on a nav-row violation. A failure
# there is CORRECT behaviour — read the message, fix the row, do not work around it.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGISTRY="${REGISTRY:-registry.int.example.com}"
IMAGE_REPO="${IMAGE_REPO:-infraweaver-console}"
BASE_UPSTREAM="${BASE_UPSTREAM:-public.ecr.aws/docker/library/node:20-alpine}"
BASE_MIRROR="${BASE_MIRROR:-$REGISTRY/base/node:20-alpine}"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/example-owner/InfraWeaver-platform.git}"
INFRA_DIR="${INFRA_DIR:-$HOME/InfraWeaver-infra}"
# The PVC behind $HOME is 5Gi; node_modules + .next do not fit. /tmp is an
# emptyDir on the node's disk (541G free on cp1, measured 2026-08-15).
WORK="${WORK:-/tmp/console-build}"
BUILDKIT_HOST="${BUILDKIT_HOST:-tcp://buildkitd.build.svc.cluster.local:1234}"
BASE_DOMAIN="${NEXT_PUBLIC_BASE_DOMAIN:-example.com}"
# 1800MB OOMed after the 2026-08-01 wave; 3400MB OOMed on 2026-08-10. 4096 is the
# setting that works, and it is why this pod carries a 6Gi limit.
NODE_HEAP_MB="${NODE_HEAP_MB:-4096}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "═══ $* ═══"; }

# ── --bump: rewrite the FOUR image pins in the prod overlay ──────────────────
# The tag is pinned in four places (initContainer, console, connector-git-sync,
# backup). Bumping three leaves the backup datastore on the previous build and
# every backup route 404s. The two asserts below are the repo's own documented
# grep checks, generalised to any tag prefix.
bump_overlay() {
  local tag="$1"
  local f="$INFRA_DIR/kubernetes/catalog/infraweaver-console/overlays/prod/kustomization.yaml"
  [ -f "$f" ] || die "overlay not found: $f (set INFRA_DIR)"
  sed -i -E "s|^( +image: ${REGISTRY}/${IMAGE_REPO}:).*$|\1${tag}|" "$f"
  local lines uniq
  lines=$(grep -cE "^ +image: ${REGISTRY}/${IMAGE_REPO}:" "$f" || true)
  uniq=$(grep -oE "^ +image: ${REGISTRY}/${IMAGE_REPO}:.*$" "$f" | sed 's/.*://' | sort -u | wc -l)
  [ "$lines" = "4" ] || die "expected 4 image pins, found $lines — the overlay changed shape"
  [ "$uniq" = "1" ] || die "image pins disagree after bump ($uniq distinct tags)"
  echo "bumped 4/4 image pins to $tag in $f"
}

if [ "${1:-}" = "--bump" ]; then
  [ -n "${2:-}" ] || die "--bump needs a TAG"
  bump_overlay "$2"
  exit 0
fi

TAG="${1:-consoleup-$(date +%Y%m%d-%H%M%S)}"

step "0/6 preflight"
for t in git node npm buildctl crane kubectl; do
  command -v "$t" >/dev/null 2>&1 || die "$t not on PATH (expected in \$HOME/bin — see kubernetes/platform/agent/terminal-admin.yaml)"
done
buildctl --addr "$BUILDKIT_HOST" debug workers >/dev/null \
  || die "cannot reach buildkitd at $BUILDKIT_HOST — check allow-agent-admin-to-buildkitd in allowlists.yaml"
echo "buildkitd reachable; TAG=$TAG"

step "1/6 registry credentials"
# Zot's htpasswd robot credential. Read from the pull Secret the console already
# uses, so there is no second copy of the password to rotate.
mkdir -p "$HOME/.docker"
if ! grep -q "$REGISTRY" "$HOME/.docker/config.json" 2>/dev/null; then
  kubectl get secret registry-pull-secret -n infraweaver-console \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$HOME/.docker/config.json"
  chmod 600 "$HOME/.docker/config.json"
fi
grep -q "$REGISTRY" "$HOME/.docker/config.json" || die "no credentials for $REGISTRY"
echo "credentials present for $REGISTRY"

step "2/6 base image mirror"
# buildkitd has NO route to public.ecr.aws — deliberately. This pod does, so the
# mirror hop happens here and buildkitd only ever resolves a Zot reference.
if crane manifest "$BASE_MIRROR" >/dev/null 2>&1; then
  echo "$BASE_MIRROR already present"
else
  echo "mirroring $BASE_UPSTREAM -> $BASE_MIRROR"
  # ECR Public rate-limits anonymous pulls per source IP and the whole cluster
  # shares one. Retry rather than fail the build on a TOOMANYREQUESTS.
  for i in 1 2 3 4 5; do
    crane copy --platform linux/amd64 "$BASE_UPSTREAM" "$BASE_MIRROR" && break
    [ "$i" = 5 ] && die "base mirror failed after 5 attempts"
    echo "retry $i ..."; sleep 15
  done
fi

step "3/6 source checkout"
mkdir -p "$WORK"
if [ -d "$WORK/platform/.git" ]; then
  git -C "$WORK/platform" fetch --depth 1 origin main
  git -C "$WORK/platform" reset --hard FETCH_HEAD
else
  rm -rf "$WORK/platform"
  git clone --depth 1 "$PLATFORM_REPO" "$WORK/platform"
fi
APP="$WORK/platform/apps/infraweaver-console"
[ -d "$APP" ] || die "console source not found at $APP"
echo "HEAD: $(git -C "$WORK/platform" rev-parse --short HEAD)"

step "4/6 npm ci + next build"
cd "$APP"
npm ci --no-audit --no-fund
NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB}" \
NEXT_PUBLIC_APP_VERSION="$TAG" \
NEXT_PUBLIC_BASE_DOMAIN="$BASE_DOMAIN" \
  npm run build
# Same guard as the VM script: a heap death leaves no standalone output and the
# failure would otherwise surface two steps later as a confusing COPY error.
[ -d .next/standalone ] || die "next build produced no .next/standalone"
echo "next build OK"

step "5/6 buildkit image build + push"
# Dockerfile.prebuilt is the source of truth for the runtime image. The ONLY
# change for the in-cluster path is where the base comes from: buildkitd cannot
# reach public.ecr.aws, so point FROM at the Zot mirror of the SAME image. The
# swap is derived, not a forked copy, so the two paths cannot drift.
sed -E "s|^FROM .*|FROM ${BASE_MIRROR}|" Dockerfile.prebuilt > Dockerfile.incluster
grep -q "^FROM ${BASE_MIRROR}$" Dockerfile.incluster || die "FROM rewrite failed"
buildctl --addr "$BUILDKIT_HOST" build \
  --frontend dockerfile.v0 \
  --local context="$APP" \
  --local dockerfile="$APP" \
  --opt filename=Dockerfile.incluster \
  --opt build-arg:APP_VERSION="$TAG" \
  --output "type=image,name=${REGISTRY}/${IMAGE_REPO}:${TAG},push=true,oci-mediatypes=true"

step "6/6 verify the tag landed"
crane manifest "${REGISTRY}/${IMAGE_REPO}:${TAG}" >/dev/null \
  || die "pushed tag is not readable back from the registry"
echo "PUSH OK: ${REGISTRY}/${IMAGE_REPO}:${TAG}"
echo
echo "NOT DEPLOYED. To ship it:"
echo "  $0 --bump $TAG   # rewrites all FOUR image pins in the prod overlay"
echo "  then commit + push InfraWeaver-infra; ArgoCD (selfHeal) rolls it out."
