# Private GitOps + Public Template + DR Rebuild

Target model and the exact steps to reach it. Sequenced so the **live cluster is
never left without a reachable GitOps source**, and the destructive rebuild is
gated to the end.

## Target architecture
```
PRIVATE repo  (InfraWeaver-infra, flipped private) = single source of truth
  terraform/ ansible/ envs/ params/ + kubernetes/** incl. concrete overlays/prod
  ArgoCD reads THIS repo via a read-only deploy key (reachable; replaces OneDev)
        │  scripts/sync-to-public.sh  (.github/workflows/sync-to-public.yml)
        ▼  excludes IaC + config/param (terraform/ansible/envs/params/overlays/prod/*.tfvars/.sops.yaml)
PUBLIC  template repo (new, e.g. InfraWeaver-template) = generic base/ + code + *.example
InfraWeaver-platform (app code) = stays public; push app changes directly
InfraWeaver-base = retire OR keep as the private IaC home (it duplicates terraform/ansible/envs)
```
The sanitized sync is **built and validated** (`scripts/sync-to-public.sh`: dry-run
confirmed it drops terraform/ansible/envs/params/overlays-prod and keeps base/ +
params.example). It is wired as a guarded GitHub Action (no-ops until `vars.PUBLIC_REPO`
+ `secrets.PUBLIC_REPO_PAT` are set).

## Phase 1 — Cutover to private GitHub source (no cluster teardown)
Do this BEFORE flipping repo visibility, or ArgoCD's anonymous reads break.
```bash
export KUBECONFIG=/home/runner/.kube/config-platform-productie
# 1. Give ArgoCD read access to the (soon-private) repo: deploy key or PAT.
kubectl -n argocd create secret generic repo-infraweaver-infra \
  --from-literal=type=git \
  --from-literal=url=https://github.com/Werewolf-p/InfraWeaver-infra \
  --from-literal=password=<fine-grained-PAT-contents:read> --from-literal=username=git
kubectl -n argocd label secret repo-infraweaver-infra argocd.argoproj.io/secret-type=repository
# 2. Repoint the app-of-apps tier OneDev -> this GitHub repo (replaces broken OneDev; see B2).
GH=https://github.com/Werewolf-p/InfraWeaver-infra
for a in bootstrap catalog apps core platform crds development monitoring; do
  kubectl patch application -n argocd "$a" --type=merge -p '{"spec":{"source":{"repoURL":"'"$GH"'"}}}'; done
kubectl patch applicationset -n argocd platform-catalog-apps --type=json \
  -p '[{"op":"replace","path":"/spec/generators/0/git/repoURL","value":"'"$GH"'"}]'
# 3. Validate ALL apps Synced/Healthy from the private repo, no unexpected prunes.
kubectl get applications -n argocd -w
# 4. Only now flip visibility:
gh repo edit Werewolf-p/InfraWeaver-infra --visibility private --accept-visibility-change-consequences
# 5. Create the public template + enable the sync:
gh repo create Werewolf-p/InfraWeaver-template --public
gh secret set PUBLIC_REPO_PAT -R Werewolf-p/InfraWeaver-infra --body <fine-grained-PAT-contents:write-on-template>
gh variable set PUBLIC_REPO -R Werewolf-p/InfraWeaver-infra --body Werewolf-p/InfraWeaver-template
gh workflow run sync-to-public.yml -R Werewolf-p/InfraWeaver-infra   # first publish
```

## Phase 2 — DR rebuild with all-new secrets (SUPERVISED; catastrophic if unattended)
Run this only with an operator watching — the Talos bootstrap has interactive waits
and many failure points; a fire-and-forget run risks an unrecoverable cluster.
**Validate first (non-destructive):** `cd terraform && tofu plan -destroy` and read it.
```bash
cd /home/runner/InfraWeaver-infra
# 0. Back up state + any secrets you want to keep (NOT the ones being rotated).
# 1. Rotate the source credentials FIRST so the rebuild uses new ones:
#    - new Proxmox API token, new Cloudflare token, new SMTP pw, new deployer SSH key
#    - put them in .env (the init website / configure-platform writes these)
# 2. Destroy cluster + init VM:
cd terraform && tofu destroy -auto-approve   # wipes Talos VMs + init VM on Proxmox
# 3. Re-init: run the init website (server.py, now bearer-auth gated) or:
bash scripts/deploy-local.sh        # re-creates init VM, applies terraform, bootstraps Talos
# 4. OpenBao comes up fresh -> re-seed platform secrets (new values):
bash scripts/deploy/seed-openbao-platform.sh http://localhost:8200 <new-root-token>
#    + re-seed DISPATCH_SECRET, console OIDC, argocd-token, etc. (see ExternalSecrets)
# 5. ArgoCD bootstraps app-of-apps from the PRIVATE GitHub repo (Phase 1 wiring) and
#    syncs every catalog app from overlays/prod (concrete values). Validate:
kubectl get applications -n argocd
curl -k https://infraweaver.int.<domain>/api/ping   # console up
```
After rebuild, the Talos CA / kubeconfig are freshly generated (resolves C-4), and all
seeded secrets are new (resolves C-1). Encrypt `envs/*/generated/` at rest with SOPS
(the private repo already carries `.sops.yaml`).

> Status: Phase-1 sync tooling is committed + validated here. The live ArgoCD cutover,
> the visibility flip, and the Phase-2 destroy are intentionally left as supervised
> operator steps (irreversible / high-blast-radius / multi-hour bootstrap).
