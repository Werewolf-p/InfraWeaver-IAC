# argocd-cmp-tools — sidecar image for the envsubst Config Management Plugin.
# (design: docs/gitops-cmp-substitution.md §4c, §5.1)
#
# Based on the official ArgoCD image so the cmp-server binary that the repo-server
# shares into the sidecar (volume var-files -> /var/run/argocd) is ABI-compatible,
# and so kustomize + helm (already bundled in the argocd image) are present for
# `kustomize build --enable-helm`. We add only `envsubst` (gettext-base).
#
# ARGOCD_VERSION MUST track the appVersion of the argo-cd Helm chart deployed by
# core/argocd (currently chart "9.5.*"). build.sh auto-detects it from the chart
# when helm is available; the default below is the fallback.
ARG ARGOCD_VERSION=v3.4.3
FROM quay.io/argoproj/argocd:${ARGOCD_VERSION}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends gettext-base \
 && rm -rf /var/lib/apt/lists/*

# argocd image runs as uid 999 (argocd); the sidecar also runs runAsUser: 999.
USER 999
