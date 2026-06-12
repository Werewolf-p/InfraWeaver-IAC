# infraweaver-console (GitOps)

ArgoCD-managed manifests for the InfraWeaver Console, structured with Kustomize
so that **stable definitions** and **tunable parameters** live in separate places.

```
infraweaver-console/
├── catalog.yaml          # catalog metadata (namespace, ingress host, secrets)
├── base/                 # environment-agnostic manifests — change rarely
│   ├── kustomization.yaml
│   ├── deployment.yaml   # NO spec.replicas (the HPA owns the replica count)
│   ├── hpa.yaml
│   └── … (service, rbac, networkpolicy, externalsecrets, …)
└── overlays/
    └── prod/
        └── kustomization.yaml   # ← THE param layer (image tag, HPA bounds)
```

## Single source of truth

- **App source code** lives in the `InfraWeaver-platform` repo and is built into a
  container image pushed to `registry.int.${BASE_DOMAIN}/infraweaver-console`.
- **What is deployed** (image tag, autoscaling bounds) lives **only** in
  `overlays/prod/kustomization.yaml`. Nothing else pins the image.

The ArgoCD `Application` (`catalog-infraweaver-console-manifests`) points its
`source.path` at `overlays/prod`. ArgoCD renders Kustomize natively — no plugin.

## How to update

**Bump the running image** (also done automatically by the feedback dispatch on
`/approve`, and reversible via `/rollback`):

```yaml
# overlays/prod/kustomization.yaml
images:
  - name: registry.int.${BASE_DOMAIN}/infraweaver-console
    newTag: <new-tag>        # ← edit this line only
```

**Change autoscaling range:** edit the HPA patch in the same overlay file.

**Add a new environment:** copy `overlays/prod` to `overlays/<env>` and point a
new Application at it. `base/` is shared and untouched.

## Why no `spec.replicas`

An HPA (`base/hpa.yaml`) owns the replica count. If the Deployment also declared
`replicas`, ArgoCD `selfHeal` and the HPA would fight over it (reset ↔ rescale).
Omitting the field makes the HPA the sole owner — no drift.

## Validate locally

```sh
kubectl kustomize overlays/prod      # must render without error
```

> Image-pin bumps (`image:` / `newTag:` lines) are the only changes the infra
> repo's `pre-push` guard allows straight to GitHub; other config edits need
> `ALLOW_CONFIG_PUSH=1`.
