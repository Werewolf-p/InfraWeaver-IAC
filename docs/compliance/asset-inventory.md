<!-- GENERATED FILE — do not edit by hand.
     Regenerate: python3 docs/compliance/scripts/generate-asset-inventory.py
     Source of truth: platform.yaml + live cluster (read-only kubectl get). -->

# Asset Inventory

**Control:** ISO/IEC 27001:2022 A.5.9 (inventory of information and other
associated assets), A.5.12 (classification), A.8.1 (endpoint devices),
A.8.6 (capacity management). SOC 2 CC3.2, CC6.1.

**Generated:** 2026-08-07 08:48 UTC by `docs/compliance/scripts/generate-asset-inventory.py`

**Owner:** Platform Owner (see `docs/compliance/information-security-policy.md` §3).

This file is generated. Hand edits are lost on the next run — change the
source (`platform.yaml`, the cluster, `envs/*/nodes.yaml`) instead, then
regenerate. That is deliberate: an inventory nobody can reproduce is not
evidence.

## 1. Platform identity

| Field | Value |
|---|---|
| Brand | ${PLATFORM_BRAND_NAME} |
| Base domain | ${BASE_DOMAIN} |
| Default cluster | ${DEFAULT_CLUSTER_ID} |
| Registry host | registry.int.${BASE_DOMAIN} |
| Identity provider | https://auth.${BASE_DOMAIN} |
| GitOps engine | https://argocd.int.${BASE_DOMAIN} |
| Backup provider | longhorn |

`${...}` tokens are fork placeholders substituted at deploy time from `.env` (see `docs/gitops-operating-model.md` §0). They are not secrets.

## 2. Compute — Kubernetes nodes

| Node | IP | Roles | State | OS | Kernel | Kubelet | Runtime | vCPU | Memory |
|---|---|---|---|---|---|---|---|---|---|
| talos-prod-cp1 | 10.0.0.90 | control-plane | Ready | Talos (v1.13.0) | 6.18.24-talos | v1.35.4 | containerd://2.2.3 | 6 | 24587224Ki |
| talos-prod-cp2 | 10.0.0.91 | control-plane | Ready | Talos (v1.13.0) | 6.18.24-talos | v1.35.4 | containerd://2.2.3 | 6 | 24587228Ki |
| talos-prod-cp3 | 10.0.0.92 | control-plane | Ready | Talos (v1.13.0) | 6.18.24-talos | v1.35.4 | containerd://2.2.3 | 6 | 10161128Ki |

**All 3 nodes are control-plane nodes and all are schedulable — this is a converged cluster: application workloads share the nodes running etcd and the API server. Accepted risk RISK-01 (`risk-register.md`).**

## 3. Hypervisor tier — Proxmox VMs beneath the nodes

### Environment `ontwikkel`

| VM | VMID | Cores | Memory (MB) | Balloon floor (MB) | Start on boot |
|---|---|---|---|---|---|
| talos-prod-cp3 | 9302 | 6 | 10240 | 0 | True |

### Environment `productie`

| VM | VMID | Cores | Memory (MB) | Balloon floor (MB) | Start on boot |
|---|---|---|---|---|---|
| treafik-and-adguard | 100 | 4 | 4096 | — | True |
| truenas | 103 | 3 | 8192 | 6144 | True |
| github-runner | 107 | 2 | 8192 | 8192 | True |
| backup-server | 111 | 2 | 4096 | — | True |
| infraweaver-init | 9004 | 2 | 2048 | — | True |
| talos-prod-cp1 | 9300 | 6 | 24576 | 0 | True |
| talos-prod-cp2 | 9301 | 6 | 24576 | 0 | True |

Source: `envs/<env>/nodes.yaml` in the infrastructure repo. These entries under `service_vms:` are *recorded inventory, not Terraform-managed* — they are reconciled with `qm set` by hand. `qm config` reports the staged value, not the running one; only `qm pending` shows what a live guest actually has. Capacity risk: RISK-05 (`risk-register.md`).

