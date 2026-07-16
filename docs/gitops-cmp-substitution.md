# ArgoCD Config Management Plugin — sync-time placeholder substitution

> **Status:** Proposed (design). Not yet applied — the prod cluster is torn down
> (DR rebuild pending), so this is validated at rebuild, not in-place.
> Supersedes the provision-time `generate-from-env.sh` step for the GitOps path.
> Related: [`gitops-operating-model.md`](./gitops-operating-model.md) §0, §2 (M4),
> [`PRIVATE-PUBLIC-GITOPS-AND-DR.md`](./PRIVATE-PUBLIC-GITOPS-AND-DR.md).

## 1. Problem

Committed config in `kubernetes/` uses `${PLACEHOLDER}` variables (the forkable
template model — operating-model §0). Counts in the current tree:

| Placeholder | Count | Class |
|-------------|------:|-------|
| `${BASE_DOMAIN}` | 313 | config |
| `${DEPLOY_REPO_URL}` | 37 | config |
| `${METALLB_TRAEFIK_VIP}` | 24 | config |
| `${ONEDEV_URL}` | 11 | config |
| `${ADMIN_PASSWORD}` | 11 | **secret** |
| `${ADMIN_LOGIN}` | 11 | secret-adjacent |
| `${MGMT_SUBNET_CIDR}` / `${NODE_SUBNET_CIDR}` | 17 | config |
| `${PUBLIC_INGRESS_IP}`, `${METALLB_COREDNS_VIP}`, `${TRUENAS_HOST}`, `${GITHUB_REPO}`, `${ADMIN_EMAIL}`, `${TARGET_REPLICAS}`, … | ~50 | config |
| `${GITHUB_TOKEN}` | 4 | **secret** |

Today these are resolved **before bootstrap** by `scripts/generate-from-env.sh`,
which writes the substituted files into the git repo ArgoCD watches. That repo was
OneDev, which is now unreachable. Pointing ArgoCD directly at the GitHub/infra repo
fails because ArgoCD has **no substitution** — it would apply literal `${BASE_DOMAIN}`
strings. This is the deployability blocker.

## 2. Decision

Substitute at **sync time inside the ArgoCD repo-server**, via a Config Management
Plugin (CMP) sidecar that runs `envsubst` over each app's rendered manifests using a
**non-secret** values source. Placeholders stay in git (fork-friendly); ArgoCD
watches the infra repo directly; no rendered tree is committed; the console keeps
imperative ownership of its own apps.

### Why not the alternatives
- **Render to `generated/` and commit it** — two trees to keep in sync, drift risk,
  every change needs a regen+commit. Rejected.
- **Repoint ArgoCD → `overlays/prod`** — breaks apps the console owns imperatively
  (per the gamehub split-brain history) and doesn't cover Helm-`values.yaml`
  placeholders. Rejected.

## 3. Secret-class placeholders are out of scope (fail-closed)

The CMP substitutes **config only**. Secret-class placeholders must NEVER be
sourced from the plugin's ConfigMap:

- `${ADMIN_PASSWORD}`, `${GITHUB_TOKEN}` — confined to `catalog/onedev/manifests/bootstrap-job.yaml`
  and the `n8n-blueprints` / `catalog/n8n` workflows. Both subsystems are being
  deprecated; their real secrets already belong in OpenBao + ESO (36 ExternalSecrets
  exist, operating-model §4).
- The plugin **fails the sync** if any `${...}` token classified as secret survives
  substitution, so a secret can never (a) be sourced from a plain ConfigMap, nor
  (b) leak as a literal `${GITHUB_TOKEN}` into a manifest.

Action item: migrate the onedev bootstrap-job and n8n workflows to ESO-injected
env (`valueFrom.secretKeyRef`) so they never carry `${SECRET}` placeholders at all.

## 4. Manifests

### 4a. Non-secret values (`argocd` namespace ConfigMap)

```yaml
# kubernetes/core/argocd/manifests/cmp-substitutions.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-substitutions
  namespace: argocd
  labels: { app.kubernetes.io/part-of: argocd }
data:
  # Config only — NEVER secrets. Sourced into envsubst at sync time.
  BASE_DOMAIN: "example.com"
  DEPLOY_REPO_URL: "https://github.com/Werewolf-p/InfraWeaver-infra.git"
  ONEDEV_URL: "https://onedev.int.example.com"
  METALLB_TRAEFIK_VIP: "10.0.0.80"
  METALLB_COREDNS_VIP: "10.0.0.53"
  PUBLIC_INGRESS_IP: "<set-at-rebuild>"
  MGMT_SUBNET_CIDR: "10.0.0.0/24"
  NODE_SUBNET_CIDR: "10.20.0.0/24"
  GITHUB_REPO: "Werewolf-p/InfraWeaver-infra"
  ADMIN_EMAIL: "admin@example.com"
  # ... remaining config placeholders
```

