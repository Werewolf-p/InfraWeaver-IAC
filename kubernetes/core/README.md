# kubernetes/core/ — Cluster Infrastructure

Core cluster services that everything else depends on. **Don't touch unless you know what you're doing.**

---

## Services

| Service | Purpose |
|---------|---------|
| **traefik** | Ingress controller — routes external traffic to services |
| **cert-manager** | TLS certificate automation (Let's Encrypt DNS-01) |
| **external-secrets** | Syncs secrets from OpenBao → Kubernetes Secrets |
| **openbao** | Secrets management (HashiCorp Vault fork) |
| **longhorn** | Distributed block storage with HA and snapshots |
| **metallb** | Bare-metal load balancer (assigns external IPs) |
| **local-path-provisioner** | Simple single-node PVC provisioner (non-HA) |
| **argocd** | GitOps engine |
| **ingress-nginx** | (Legacy — scheduled for removal in favour of Traefik) |

---

## Adding a Core Service

Core services typically require cluster-admin permissions and must be deployed before apps.

Use sync waves to control deployment order:
- Wave 0: CRDs and storage
- Wave 1: Security / secrets (cert-manager, external-secrets, openbao)
- Wave 2: Networking (traefik, metallb)
- Wave 3: ArgoCD itself

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```
