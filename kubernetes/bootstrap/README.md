# kubernetes/bootstrap/ — ArgoCD Bootstrap

ArgoCD ApplicationSet and Application manifests that bootstrap the entire platform.

**Don't edit these files unless you're adding a new platform service or changing ArgoCD configuration.**

---

## How It Works

1. Terraform (`platform.yml`) creates the root ApplicationSet in ArgoCD
2. The root ApplicationSet scans `kubernetes/*/` and creates one ArgoCD Application per tier
3. The Application for `bootstrap/` deploys ALL files in this directory
4. Those files include:
   - `applicationset-root.yaml` — git-file ApplicationSet that auto-discovers Helm apps
   - `app-*.yaml` — per-service ArgoCD Applications for raw manifest directories
   - `appproject-platform.yaml` — ArgoCD AppProject (access control)
   - `core-*.yaml` — bootstrap Applications for core infra manifests

---

## Adding a Bootstrap Application

When a service has raw K8s manifests (not just Helm), create a bootstrap Application here:

```bash
# Copy an existing one as a template:
cp kubernetes/bootstrap/app-authentik-manifests.yaml \
   kubernetes/bootstrap/app-my-service.yaml

# Edit the path and name:
# - metadata.name: apps-my-service
# - spec.source.path: kubernetes/apps/my-service/manifests
# - spec.destination.namespace: apps-my-service
```

---

## Files

| File | Purpose |
|------|---------|
| `applicationset-root.yaml` | Auto-discovers `kubernetes/*/*/application.yaml` → Helm apps |
| `appproject-platform.yaml` | ArgoCD AppProject with access rules |
| `app-authentik-manifests.yaml` | Deploys Authentik ExternalSecrets + blueprints |
| `app-external-routes.yaml` | Deploys all IngressRoutes + Middlewares |
| `app-dns.yaml` | Deploys CoreDNS custom ConfigMap |
| `app-grafana-manifests.yaml` | Deploys Grafana dashboards + datasources |
| `core-*.yaml` | Core infra bootstrap Applications |
