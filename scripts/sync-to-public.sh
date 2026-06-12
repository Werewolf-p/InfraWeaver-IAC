#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-to-public.sh — publish a SANITIZED subset of this PRIVATE source repo to
# the PUBLIC template repo. IaC and config/param NEVER leave the private repo.
#
# Model:
#   PRIVATE repo (this one)  = full source of truth: terraform/ ansible/ envs/
#                              params/ + kubernetes/** incl. concrete overlays/prod.
#                              ArgoCD reads THIS repo (private, via deploy key).
#   PUBLIC  template repo     = generic, forkable: base/ manifests + app code +
#                              *.example templates. NO secrets, NO real config,
#                              NO IaC, NO prod overlays.
#
# Excluded from the public push (the "config/param + IaC" the goal calls out):
#   terraform/  ansible/  envs/  params/  *.tfvars  *.tfstate*  .sops.yaml  .env
#   kubernetes/**/overlays/prod/   (concrete per-cluster values)
# Kept (templates so forks can fill them in): params.example/ *.example .env.example
#
# Usage (CI or local):
#   PUBLIC_REPO_URL="https://x-access-token:${TOKEN}@github.com/<owner>/<public>.git" \
#     scripts/sync-to-public.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PUBLIC_REPO_URL="${PUBLIC_REPO_URL:?set PUBLIC_REPO_URL (https URL with a write token)}"
SRC="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning public target"
git clone --quiet --depth=1 "$PUBLIC_REPO_URL" "$WORK/pub" 2>/dev/null || {
  mkdir -p "$WORK/pub"; git -C "$WORK/pub" init -q; git -C "$WORK/pub" checkout -q -b main
}

echo "==> exporting GIT-TRACKED tree only (git archive)"
# CRITICAL: export only committed files. rsync of the working tree would copy
# gitignored local artifacts (overlays/local/, generated kubeconfig/talosconfig,
# *.local.yaml, .redeploy-backup-*) straight into the public mirror. git archive
# emits ONLY tracked content, eliminating that entire leak class.
find "$WORK/pub" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
git -C "$SRC" archive --format=tar HEAD | tar -x -C "$WORK/pub"

echo "==> stripping IaC + concrete per-cluster config from the export"
( cd "$WORK/pub"
  rm -rf terraform ansible envs params
  rm -f docs/SECURITY-REMEDIATION-RUNBOOK.md .last-params-backup .sops.yaml .env
  # concrete prod overlays (real domain/IPs) — keep base/ + overlays/local stays gitignored
  find . -depth -type d -name prod -path '*/overlays/*' -exec rm -rf {} +
  find . -type f \( -name '*.tfvars' -o -name '*.tfstate' -o -name '*.tfstate.*' \
       -o -name '*.key' -o -name '*.pem' \) -delete )

# Safety net: refuse to publish if any obviously-sensitive path slipped through.
if find "$WORK/pub" \( -path '*/terraform/*' -o -path '*/ansible/*' -o -path '*/envs/*' \
      -o -path '*/overlays/prod/*' -o -name '*.tfvars' -o -name '.sops.yaml' \) \
      -not -path '*/.git/*' | grep -q .; then
  echo "✖ ABORT: excluded content present in sanitized tree — not pushing." >&2
  find "$WORK/pub" \( -path '*/terraform/*' -o -path '*/overlays/prod/*' \) -not -path '*/.git/*' | head >&2
  exit 1
fi

# Content deny-scan (fail-closed): refuse to publish if any private identifier
# (real domain, real usernames, token names) appears in the sanitized tree.
# Patterns live in params/.public-deny (gitignored, never synced) — one ERE
# regex per line, '#' comments allowed — so the secrets/identifiers themselves
# are never baked into this script. If the file is absent, only a built-in
# generic check runs (private-key blocks).
DENY_FILE="$SRC/params/.public-deny"
deny_hit=0
if [[ -f "$DENY_FILE" ]]; then
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    if grep -rIlE "$pat" "$WORK/pub" --exclude-dir=.git >/dev/null 2>&1; then
      echo "✖ ABORT: deny-pattern matched in sanitized tree (pattern hidden) — not pushing." >&2
      grep -rIlE "$pat" "$WORK/pub" --exclude-dir=.git | sed "s|$WORK/pub/||" | head >&2
      deny_hit=1
    fi
  done < "$DENY_FILE"
fi
if grep -rIlE '^[[:space:]]*-----BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----' "$WORK/pub" --exclude-dir=.git >/dev/null 2>&1; then
  echo "✖ ABORT: private key material present in sanitized tree — not pushing." >&2
  deny_hit=1
fi
[[ "$deny_hit" == 1 ]] && exit 1

cd "$WORK/pub"
git add -A
if git diff --cached --quiet; then
  echo "==> no changes to publish"; exit 0
fi
git -c user.name="infraweaver-sync" -c user.email="sync@infraweaver.local" \
  commit -q -m "sync: sanitized update from private source ($(date -u +%FT%TZ))"
git push --quiet "$PUBLIC_REPO_URL" HEAD:main
echo "==> published sanitized update to public template"
