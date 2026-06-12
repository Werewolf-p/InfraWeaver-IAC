# kubernetes/ — GitOps Manifests

All Kubernetes resources are managed here by ArgoCD. The folder is organized into **tiers** — ArgoCD creates one Application per tier directory.

---

## Tier Overview

| Tier | Directory | Who manages | What lives here |
|------|-----------|-------------|-----------------|
| **apps** | `apps/` | You | User apps, workloads, custom services |
| **platform** | `platform/` | Platform team | Authentication, VPN, DNS, routing, dashboards |
| **core** | `core/` | Platform team | Cluster infrastructure: ingress, certs, secrets, storage, ArgoCD |
| **monitoring** | `monitoring/` | Platform team | Prometheus, Grafana, Loki, alerting |
| **bootstrap** | `bootstrap/` | Terraform + git | ArgoCD ApplicationSet + per-app bootstrap Applications |

---

## How Apps Are Deployed

```
┌─────────────────────────────────────────────────────────────────┐
│  Terraform (platform.yml)                                        │
│  └── Creates root ApplicationSet (scans kubernetes/*/)          │
│       ├── Application "apps"       → deploys kubernetes/apps/   │
│       ├── Application "platform"   → deploys kubernetes/platform│
│       ├── Application "core"       → deploys kubernetes/core/   │
│       ├── Application "monitoring" → deploys kubernetes/monitoring│
│       └── Application "bootstrap"  → deploys kubernetes/bootstrap│
│                                                                  │
│  ApplicationSet in bootstrap/ (git-file generator)              │
│  └── Scans kubernetes/*/*/application.yaml                      │
│       └── Creates Helm chart Applications for each app          │
└─────────────────────────────────────────────────────────────────┘
```

### Adding a Helm chart app:
```bash
bash scripts/new-app.sh my-service --helm https://charts.example.com my-chart
```

### Adding a raw-manifest app:
```bash
bash scripts/new-app.sh my-service
```

See `docs/templates/app/README.md` for full details.

---

## Security Model

- All `*.int.${BASE_DOMAIN}` routes are protected by the `forward-auth` middleware (VPN required)
- All `*.${BASE_DOMAIN}` routes are public (add `forward-auth` middleware for Authentik SSO)
- New apps scaffolded via `scripts/new-app.sh` get NetworkPolicy, PSA, and ResourceQuota by default

---

## Quick Reference

```
kubernetes/
├── apps/               ← ADD YOUR APPS HERE
│   ├── _template/      ← Template files (don't edit, use new-app.sh instead)
│   ├── example-app/    ← Reference implementation
│   └── test-website/   ← Simple HTTP server for smoke testing
├── platform/           ← Platform services (authentik, dns, etc.)
├── core/               ← Cluster infrastructure (traefik, cert-manager, openbao, etc.)
├── monitoring/         ← Observability stack (prometheus, grafana, loki)
└── bootstrap/          ← ArgoCD bootstrap (don't edit unless you know what you're doing)
```