> Populate `data` from `.env` at rebuild — e.g. a one-liner that emits only the
> config-class keys (an explicit allowlist, so a secret key can never slip in).

### 4b. CMP plugin definition

```yaml
# kubernetes/core/argocd/manifests/cmp-plugin.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-envsubst-plugin
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: envsubst
    spec:
      version: v1.0
      # Opt-in: only apps that set the plugin (or whose path matches) use it.
      discover:
        find:
          glob: "**/*.yaml"
      generate:
        # 1. render (kustomize build if kustomization.yaml present, else cat),
        # 2. envsubst with ONLY the allowlisted vars,
        # 3. fail-closed if any secret-class ${TOKEN} survives.
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -eu
            if [ -f kustomization.yaml ]; then RENDER="kustomize build --enable-helm ."; else RENDER="cat $(find . -name '*.yaml' | sort)"; fi
            OUT="$($RENDER | envsubst "$ALLOWED_VARS")"
            if printf '%s' "$OUT" | grep -Eq '\$\{(ADMIN_PASSWORD|GITHUB_TOKEN)\}'; then
              echo "envsubst: secret-class placeholder survived — refusing" >&2; exit 1
            fi
            printf '%s' "$OUT"
```

> `$ALLOWED_VARS` is the explicit `${VAR}` allowlist (e.g.
> `"${BASE_DOMAIN} ${DEPLOY_REPO_URL} ${ONEDEV_URL} ..."`), passed to `envsubst`
> so only listed names are substituted; everything else is left verbatim and the
> secret-class grep then hard-fails.

### 4c. repo-server sidecar (add to `kubernetes/core/argocd/values.yaml`)

```yaml
repoServer:
  # ... existing config ...
  sidecarContainers:
    - name: cmp-envsubst
      image: ghcr.io/Werewolf-p/argocd-cmp-tools:latest   # argocd-repo-server base + envsubst + kustomize + helm
      args: ["/var/run/argocd/argocd-cmp-server"]
      securityContext: { runAsNonRoot: true, runAsUser: 999 }
      envFrom:
        - configMapRef: { name: argocd-cmp-substitutions }
      env:
        - name: ALLOWED_VARS
          value: "${BASE_DOMAIN} ${DEPLOY_REPO_URL} ${ONEDEV_URL} ${METALLB_TRAEFIK_VIP} ${METALLB_COREDNS_VIP} ${PUBLIC_INGRESS_IP} ${MGMT_SUBNET_CIDR} ${NODE_SUBNET_CIDR} ${GITHUB_REPO} ${ADMIN_EMAIL}"
      volumeMounts:
        - { name: var-files, mountPath: /var/run/argocd }
        - { name: plugins, mountPath: /home/argocd/cmp-server/plugins }
        - { name: cmp-tmp, mountPath: /tmp }
        - { name: argocd-cmp-envsubst-plugin, mountPath: /home/argocd/cmp-server/config/plugin.yaml, subPath: plugin.yaml }
  volumes:
    - { name: cmp-tmp, emptyDir: {} }
    - { name: argocd-cmp-envsubst-plugin, configMap: { name: argocd-cmp-envsubst-plugin } }
```

### 4d. Opt an Application in

```yaml
spec:
  source:
    plugin:
      name: envsubst-v1.0
```

(Or rely on `discover` for the directory/Helm apps under `core/`, `platform/`,
`monitoring/`. Recommend explicit opt-in for the first migration wave.)

## 5. Migration

1. Build & push the `argocd-cmp-tools` image (repo-server base + `envsubst`,
   `kustomize`, `helm`).
2. Apply 4a–4c during the DR rebuild, before app-of-apps bootstrap.
3. Convert one low-risk app (e.g. `core/traefik` or a `BASE_DOMAIN`-only manifest)
   to the plugin; confirm `argocd app manifests <app>` shows the resolved domain.
4. Roll the rest of `core/`, `platform/`, `monitoring/` wave by wave.
5. Once ArgoCD substitutes at sync time, **retire `generate-from-env.sh` from the
   GitOps path** (keep it only for non-ArgoCD artifacts: `envs/` tfvars,
   `users.yaml`). Update operating-model §0 accordingly.
6. Migrate onedev/n8n secret-class placeholders to ESO (§3 action item), then the
   fail-closed grep becomes belt-and-suspenders.

## 6. Open questions / validation (at rebuild)

- Helm apps under `core/` use `$values/.../values.yaml`; confirm envsubst runs
  *after* `kustomize build --enable-helm` so chart-templated `${}` in values are
  caught. Some charts may need `helm template` directly instead.
- Decide M4 (single ArgoCD remote) in tandem — the CMP only makes sense once
  ArgoCD reads the infra repo with placeholders intact.
- Confirm repo-server memory headroom for the sidecar (currently `512Mi` limit).
