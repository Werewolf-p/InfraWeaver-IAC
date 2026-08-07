# Information Security Policy

| | |
|---|---|
| **Document ID** | ISMS-POL-001 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner / Approver** | Platform Owner |
| **Next review** | 2027-02-07 (semi-annual, or on material change) |
| **Controls** | ISO/IEC 27001:2022 cl. 5.2, A.5.1, A.5.2, A.5.4, A.5.36, A.5.37 · SOC 2 CC1.1–CC1.5, CC2.2, CC5.3 |

---

## 1. Purpose and honest scoping statement

This is the top-level information security policy for the **InfraWeaver platform**:
a three-node Talos Kubernetes cluster running on self-hosted Proxmox hypervisors,
its GitOps repositories, and the identity, storage, and application services it
hosts for a small number of named users.

It is written for a platform with **one operator**. Every ISO 27001 and SOC 2
control framework assumes an organisation with separable duties, a hiring
process, and a management review board. This platform has none of those. Rather
than fabricate them, this policy states plainly where a control is met by
technical means, where it is met by a compensating control, and where it is
**not met** and tracked as an accepted risk.

An auditor reading this document should be able to verify every claim it makes
by running a command from `evidence-index.md`. Claims that cannot be verified
that way are marked as gaps, not as controls.

## 2. Scope

**In scope**

| Domain | Assets |
|---|---|
| Compute | `talos-prod-cp1/2/3` (Talos v1.13.0, Kubernetes v1.35.4), converged control-plane |
| Virtualisation | Proxmox hosts `10.1.0.3` (productie) and `10.1.0.4` (microserver/ontwikkel) and their VMs |
| Source of truth | `InfraWeaver-infra` (GitOps manifests), `InfraWeaver-platform` (application monorepo), `InfraWeaver-base` (Terraform/OpenTofu for Proxmox) |
| Identity | Authentik (OIDC + LDAP outpost), `users.yaml` access register, ArgoCD RBAC, Kubernetes RBAC |
| Secrets | OpenBao + External Secrets Operator; SOPS/age for Terraform variables |
| Data | All PersistentVolumeClaims enumerated in `asset-inventory.md` §7, plus TrueNAS and Synology NAS shares |
| Edge | Traefik ingress, Cloudflare DNS, Let's Encrypt certificates, all published hostnames |

**Explicitly out of scope**

- End-user personal devices. There is no MDM, no endpoint agent, and no
  corporate device fleet. Access is from the operator's own machines.
- Physical security of the premises. The hardware sits in a private residence,
  not a data centre. See A.7 in `statement-of-applicability.md` — the entire
  physical control family is handled as inherited-from-residence with a stated
  justification, not claimed as implemented.
- Employment lifecycle controls (screening, disciplinary process, termination).
  There are no employees.

## 3. Roles and responsibilities

There is **one person**. Naming three role titles and assigning them all to the
same individual would be theatre. Instead this policy names the *functions* that
must happen and states who performs them:

| Function | Performed by | Reality check |
|---|---|---|
| Risk acceptance and policy approval | Platform Owner | No independent approver exists. Every acceptance in `risk-register.md` is self-approved and says so. |
| Day-to-day operation, change authoring, change approval | Platform Owner | **Segregation of duties is not achievable** (A.5.3). Compensating controls in §4. |
| Incident response commander | Platform Owner | Single responder; see `incident-response-plan.md` §3 for what this means for response time and for the single-person-dependency risk. |
| Access approval | Platform Owner | All grants recorded in `users.yaml` with `grantedBy` and `grantedAt`. |
| Independent security review | **Not performed by a person.** Substituted by automated review: CI gates, Kyverno policy reports, and periodic AI-assisted audits (the audit that produced this pack, 2026-08-07). | A.5.35 is recorded as **partially met** — automated and self-review only. An external review has never taken place. |

**Single-person dependency (RISK-08)** is the largest organisational risk on
this platform and is recorded as such. The compensating controls are: everything
is in git and reproducible; the break-glass procedure (pending WP11) will be
documented and tested; backups will be restorable by a third party following
`business-continuity-plan.md`. Those are mitigations, not a fix. A second
operator is the only real fix and does not exist.

## 4. Compensating controls for absent segregation of duties

Because the same person writes, approves, and applies every change, the
integrity of change control rests on machine-enforced gates rather than human
separation:

1. **Everything is GitOps.** 61 ArgoCD Applications, 60 with auto-sync. The
   cluster converges to git; direct `kubectl apply` is not the change path.
2. **CI gates run on every pull request** and cannot be skipped by intent alone
   — kustomize render, kubeconform schema validation, a secret-leak ratchet,
   a cron-secret seed gate, promtool alert-rule validation, a NetworkPolicy
   port-vs-Service gate, shellcheck, ruff, and `tofu fmt`/`validate`. See
   `secure-development-policy.md` §3.
3. **Admission control** — Kyverno (19 ClusterPolicies) and Pod Security
   Admission evaluate every workload at admission time regardless of who
   submitted it.
4. **Immutable-ish audit trail** — git history plus the Kubernetes API server
   audit log record what changed and when.