## 4. Declared platform composition (`platform.yaml`)

### 4.1 Mandatory core (cannot be disabled)

| App | Enabled | Purpose |
|---|---|---|
| argocd | yes | GitOps engine — powers all deployments |
| cert-manager | yes | TLS certificate automation (Let's Encrypt) |
| external-secrets | yes | Syncs secrets from OpenBao → Kubernetes Secrets |
| kyverno | yes | Policy engine — enforces resource limits on all pods, blocks privileged containers in app namespaces |
| local-path-provisioner | yes | Local disk storage for lightweight workloads |
| longhorn | yes | HA distributed block storage — cross-node PVC replication + scheduled backups to NFS |
| metallb | yes | Load balancer IP assignment for bare-metal |
| openbao | yes | Secrets vault (open-source Vault fork) |
| priority-classes | yes | Pod scheduling priority tiers |
| traefik | yes | Ingress controller — all HTTP(S) routing |

### 4.2 Optional groups

**`core-monitoring`** — Prometheus, Loki, Alertmanager — cluster observability (optional) (group enabled)

| App | Enabled | Purpose |
|---|---|---|
| alertmanager-discord | yes | Discord alert forwarder for Alertmanager |
| alerts | yes | PrometheusRule alert definitions (no pods) |
| kube-prometheus-stack | yes | Prometheus + kube-state-metrics + node-exporter |
| loki | yes | Log aggregation |

**`core-platform`** — SSO (required) + optional platform services (group enabled)

| App | Enabled | Purpose |
|---|---|---|
| argocd-image-updater | no | Automatic container image tag updates via GitOps |
| authentik | yes | Identity provider and SSO gateway |
| external-dns | yes | Automatic DNS record management via Cloudflare |
| falco | no | Runtime security and threat detection |
| grafana | no | Standalone Grafana for custom dashboards |
| homepage | no | Homelab dashboard (console /home tab provides same content) |
| minio-velero | no | S3-compatible storage for Velero backups |
| velero | no | Kubernetes backup controller |
| wazuh | no | SIEM and security event management |

### 4.3 Catalog applications enabled

| Catalog app |
|---|
| gatus |
| infraweaver-api |
| infraweaver-console |
| infraweaver-node |
| plex |
| registry |

## 5. Deployed applications — live ArgoCD inventory

**61 ArgoCD Applications** across 3 AppProjects.

| AppProject | Applications |
|---|---|
| default | 6 |
| infraweaver-prod | 9 |
| platform | 46 |

**6 applications sit in the unrestricted `default` AppProject** (no sourceRepos/destination pinning). Gap GAP-H9, owned by WP1.

<details><summary>Full application list</summary>

| Application | Project | Namespace | Source path | Sync | Health |
|---|---|---|---|---|---|
| catalog-game-hub-networks | default | game-hub | kubernetes/catalog/game-hub/networks | Synced | Healthy |
| core-metallb-manifests | default | metallb-system | kubernetes/core/metallb/manifests | Synced | Healthy |
| core-network-policies | default | kube-system | kubernetes/core/network-policies/manifests | Synced | Healthy |
| external-routes | default | traefik | kubernetes/platform/external-routes/manifests | Synced | Healthy |
| private-test | default | private-test | private-apps/private-test/k8s | Synced | Healthy |
| tradesphere | default | tradesphere | private-apps/tradesphere/k8s | OutOfSync | Degraded |
| apps | infraweaver-prod | apps | kubernetes/apps | Synced | Healthy |
| bootstrap | infraweaver-prod | bootstrap | kubernetes/bootstrap | Synced | Degraded |
| catalog | infraweaver-prod | catalog | kubernetes/catalog | Synced | Healthy |
| core | infraweaver-prod | core | kubernetes/core | Synced | Healthy |
| crds | infraweaver-prod | crds | kubernetes/crds | Synced | Healthy |
| development | infraweaver-prod | development | kubernetes/development | Synced | Healthy |
| monitoring | infraweaver-prod | monitoring | kubernetes/monitoring | Synced | Healthy |
| n8n-blueprints | infraweaver-prod | n8n-blueprints | kubernetes/n8n-blueprints | Synced | Healthy |
| platform | infraweaver-prod | platform | kubernetes/platform | Synced | Healthy |
| apps-authentik-manifests | platform | authentik | kubernetes/platform/authentik/manifests | Synced | Healthy |
| apps-dns | platform | dns-system | kubernetes/platform/dns/manifests | Synced | Healthy |
| catalog-game-hub-namespace | platform | game-hub | kubernetes/catalog/game-hub | Synced | Healthy |
| catalog-game-hub-servers | platform | game-hub | kubernetes/catalog/game-hub/servers | Synced | Degraded |
| catalog-gatus-manifests | platform | gatus | kubernetes/catalog/gatus/manifests | Synced | Healthy |
| catalog-infraweaver-api-manifests | platform | infraweaver-console | kubernetes/catalog/infraweaver-api/overlays/prod | Synced | Healthy |
| catalog-infraweaver-console-manifests | platform | infraweaver-console | kubernetes/catalog/infraweaver-console/overlays/prod | Synced | Degraded |
| catalog-infraweaver-node-manifests | platform | infraweaver-system | kubernetes/catalog/infraweaver-node/overlays/prod | Synced | Healthy |
| catalog-jellyfin-manifests | platform | jellyfin | kubernetes/catalog/jellyfin/manifests | Synced | Healthy |
| catalog-nas-shares | platform | default | kubernetes/catalog/nas-shares | Synced | Healthy |
| catalog-nextcloud-manifests | platform | nextcloud | kubernetes/catalog/nextcloud/manifests | Synced | Healthy |
| core-argocd | platform | argocd | - | Synced | Healthy |
| core-argocd-manifests | platform | argocd | kubernetes/core/argocd/manifests | Synced | Healthy |
| core-buildkit-manifests | platform | build | kubernetes/core/buildkit | Synced | Healthy |
| core-cert-manager | platform | cert-manager | - | Synced | Healthy |
| core-cert-manager-manifests | platform | cert-manager | kubernetes/core/cert-manager/manifests | Synced | Healthy |
| core-cert-manager-webhook-hetzner | platform | cert-manager | - | Synced | Healthy |
| core-cilium | platform | kube-system | - | Synced | Healthy |
| core-csi-driver-smb | platform | kube-system | - | Synced | Healthy |
| core-external-secrets | platform | external-secrets | - | Synced | Healthy |
| core-external-secrets-manifests | platform | external-secrets | kubernetes/core/external-secrets/manifests | Synced | Healthy |
| core-kyverno | platform | kyverno | - | Synced | Healthy |
| core-kyverno-policies | platform | kyverno | kubernetes/core/kyverno/manifests | Synced | Healthy |
| core-limitranges | platform | default | kubernetes/core/limitranges | Synced | Healthy |
| core-local-path-manifests | platform | default | kubernetes/core/local-path | Synced | Healthy |
| core-longhorn | platform | longhorn-system | - | Synced | Healthy |
| core-longhorn-manifests | platform | longhorn-system | kubernetes/core/longhorn/manifests | Synced | Healthy |
| core-metallb | platform | metallb-system | - | Synced | Healthy |
| core-metrics-server | platform | kube-system | - | Synced | Healthy |
| core-openbao | platform | openbao | - | Synced | Healthy |
| core-openbao-manifests | platform | openbao | kubernetes/core/openbao/manifests | Synced | Healthy |
| core-priority-classes | platform | kube-system | kubernetes/core/priority-classes/manifests | Synced | Healthy |
| core-psa-manifests | platform | default | kubernetes/core/psa | Synced | Healthy |
| core-registry-manifests | platform | registry | kubernetes/core/registry | Synced | Healthy |
| core-traefik | platform | traefik | - | Synced | Healthy |
| core-traefik-manifests | platform | traefik | kubernetes/core/traefik/manifests | Synced | Healthy |
| monitoring-alertmanager-discord | platform | monitoring | kubernetes/monitoring/alertmanager-discord/manifests | Synced | Healthy |
| monitoring-alerts | platform | monitoring | kubernetes/monitoring/alerts | Synced | Healthy |
| monitoring-grafana-dashboards | platform | monitoring | kubernetes/monitoring/grafana-dashboards | Synced | Healthy |
| monitoring-kube-prometheus-stack | platform | monitoring | - | Synced | Healthy |
| monitoring-kube-prometheus-stack-manifests | platform | monitoring | kubernetes/monitoring/kube-prometheus-stack/manifests | Synced | Healthy |
| monitoring-loki | platform | monitoring | - | Synced | Healthy |
| platform-authentik | platform | authentik | - | Synced | Healthy |
| platform-external-dns | platform | external-dns | - | Synced | Healthy |
| platform-external-dns-manifests | platform | external-dns | kubernetes/platform/external-dns/manifests | Synced | Healthy |
| platform-n8n | platform | n8n-prod | kubernetes/platform/n8n/manifests | Synced | Healthy |

</details>

Applications not Healthy at generation time:

| Application | Sync | Health |
|---|---|---|
| tradesphere | OutOfSync | Degraded |
| bootstrap | Synced | Degraded |
| catalog-game-hub-servers | Synced | Degraded |
| catalog-infraweaver-console-manifests | Synced | Degraded |

## 6. Trust zones — namespaces and Pod Security Admission level

**37 namespaces.**

| Namespace | PSA enforce | PSA audit |
|---|---|---|
| apps-grafana | privileged | privileged |
| argocd | baseline | baseline |
| authentik | baseline | baseline |
| bootstrap | - | - |
| build | privileged | privileged |
| cert-manager | baseline | restricted |
| cilium-secrets | - | - |
| crds | - | - |
| default | - | - |
| dns-system | - | - |
| external-dns | baseline | baseline |
| external-secrets | baseline | restricted |
| falco | privileged | privileged |
| game-hub | - | - |
| game-servers | - | - |
| gatus | - | - |
| infraweaver | - | - |
| infraweaver-console | baseline | restricted |
| infraweaver-system | baseline | restricted |
| jellyfin | privileged | baseline |
| kube-node-lease | - | - |
| kube-public | - | - |
| kube-system | privileged | privileged |
| kyverno | baseline | restricted |
| local-path-storage | privileged | privileged |
| longhorn-system | privileged | privileged |
| metallb-system | privileged | privileged |
| monitoring | privileged | privileged |
| n8n-prod | - | - |
| nextcloud | baseline | restricted |
| openbao | baseline | restricted |
| private-test | restricted | - |
| registry | baseline | restricted |
| tradesphere | restricted | - |
| traefik | baseline | baseline |
| velero | - | - |
| wordpress | baseline | restricted |

**13 namespaces carry no explicit PSA enforce label** and inherit the cluster default (`baseline`): `bootstrap`, `cilium-secrets`, `crds`, `default`, `dns-system`, `game-hub`, `game-servers`, `gatus`, `infraweaver`, `kube-node-lease`, `kube-public`, `n8n-prod`, `velero`. Gap GAP-M3, owned by WP4.

## 7. Persistent data assets

**39 PersistentVolumeClaims.** Each is in scope for the backup and retention obligations in `business-continuity-plan.md` and `logging-and-retention-policy.md`.

| Namespace | PVC | StorageClass | Size | Phase |
|---|---|---|---|---|
| authentik | data-authentik-postgresql-0 | local-path | 2Gi | Bound |
| game-hub | gt-new-horizons-container | longhorn-game | 60Gi | Bound |
| game-hub | gt-new-horizons-container-local | local-path-retain | 30Gi | Bound |
| game-hub | gt-new-horizons-container-portable | longhorn | 60Gi | Bound |
| infraweaver-console | infraweaver-backup-datastore | longhorn-retain | 30Gi | Bound |
| jellyfin | jellyfin-data-0 | longhorn | 5Gi | Bound |
| jellyfin | jellyfin-data-0-lp | local-path-retain | 5Gi | Bound |
| jellyfin | nas-infraweaver-media-ro |  | 500Gi | Bound |
| monitoring | alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0 | local-path | 2Gi | Bound |
| monitoring | prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 | local-path | 20Gi | Bound |
| monitoring | storage-loki-0 | local-path | 10Gi | Bound |
| n8n-prod | n8n-data | local-path-retain | 2Gi | Bound |
| n8n-prod | postgresql-n8n-data | local-path-retain | 5Gi | Bound |
| nextcloud | nas-infraweaver-media-rw |  | 500Gi | Bound |
| nextcloud | nextcloud-data | longhorn | 40Gi | Bound |
| nextcloud | nextcloud-data-lp | local-path-retain | 100Gi | Bound |
| nextcloud | postgresql-nextcloud-data | longhorn | 10Gi | Bound |
| nextcloud | postgresql-nextcloud-data-lp | local-path-retain | 10Gi | Bound |
| openbao | data-openbao-0 | local-path | 5Gi | Bound |
| registry | zot-data | local-path-retain | 20Gi | Bound |
| tradesphere | data-tradesphere-db-0 | local-path | 2Gi | Bound |
| velero | minio-velero-data | longhorn-retain | 20Gi | Bound |
| wordpress | hi2-db-data | local-path-retain | 5Gi | Bound |
| wordpress | hi2-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | hi2-wp-data-slot-b | local-path-retain | 5Gi | Bound |
| wordpress | hihi-db-data | local-path-retain | 5Gi | Bound |
| wordpress | hihi-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | lol-db-data | local-path-retain | 5Gi | Bound |
| wordpress | lol-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | lolll-db-data | local-path-retain | 5Gi | Bound |
| wordpress | lolll-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | my-site-db-data | local-path-retain | 5Gi | Pending |
| wordpress | test-db-data | local-path-retain | 5Gi | Bound |
| wordpress | test-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | yonavaarwater-nl-db-data | local-path-retain | 5Gi | Bound |
| wordpress | yonavaarwater-nl-wp-data | local-path-retain | 5Gi | Bound |
| wordpress | zonnevaarwater-nl-db-data | local-path-retain | 5Gi | Bound |
| wordpress | zonnevaarwater-nl-wp-data | local-path-retain | 5Gi | Bound |

## 8. External data custodians declared in `platform.yaml`

| Provider | Enabled | Host | SMB | NFS | Managed shares |
|---|---|---|---|---|---|
| synology | yes | 10.1.0.21 | SMB |  | Mediaserver |
| truenas | yes | 10.1.0.135 | SMB | NFS | Main |

Longhorn volume backup target (declared): `nfs://10.1.0.135/mnt/pool/k8s-longhorn-backups`, enabled=True. Verify the LIVE value — they have drifted before (GAP-C2): `kubectl get backuptarget -n longhorn-system -o jsonpath='{.items[*].spec.backupTargetURL}'`.

Commercial/contractual detail for these and all other third parties is in
`vendor-register.md`.

---

## Classification

This platform uses three classes (see `information-security-policy.md` §6):

| Class | Meaning | Examples in this inventory |
|---|---|---|
| Secret | Compromise grants access to other systems | OpenBao contents, Kubernetes Secrets, kubeconfig, Talos PKI, SOPS/age keys, Proxmox API tokens |
| Personal | Identifies a natural person (GDPR in scope) | `users.yaml`, Authentik user table, Nextcloud data, Jellyfin profiles, WordPress site users, mail addresses |
| Operational | Everything else the platform runs on | Manifests, container images, metrics, logs, this inventory |

No secret values appear in this file or anywhere else in `docs/compliance/`. Secrets live only in OpenBao and, for IaC, in SOPS/age-encrypted `envs/*/secrets.sops.yaml`.

