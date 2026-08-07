# Vendor and Supplier Register

| | |
|---|---|
| **Document ID** | ISMS-REG-002 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | Quarterly, alongside the access review (next: 2026-11-02) |
| **Controls** | ISO/IEC 27001:2022 A.5.19, A.5.20, A.5.21, A.5.22, A.5.23, A.8.29, A.8.30 · SOC 2 CC9.2 |

---

## 1. Scope and honest framing

ISO 27001 A.5.19–A.5.23 assume a procurement function that negotiates security
terms into supplier agreements and audits compliance against them. **This
platform has no negotiating position whatsoever.** Every supplier below is used
on standard published terms, mostly on a free or consumer tier, accepted as-is.
There are no bespoke security addenda, no DPAs beyond the providers' standard
ones, and no right to audit.

The value of this register is therefore not contractual assurance. It is
**knowing the blast radius**: what each third party can see, what breaks if it
disappears, and what the exit looks like. That is the question this document
actually answers.

**Criticality scale**
- **C1** — platform stops or data is lost without it
- **C2** — significant degradation; a workaround exists but is painful
- **C3** — inconvenience; readily replaced

---

## 2. Register

### 2.1 Critical suppliers (C1)

| Vendor | Service | Data it can see | Criticality | Access it holds | Exit path |
|---|---|---|---|---|---|
| **GitHub** (Microsoft) | Source of truth for all three repositories; GitHub Actions CI; self-hosted runner registration | Every manifest and every application source file. **No plaintext secrets** — enforced by the CI secret-leak gate. Repository metadata and commit identities | **C1** | Full read/write to the platform's declarative definition. A compromise of the account is a compromise of the platform, since 60 of 61 ArgoCD apps auto-sync from it | Repositories are git — clone to any forge (Gitea/Forgejo manifests already exist in the catalog). ArgoCD `repoURL` repoint is a documented operation (`SECURITY-REMEDIATION-RUNBOOK.md` §B2 performed exactly this migration). **Real risk: hours, not days** |
| **Cloudflare** | Authoritative DNS for `example.com`; DNS-01 challenge target for cert-manager; **reverse proxy for at least the `bitwarden.example.com` route** | All hostnames and query metadata. The `*.int` wildcard is DNS-only (resolves to the origin), but `bitwarden.example.com` resolves into Cloudflare space (`188.114.96.0`/`97.0`) — so for the **password-manager route Cloudflare terminates TLS and can see plaintext request bodies, including `/identity/connect/token`**. Confirmed 2026-08-07 via the WP9 rate-limit work, which had to bucket on `Cf-Connecting-IP` precisely because the connection source is a Cloudflare edge IP | **C1** | An API token with DNS edit rights, held in OpenBao and consumed by `external-dns` and `cert-manager-webhook-hetzner`. Token compromise permits DNS hijack of every platform hostname | Any DNS provider with a cert-manager/external-dns webhook. Migration cost is TTL propagation |
| **Let's Encrypt** (ISRG) | TLS certificates for every published hostname (`letsencrypt-dns`, `letsencrypt-http`, plus staging issuers) | Hostnames only (also public in CT logs) | **C1** | Issues certificates for platform domains via ACME | ZeroSSL/Buypass ACME, or the in-cluster `infraweaver-ca` self-signed issuer for internal-only operation |
| **Proxmox VE** (Proxmox Server Solutions) | Hypervisor software on self-owned hardware `10.1.0.3` and `10.1.0.4` | Everything — it runs every VM | **C1** | Self-hosted; the vendor holds no access. The supplier relationship is software supply chain only | Any hypervisor, at the cost of a full rebuild. In practice this is a hardware decision, not a vendor decision |
| **TrueNAS** (iXsystems) — VM 103 | Primary NAS; SMB/NFS shares; the declared Longhorn backup target | User media and file shares; **would hold every volume backup once WP2 makes backups work** | **C1** | Self-hosted. An `infraweaver-svc` API key at OpenBao path `secret/platform/nas/providers` | Synology (already present) or direct-attached storage |
| **Talos Linux** (Sidero Labs) | Immutable Kubernetes OS on all three nodes, v1.13.0 | Everything on the nodes | **C1** | Self-hosted; supply chain only. **The Talos CA private key currently sits unencrypted on the runner VM** — RISK-17 | Any Kubernetes distribution, at the cost of a rebuild |

