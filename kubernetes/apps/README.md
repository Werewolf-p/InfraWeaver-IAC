# kubernetes/apps/ — User Applications

This is where **you add new apps**. Each subdirectory is one application.

ArgoCD auto-deploys apps when you push to `main` — no manual pipeline changes needed.

---

## Adding a New App

```bash
# From the repo root:
bash scripts/new-app.sh <app-name>

# For a Helm chart:
bash scripts/new-app.sh <app-name> --helm https://charts.example.com chart-name
```

This copies security-hardened templates into `kubernetes/apps/<app-name>/manifests/` and creates
a `kubernetes/bootstrap/app-<app-name>.yaml` ArgoCD Application file.

**What happens when you push:**
- `apply-changes.yml` detects the new `kubernetes/bootstrap/app-<app-name>.yaml` file
- It applies the ArgoCD Application to the cluster
- ArgoCD syncs the manifests within ~60 seconds
- Your app is live!

**Security defaults included out of the box:**
- NetworkPolicy: default-deny + allow only from Traefik
- Dedicated ServiceAccount (no auto-mount)
- Pod Security Admission: restricted profile
- Secure pod template (non-root, read-only fs, drop ALL capabilities)
- ResourceQuota on the namespace

---

## Access Modes

### Internal (VPN only) — default
```bash
# Rename to activate:
mv kubernetes/apps/<app>/manifests/ingressroute-internal.yaml.example \
   kubernetes/apps/<app>/manifests/ingressroute-internal.yaml
# URL: https://<app>.int.${BASE_DOMAIN}
```

### Public internet (opt-in)
```bash
# Rename to activate (⚠️ review before using!):
mv kubernetes/apps/<app>/manifests/ingressroute-public.yaml.example \
   kubernetes/apps/<app>/manifests/ingressroute-public.yaml
# URL: https://<app>.${BASE_DOMAIN}
```

---

## Directory Structure

```
apps/
├── _template/           ← DO NOT deploy this — it's the template for new-app.sh
│   └── manifests/
│       ├── namespace.yaml
│       ├── serviceaccount.yaml
│       ├── networkpolicy.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── resourcequota.yaml
│       ├── ingressroute-internal.yaml.example
│       └── ingressroute-public.yaml.example
│
├── example-app/         ← Reference Helm chart app (nginx)
│   ├── application.yaml ← ArgoCD ApplicationSet descriptor
│   └── values.yaml      ← Helm values
│
└── test-website/        ← Simple HTTP smoke-test site
    └── manifests/
        └── *.yaml
```

> **Note:** `_template/` is protected from ArgoCD deployment via an ArgoCD ignore-path annotation.
> Files named `*.yaml.example` are never applied by ArgoCD.

---

## Checklist Before Pushing a New App

- [ ] Replace all `APP_NAME` placeholders in manifests
- [ ] Update container image and port in `deployment.yaml`
- [ ] Choose internal vs public IngressRoute (rename `.yaml.example` → `.yaml`)
- [ ] Review resource limits (requests/limits in `deployment.yaml` + `resourcequota.yaml`)
- [ ] For Helm apps: pin `targetRevision` to an exact version (e.g. `"2.4.1"`, NOT `"*"`)
