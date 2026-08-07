# Access Control Policy

| | |
|---|---|
| **Document ID** | ISMS-POL-002 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | 2027-02-07 |
| **Controls** | ISO/IEC 27001:2022 A.5.15, A.5.16, A.5.17, A.5.18, A.6.7, A.8.2, A.8.3, A.8.4, A.8.5, A.8.18 · SOC 2 CC6.1, CC6.2, CC6.3, CC6.6 |

---

## 1. Scope

Every identity that can reach a platform resource: human users, Kubernetes
ServiceAccounts, CI credentials, and the Terraform/Proxmox automation identity.

## 2. Identity model

There is exactly one authoritative identity provider for humans: **Authentik**.
Applications either federate to it via OIDC/LDAP, or sit behind Traefik
`forward-auth`, which requires an Authentik session before the request reaches
the backend.

| Layer | Authority | Where it is declared |
|---|---|---|
| Human identity | Authentik (OIDC + LDAP outpost) | Authentik database; **not currently in git** — see RISK-07 / WP11 |
| Human authorisation register | `users.yaml` | Repository root, reviewed in git |
| Console authorisation | `platform.yaml` → `console.rbac` (group → role → permissions) | Repository root |
| ArgoCD authorisation | `argocd-rbac-cm` `policy.csv` | `kubernetes/core/argocd/` |
| Cluster authorisation | Kubernetes RBAC | GitOps manifests, **except one binding that is not in git** — RISK-09 |
| Secrets authorisation | OpenBao policies | OpenBao |
| Hypervisor | Proxmox local users + API tokens | Proxmox host; Terraform credential in SOPS/age |

`users.yaml` is the access register of record for humans. Every grant carries
`roleId`, `scope`, `principalType`, `principalId`, `grantedBy` and `grantedAt` —
which is what makes the quarterly review possible at all.

## 3. Account lifecycle

**Provisioning.** A human account is created only through the console's invite/
enrolment flow, which writes the grant into `users.yaml` with a `grantedBy` and
`grantedAt` and creates the corresponding Authentik user and group memberships.
Manual account creation directly in Authentik is not the sanctioned path,
because it produces an identity with no register entry.

**Modification.** Role changes are edits to `users.yaml` role assignments, made
through the console RBAC surface so that provenance fields are written.

**Deprovisioning.** Removal must cover *all* of: the `users.yaml` entry,
Authentik user deactivation, Authentik group memberships, per-application
groups (WordPress site groups, storage share groups), and any NAS share
assignment. A user removed from `users.yaml` alone remains able to authenticate.

**Deactivation over deletion.** Authentik accounts are deactivated
(`is_active = false`) rather than deleted, so the audit trail survives. The
`koen` account is currently in this state.

## 4. Authentication requirements

| Requirement | Status |
|---|---|
| Centralised SSO for all human access | **Met** — Authentik fronts every admin surface via forward-auth or OIDC |
| Built-in ArgoCD admin login disabled | **Met** — `argocd-cm` `admin.enabled: false` |
| Session lifetime bounded | **Met** — console JWT max age 8h |
| TLS on every published endpoint | **Met** — Let's Encrypt via cert-manager, wildcard public and internal certs |
| **Multi-factor authentication** | **NOT MET.** Zero enrolled second factors of any type across all accounts; no authenticator-validation stage bound to the authentication flow. RISK-07, remediated by WP11. |
| Password policy | **Not evidenced.** Authentik defaults apply; no policy is declared as code. Pending WP11 blueprint export. |

MFA is the single largest authentication gap on this platform and is stated as
not met rather than dressed up. See `risk-register.md` RISK-07 for the measured
evidence.

## 5. Authorisation principles

1. **Least privilege.** Grant the narrowest scope that works. Scopes in
   `users.yaml` are paths (`/`, `/wiki`, `/jellyfin`,
   `/wordpress/sites/<site>`, `/nas/truenas/...`), so a grant is naturally
   bounded to one surface.
2. **Group-based, not per-user, for platform roles.** Console and ArgoCD roles
   derive from Authentik group membership (`platform-admins`,
   `platform-operators`, `platform-users`), not from individual mappings.
3. **Deny wins.** A role assignment carrying `effect: Deny` overrides an Allow
   at the same or broader scope. (This evaluation had a defect where Deny was
   counted as a grant; fixed 2026-08-06 — any review performed before that date
   is unreliable.)
4. **Default deny for unknown principals.** ArgoCD `policy.default` is
   `role:readonly`; the console denies by default outside a mapped group.
5. **Service accounts are for machines.** A ServiceAccount used as a standing
   human credential is a finding, not a design.

## 6. Privileged access

**Definition.** Privileged access on this platform means any of: Kubernetes
`cluster-admin`, ArgoCD `role:admin`, Authentik superuser, OpenBao root or a
policy granting broad secret read, Proxmox root/PAM or an API token with VM
lifecycle rights, or Talos `os:admin`.

**Rules.**
- Privileged access is minted **short-lived** where the platform supports it —
  `kubectl create token <sa> --duration=<n>h` rather than a static Secret.
- Static, non-expiring ServiceAccount token Secrets are prohibited. **One
  currently exists in violation** (`infraweaver-system/claude-platform-owner-token`,
  cluster-admin, non-expiring) — RISK-09, remediated by WP3.
- Every privileged binding must be declared in git. One is not (RISK-09).
- Operator-managed privileged bindings (e.g. Longhorn's support-bundle
  ServiceAccount) are permitted only where the operator recreates them on demand
  and the binding is documented as such.

**Break-glass.** A documented break-glass credential procedure does **not yet
exist**. It is a WP11 deliverable (`docs/BREAK-GLASS.md`) and is a hard
prerequisite for enforcing MFA — a single admin locking themselves out of their
own identity provider is a self-inflicted outage.

## 7. Access to source code (A.8.4)

Three private GitHub repositories under a single owner account. Read and write
access is the GitHub account's own. **Branch protection cannot be enabled**
(free plan, HTTP 403 — RISK-02), so repository-level authorisation is
account-level only, with CI gates and (pending WP1) CODEOWNERS as the
compensating controls. A public, sanitised template mirror is published by the
`sync-to-public` workflow; the secret-leak CI gate is what stands between the
private and public trees.

## 8. Remote working (A.6.7)

All access is remote by construction — the operator administers the platform
from personal machines over the internet, gated by Authentik. There is no VPN
tier: the previous VPN was retired deliberately, and internal (`*.int.`)
hostnames are protected by forward-auth rather than by network position. This
means **Authentik is the only boundary** for internal services, which is why
RISK-07 (no MFA) is scored Critical.

There is no managed device fleet, no MDM, and no endpoint protection on the
machines used for administration (A.8.1). This is stated as a scope exclusion in
`information-security-policy.md` §2, not claimed as a control.

## 9. Review

Access is reviewed quarterly per `access-review-procedure.md`. The first review
was executed on 2026-08-07 and is recorded in `access-review-2026-Q3.md`.