### 2.2 Important suppliers (C2)

| Vendor | Service | Data it can see | Criticality | Notes |
|---|---|---|---|---|
| **Synology** — `10.1.0.21` | Secondary NAS; SMB shares (`Mediaserver`), per-user subfolders | User media | **C2** | Self-hosted. `infraweaver-svc` DSM account; credentials in OpenBao |
| **Docker Hub** (Docker Inc.) | 36 of the 83 distinct container images in use (measured 2026-08-07) | Nothing outbound; inbound supply-chain risk | **C2** | **No digest pinning and no vulnerability scanning** (RISK-15). Anonymous pull rate limits are an availability risk. Mitigation: the in-cluster Zot registry (`registry.int.…`) can mirror; a Kyverno registry allowlist is a WP4 deliverable |
| **GitHub Container Registry (ghcr.io)** | Platform-built images | Image contents | **C2** | Pull secret provisioned through OpenBao + ESO since 2026-07-15 |
| **Quay.io** (Red Hat), **registry.k8s.io** (CNCF), **lscr.io** (LinuxServer.io), **oci.external-secrets.io** | Upstream images for infrastructure components | Inbound supply chain | **C2** | Same unpinned/unscanned caveat. `lscr.io/linuxserver/jellyfin` is currently **untagged** — GAP-M1/WP5 |
| **Discord** (Discord Inc.) | The **only** Alertmanager delivery channel, via `alertmanager-discord` | Alert contents — hostnames, namespaces, workload names, failure detail. **This is operational metadata leaving the platform to a consumer chat service** | **C2** | Single point of failure for alerting (GAP-M4). An `email-admin` receiver is defined but the routing tree currently sends everything to `discord` or to `null`. No dead-man's-switch. WP8 adds a second receiver |
| **SMTP / mail provider** | Transactional mail: user invites, recovery, welcome and deploy notifications | Recipient email addresses and message bodies — **personal data** | **C2** | Credential rotation procedure at `SECURITY-REMEDIATION-RUNBOOK.md` §C-1 step 3. The provider identity is configured via `.env`/OpenBao and is deliberately not named here |
| **Hetzner** | DNS webhook solver for cert-manager (`core-cert-manager-webhook-hetzner`) | DNS records for any zone it manages | **C2** | Present as a deployed ArgoCD application. Its role should be re-confirmed at the next review — Cloudflare is the primary DNS provider |

### 2.3 Software supply chain — no commercial relationship (C2/C3)

Open-source components with no vendor contract, listed because A.5.21 (ICT
supply chain) applies to them whether or not money changes hands. Each is
deployed from an upstream chart or manifest and each represents an update-path
trust decision:

ArgoCD · Cilium · Traefik · cert-manager · External Secrets Operator · OpenBao ·
Authentik · Longhorn · MetalLB · Kyverno · Prometheus/Alertmanager/Grafana ·
Loki · Velero (undeployed) · Falco (disabled) · Zot · BuildKit · csi-driver-smb ·
local-path-provisioner · n8n · Nextcloud · Jellyfin · WordPress · Gatus.

**Control status:** no SBOM, no image signing verification, no CVE scanning of
running images. Checkov covers infrastructure-as-code only. RISK-15, accepted.

### 2.4 Discretionary (C3)

| Vendor | Service | Notes |
|---|---|---|
| **AdGuard** | DNS filtering on VM 100 | Self-hosted |
| **Bitwarden-compatible vault** (`bm-bitwarden`) | Password manager, bare-metal backend published at `bitwarden.example.com` | Self-hosted but **publicly exposed with no edge auth and no rate limit** — RISK-06. Registration disabled at the application (commit `db3cab4`) |
| **Binance API** (via `tradesphere`) | Market data for a personal trading workload | Its ExternalSecret is currently failing (RISK-13). Not platform-critical |