Gap, stated honestly: **branch protection cannot be enabled** on any of the
three repositories (GitHub free plan on private repos returns HTTP 403). The
gates above therefore *run* but are not *required* — nothing technically
prevents a direct push to `main`. This is RISK-02 and is the single most
important open item in this pack. WP1 addresses it by making CODEOWNERS +
dispatch-only Terraform apply the enforced path.

## 5. Security principles

These are the principles the platform is actually built on, each traceable to
running configuration:

1. **No secrets in git.** Secrets live in OpenBao and reach the cluster through
   External Secrets Operator; Terraform variables are SOPS/age-encrypted. CI
   enforces this with a secret-leak gate that ratchets (new leaks blocked, old
   ones tracked to zero — the baseline list is currently empty).
2. **Identity is centralised.** Authentik is the single identity provider;
   admin surfaces sit behind Traefik `forward-auth`. There is no local password
   per application for human access.
3. **Deny by default at the network layer** where it has been rolled out —
   default-deny ingress *and* egress in `argocd`, `authentik`, `cert-manager`,
   `external-dns`, `external-secrets`, `falco`, `infraweaver-console`, `kyverno`,
   and `openbao`, plus Cilium "airgap-baseline" policies across 25 namespaces.
   Seven namespaces still have no policy at all (GAP-H2 / WP6).
4. **Least privilege, aspirationally.** Currently violated by one standing
   cluster-admin ServiceAccount with a non-expiring token (GAP-C3 / WP3) and by
   44 pods running on automounted `default` ServiceAccount tokens (GAP-H3).
5. **Encryption everywhere it is cheap.** etcd secrets encrypted at rest
   (`secretbox`), TLS 1.2+ on the API server and 1.3 on kubelet/KCM/scheduler,
   Let's Encrypt certificates on all published hostnames.
6. **Evidence over assertion.** Every control claim in this pack carries a
   re-runnable command in `evidence-index.md`.

## 6. Information classification

Three classes. More would not be used.

| Class | Definition | Handling rule |
|---|---|---|
| **Secret** | Compromise grants access to other systems | Only in OpenBao or SOPS/age. Never in git, never in a pod env literal, never in a document in this directory. Access via ESO or short-lived token. |
| **Personal** | Identifies a natural person; GDPR applies | Minimum necessary collection. Held in Authentik, `users.yaml`, Nextcloud, Jellyfin, WordPress. Retention per `logging-and-retention-policy.md` §6. |
| **Operational** | Everything else | Public-by-default within the platform; the GitOps manifests are mirrored to a public template repository after sanitisation. |

Known live violation of the Secret handling rule: `game-hub/gt-new-horizons`
carries `RCON_PASSWORD` as a literal pod environment value (GAP-H7, WP10).

## 7. Acceptable use

Applies to the operator and to every user granted access via `users.yaml`:

- Accounts are personal and not shared. Service accounts are for machines only.
- Do not disable or bypass a security control (PSA label, NetworkPolicy,
  forward-auth middleware) to make something work. Change it in git with a
  recorded reason instead.
- Do not commit a secret. If one is committed, treat it as disclosed and follow
  `incident-response-plan.md` §7 (credential compromise) — rotation, not
  history rewriting, is the fix.
- Platform data hosted for other users (WordPress sites, Nextcloud files,
  Jellyfin libraries) is theirs. Administrative access is not licence to read
  it absent an operational need.

## 8. Policy set

This policy sits above:

| Document | Covers |
|---|---|
| `access-control-policy.md` | Identity, authentication, authorisation, privileged access |
| `access-review-procedure.md` | Quarterly review method |
| `secure-development-policy.md` | SDLC, CI gates, change management |
| `logging-and-retention-policy.md` | Logging, monitoring, retention periods |
| `incident-response-plan.md` | Detection, triage, response, post-mortem |
| `business-continuity-plan.md` | Backup, restore, DR, RTO/RPO |
| `risk-register.md` | Identified risks, treatment, acceptances |
| `statement-of-applicability.md` | All 93 Annex A controls, applicability and status |
| `asset-inventory.md` | Generated inventory of everything in scope |
| `vendor-register.md` | Third parties and the data they touch |
| `evidence-index.md` | Control → artifact → re-runnable command |

## 9. Compliance, exceptions and enforcement

- **Compliance monitoring** is automated: CI on every PR, Kyverno PolicyReports
  continuously, and the quarterly access review. There is no manual audit
  programme.
- **Exceptions** are recorded in `risk-register.md` with an owner, a rationale,
  and a review date — not granted verbally. An exception that is not in the
  register does not exist.
- **Enforcement**: for the operator, self-enforcement. For platform users,
  access removal via `users.yaml` and Authentik.

## 10. Review

Reviewed semi-annually and on any of: a security incident at severity SEV-2 or
above, a change to the trust model (new external service, new user class,
authentication change), or completion of any work package WP1–WP11, since each
changes the truth of the statements above.

**Change log**

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-08-07 | Initial issue. Created as part of WP7 closing GAP-C4 (no ISMS artifacts existed anywhere in either repository). |
