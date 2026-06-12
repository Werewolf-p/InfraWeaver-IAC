# kubernetes/platform/ — Platform Services

Platform services are core user-facing services managed by the platform team. These include authentication, VPN, DNS, routing, and dashboards.

**Do not add user workloads here.** User apps go in `kubernetes/apps/`.

---

## Services in This Tier

| Service | Namespace | URL | Purpose |
|---------|-----------|-----|---------|
| **Authentik** | `authentik` | `https://auth.${BASE_DOMAIN}` | SSO / identity provider |
| **DNS** | `dns` | cluster-internal | Custom DNS zones for `.int.${BASE_DOMAIN}` |
| **External-Routes** | `traefik` | — | Traefik IngressRoutes + Middlewares |
| **Homepage** | `apps-homepage` | `https://home.int.${BASE_DOMAIN}` | Homelab service dashboard |
| **Grafana** | `monitoring` | `https://grafana.int.${BASE_DOMAIN}` | Metrics visualization |

---

## Structure

Each service follows the same layout:
```
platform/
└── <service>/
    ├── application.yaml     ← Helm chart descriptor (if Helm-based)
    ├── values.yaml          ← Helm values
    └── manifests/           ← Raw K8s resources (Secrets, IngressRoutes, etc.)
```

---

## Adding a New Platform Service

Platform services are different from user apps — they typically need cross-namespace access, special certificates, or integration with Authentik.

For adding a simple user-facing app, use `kubernetes/apps/` instead:
```bash
bash scripts/new-app.sh my-app
```

For a new platform service:
1. Create `kubernetes/platform/<service-name>/`
2. Add `application.yaml` (if Helm-based)
3. Add `manifests/` with K8s resources
4. Add a bootstrap Application in `kubernetes/bootstrap/app-<service-name>.yaml`
5. Add routes in `kubernetes/platform/external-routes/manifests/`

---

## Routing and Security

All platform routes are defined in `external-routes/manifests/`:
- Internal routes (`*.int.${BASE_DOMAIN}`) → require Authentik forward-auth (`forward-auth` middleware)
- Public routes (`*.${BASE_DOMAIN}`) → require Authentik SSO (`forward-auth` middleware) where appropriate