---

## 3. Data flows leaving the platform

The register above is mostly about inbound dependency. This section is the one
an auditor asking about A.5.23 and GDPR processors actually wants:

| Destination | What leaves | Class | Justification |
|---|---|---|---|
| GitHub | Manifests, application source, commit metadata | Operational | Source of truth |
| Cloudflare | DNS queries and zone records for every hostname — **plus, for the Cloudflare-proxied `bitwarden.example.com` route, decrypted HTTP request bodies including vault authentication traffic** | Operational + **Secret-adjacent** | Authoritative DNS; reverse proxy for the public bitwarden host. **This is the single largest plaintext-exposure surface to a third party on the platform** and deserves a deliberate decision: either accept it, or serve bitwarden DNS-only like the `*.int` hosts and rely on `rate-limit-public` instead of the `-cf` variant |
| Let's Encrypt / CT logs | Hostnames | Operational (public) | Certificate issuance |
| Discord | Alert contents: hostnames, namespaces, workloads, failure detail | Operational | Alert delivery. **The highest-volume unnecessary egress on the platform** — worth revisiting when WP8 adds a second receiver |
| SMTP provider | Recipient addresses, message bodies | **Personal** | Invites, recovery, notifications |
| Container registries | Pull requests only (image name + auth) | Operational | Image distribution |

**No user content — WordPress data, Nextcloud files, Jellyfin libraries, NAS
shares — leaves the platform to any third party.** All of it is on self-hosted
storage. That is the single strongest privacy property this platform has and it
is deliberate.

**One qualification, added 2026-08-07:** the claim above is about *stored*
content. It does not hold for traffic on the Cloudflare-proxied
`bitwarden.example.com` route, where Cloudflare terminates TLS. Vault
ciphertext stays encrypted under the user's own key, but authentication traffic
transits a third party in the clear. Recorded here rather than left implicit.

## 4. Supplier security assessment

| A.5.19–A.5.23 requirement | Status |
|---|---|
| Security requirements agreed with suppliers | **Not met.** Standard published terms accepted; no negotiation possible on free/consumer tiers |
| Security addressed in supplier agreements | **Not met.** No bespoke agreements exist |
| ICT supply chain managed | **Partially met.** Components are pinned in git and deployed via GitOps, giving a reviewable change path — but images are largely unpinned by digest and unscanned (RISK-15) |
| Supplier services monitored and reviewed | **Partially met.** Availability is monitored (Gatus, Prometheus); security posture is not reviewed |
| Cloud service security | **Partially met.** Cloud use is deliberately minimal — GitHub, Cloudflare, Let's Encrypt, registries, SMTP. Everything with user data is self-hosted |

**Overall assessment: this is a small self-hosted platform whose principal
supplier-risk mitigation is not using suppliers.** The three that matter —
GitHub, Cloudflare, Let's Encrypt — are each individually replaceable within
hours to days, and none of them holds user content.

## 5. Concentration and single points of failure

- **GitHub** is the only source of truth and also the CI provider and also the
  self-hosted runner registrar. Losing the account is the largest single-vendor
  event. Mitigation: every repository is fully cloned locally, and an ArgoCD
  `repoURL` repoint has been performed before and is documented.
- **Cloudflare** holds DNS for every published hostname; compromise permits
  hijack of all of them, including the ACME DNS-01 challenge path.
- **Discord** is the only alert delivery path — a supplier outage means silent
  monitoring (GAP-M4).
- **The productie Proxmox host** carries cp1, cp2, TrueNAS and the runner. Not a
  vendor risk, but the largest concentration on the platform
  (`business-continuity-plan.md` §3.2).

## 6. Review

Reviewed quarterly with the access review. Add a vendor before first production
use, not after. Record at minimum: what data it can see, criticality, the access
it holds, and the exit path — the last column is the one that turns this register
from paperwork into a decision aid.
