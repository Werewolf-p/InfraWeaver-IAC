# Access Review — 2026 Q3

| | |
|---|---|
| **Document ID** | ISMS-REC-001 |
| **Review date** | 2026-08-07 |
| **Reviewer** | Platform Owner (self-review — see `access-review-procedure.md` §2) |
| **Period covered** | Platform inception → 2026-08-07 |
| **Method** | `access-review-procedure.md` v1.0, all five surfaces |
| **Next review due** | 2026-11-02 |
| **Controls** | ISO/IEC 27001:2022 A.5.15, A.5.16, A.5.18, A.8.2, A.8.3 · SOC 2 CC6.1, CC6.2, CC6.3 |

---

## 0. Status

**This is the first access review ever performed on this platform.** Before
2026-08-07 no periodic review procedure or record existed (GAP-M8). Every
finding below is therefore a first-time finding, and no "since last review"
comparison is possible.

All evidence was gathered with read-only commands on 2026-08-07. Raw outputs are
reproduced below rather than summarised, so a third party can re-run the same
commands and diff.

**Important reliability caveat.** The console's effective-rights calculation had
a defect in which a `Deny` role assignment was counted as a grant, and users
holding rights only through a group read as "holds nothing". That defect was
fixed on 2026-08-06 (branch under review at the time of this review). This review
therefore deliberately reads the **underlying sources** — `users.yaml`, the
Authentik database, and the Kubernetes API — rather than the console's computed
view.

---

## 1. Surface 1 — `users.yaml` register

Source: `users.yaml` at repository root, branch `fix/console-reader-rbac-inventory`.

| User | Email | Role assignments | Granted by | Disposition |
|---|---|---|---|---|
| `admin` | example-owner@gmail.com | `platform-owner` @ `/`; `wiki-editor` @ `/wiki` | self, 2026-01-01 | **Retain** (platform-owner) / **Revoke** (wiki-editor — see F-03) |
| `sindala` | jellyfin.knee499@passmail.net | `jellyfin-user` @ `/jellyfin`; `storage-contributor` @ `/nas/truenas/infraweaver/media` | enrollment, 2026-07-14 | **Retain** |
| `koen1` | koenluppers@gmail.com | `wordpress-viewer` @ `/wordpress/sites/yonavaarwater-nl` (effect: Allow) | example-owner@gmail.com, 2026-08-03 | **Retain** |
| `zonnevaarwater` | zonne.vaarwater@gmail.com | `wordpress-admin` @ `/wordpress/sites/zonnevaarwater-nl` (Allow) | example-owner@gmail.com, 2026-08-04 | **Retain** |
| `Yona` | yona.vaarwater@gmail.com | `wordpress-admin` @ `/wordpress/sites/yonavaarwater-nl` (Allow) | example-owner@gmail.com, 2026-08-04 | **Retain** |

**Assessment.** Five human principals, nine role assignments. Every grant carries
`grantedBy` and `grantedAt`; provenance is complete. Scoping is genuinely least
privilege for the four non-owner users — each is bounded to a single WordPress
site or a single NAS path. No grant is over-broad except as noted in F-03.

No `Deny` assignments exist anywhere in the register, so the 2026-08-06 Deny
defect had no live effect on these five users. That is fortunate, not by design.

---

## 2. Surface 2 — Authentik users, groups and second factors

### 2.1 Accounts

```
username                                  | active | type                     | last_login | joined
ak-outpost-a260cef19bdf400cb2a88afe8147c5d7|   t    | internal_service_account | never      | 2026-06-13
AnonymousUser                             |   t    | internal                 | never      | 2026-06-13
koen                                      |   f    | internal                 | 2026-08-03 | 2026-08-03
koen1                                     |   t    | internal                 | 2026-08-03 | 2026-08-03
admin                                     |   t    | internal                 | 2026-08-07 | 2026-06-14
sindala                                   |   t    | internal                 | 2026-07-14 | 2026-07-14
Yona                                      |   t    | internal                 | 2026-08-04 | 2026-08-04
zonnevaarwater                            |   t    | internal                 | 2026-08-04 | 2026-08-04
```

- 5 active human accounts, exactly matching `users.yaml`. **No orphans in either
  direction.** This is the strongest result in the review.
- `koen` is deactivated (`is_active = f`), created and superseded by `koen1` on
  the same day. Correct handling — deactivation rather than deletion preserves
  the trail. **Retain (deactivated).**
- `ak-outpost-…` and `AnonymousUser` are Authentik-internal service principals.
  **Retain.**

### 2.2 Group membership

```
koen1          | wordpress-yonavaarwater-nl-access
admin          | authentik Admins
admin          | platform-admins
admin          | storage-truenas-infraweaver-media-c9e46201be8c-ro
admin          | storage-truenas-infraweaver-media-c9e46201be8c-rw
admin          | storage-truenas-infraweaver-ro
admin          | storage-truenas-infraweaver-rw
admin          | storage-truenas-share-ro
admin          | storage-truenas-share-rw
admin          | wordpress-hi2-access
admin          | wordpress-hihi-access
admin          | wordpress-lol-access
admin          | wordpress-lolll-access
admin          | wordpress-test-access
admin          | wordpress-yonavaarwater-nl-access
admin          | wordpress-zonnevaarwater-nl-access
sindala        | storage-truenas-infraweaver-media-c9e46201be8c-ro
sindala        | storage-truenas-infraweaver-media-c9e46201be8c-rw
Yona           | wordpress-yonavaarwater-nl-access
zonnevaarwater | wordpress-zonnevaarwater-nl-access
```

31 groups exist; **15 have zero members**: `authentik Read-only`,
`infra-automation`, `infra-containers`, `infra-gitops`, `infra-network`,
`infra-proxmox`, `infra-storage`, `infra-truenas`, `infra-vault`, `nc-media-ro`,
`nc-media-rw`, `nc-synology`, `nc-truenas`, `nc-users`, and — significantly —
`platform-users`.

### 2.3 Second factors

```
totp     | 0
webauthn | 0
static   | 0
duo      | 0
sms      | 0
```

**Zero enrolled second factors across every account, including the platform
owner.** No authenticator-validation stage is bound to
`default-authentication-flow`. Setup flows exist
(`default-authenticator-totp-setup`, `default-authenticator-webauthn-setup`) but
are unreachable from the authentication path.

---

## 3. Surface 3 — Authentik application access bindings

72 registered applications, 71 policy bindings. **13 applications have no policy
binding at all**, meaning any authenticated user reaches them:

```
forgejo, gitea, grafana, infraweaver-console, onedev, portainer,
proxmox, route-truenas, tradesphere, vaultwarden, wikijs,
wordpress-ssoe2e, wordpress-ssoe2e-gate
```

Cross-referenced against the live ArgoCD application list and namespace
inventory:

| Application | Live? | Assessment |
|---|---|---|
| `grafana` | Yes (`apps-grafana`) | Unbound — F-01 |
| `infraweaver-console` | Yes | Unbound, but the console applies its own group-based RBAC (`platform.yaml` → `console.rbac`) and denies by default. Lower severity — F-01 |
| `tradesphere` | Yes | Unbound — F-01 |
| `proxmox` | Yes (external hypervisor UI) | Unbound — **highest concern in F-01**; this is the hypervisor |
| `route-truenas` | Yes (external NAS) | Unbound — F-01 |
| `vaultwarden` | Yes (bare-metal backend `bm-bitwarden`, published at `bitwarden.example.com`) | Unbound at Authentik *and* the route carries no forward-auth (RISK-06). Application-level auth only |
| `forgejo`, `gitea`, `onedev`, `portainer`, `wikijs` | **No** — no namespace, no ArgoCD application | Stale registrations — F-02 |
| `wordpress-ssoe2e`, `wordpress-ssoe2e-gate` | Test artifacts | Stale registrations — F-02 |

Sampled bound applications for contrast: `jellyfin-fwd` (1 binding),
`nextcloud` (1 binding) — these are correctly gated.

---

## 4. Surface 4 — ArgoCD and Kubernetes authorisation

### 4.1 ArgoCD

```
policy.csv:
  g, admin, role:admin
  g, platform-admins, role:admin
  g, platform-users, role:readonly
policy.default: role:readonly
scopes: "[groups]"
admin.enabled: false
```

Default-deny posture is correct (`role:readonly` default, built-in admin login
disabled). Two observations:

- `argocd-cm` `oidc.config.requestedScopes` is `openid, profile, email` — it does
  **not** request `groups`, while `argocd-rbac-cm` sets `scopes: "[groups]"`.
  Unless Authentik attaches a groups claim to the `argocd` provider's ID token
  independently of the requested scopes, the `platform-admins → role:admin`
  mapping never matches and every OIDC user lands on `role:readonly`. This fails
  *safe* (readonly, not admin), so it is an observation rather than an exposure —
  but it means the documented admin mapping may be inert. **F-04, verify.**
- `platform-users → role:readonly` maps a group that currently has **zero
  members** (§2.2), so it grants nothing today.

### 4.2 Kubernetes cluster-admin

```
claude-platform-owner : ServiceAccount/infraweaver-system/claude-platform-owner
cluster-admin         : Group/system:masters
longhorn-support-bundle: ServiceAccount/longhorn-system/longhorn-support-bundle
```

### 4.3 Static ServiceAccount token Secrets

```
NAMESPACE             NAME                            CREATED
infraweaver-console   infraweaver-console-sa-token    2026-06-13T22:18:50Z   (55 days)
infraweaver-system    claude-platform-owner-token     2026-06-29T04:05:47Z   (39 days)
```

Both are non-expiring `kubernetes.io/service-account-token` Secrets, which
`access-control-policy.md` §6 prohibits. They differ materially:

- `infraweaver-console-sa-token` **is declared in git**
  (`kubernetes/catalog/infraweaver-console/base/service-account.yaml`) and its
  ServiceAccount is bound to scoped reader roles
  (`infraweaver-console-reader`), **not** cluster-admin. Managed, over-privileged
  in lifetime only. **F-06.**
- `claude-platform-owner-token` **is not declared anywhere in git**
  (`grep -rln claude-platform-owner kubernetes/` returns nothing) and its
  ServiceAccount holds **cluster-admin**. **F-05 — the most serious finding in
  this review.**

### 4.4 ArgoCD AppProjects

```
{"default": 6, "infraweaver-prod": 9, "platform": 46}
```

Six applications sit in the unrestricted `default` AppProject
(`catalog-game-hub-networks`, `core-metallb-manifests`,
`core-network-policies`, `external-routes`, `private-test`, `tradesphere`) — no
`sourceRepos` or `destinations` pinning. **F-07.**

---

## 5. Surface 5 — access outside the cluster

Recorded by inspection on 2026-08-07; no API-derived evidence was collected for
this surface, which is itself a weakness of this first review.

| System | Access | Disposition |
|---|---|---|
| Proxmox `10.1.0.3` / `10.1.0.4` | `root` via SSH key (`~/.ssh/deployer_ed25519`), plus a Terraform API token held SOPS/age-encrypted in `envs/*/secrets.sops.yaml` | **Retain**; no per-operation audit trail exists. Recorded as a limitation |
| TrueNAS `10.1.0.135` / Synology `10.1.0.21` | `infraweaver-svc` service accounts; credentials at `secret/platform/nas/providers` in OpenBao | **Retain** |
| GitHub (3 private repos, owner `example-owner`) | Single owner account; no additional collaborators identified | **Retain**; branch protection unavailable (RISK-02) |
| OpenBao | Policies not enumerated in this review; no audit device is configured, so secret access is unevidenced | **Investigate** — F-08 |

---

## 6. Findings and actions

| ID | Finding | Severity | Disposition | Action / owner |
|---|---|---|---|---|
| **F-01** | 6 live applications have no Authentik access policy binding (`proxmox`, `grafana`, `tradesphere`, `route-truenas`, `vaultwarden`, `infraweaver-console`) — reachable by any authenticated user. With 5 users the blast radius is small, but `proxmox` is the hypervisor. | **High** | Reduce | Bind each to `platform-admins` (or the appropriate group) before the next review. New risk-register candidate; not currently owned by a work package. |
| **F-02** | 7 stale Authentik application registrations for services that no longer exist (`forgejo`, `gitea`, `onedev`, `portainer`, `wikijs`, `wordpress-ssoe2e`, `wordpress-ssoe2e-gate`). | Medium | Revoke | Deregister. Fold into WP11's blueprint export so removal is captured as code. |
| **F-03** | `admin` holds `wiki-editor` @ `/wiki` and `wiki_role: admin` in `users.yaml`, and `authentik_groups` declares `wiki-admins` and `platform-users`. **No wiki is deployed** (no `wiki` namespace, no ArgoCD app, not in `platform.yaml` `catalog.enabled`), **no `wiki-admins` group exists in Authentik**, and `admin` is **not** in `platform-users` live. | Medium | Revoke / reconcile | `users.yaml` declares access to a non-existent service and non-existent group — register drift. Remove the wiki grant, or reconcile `authentik_groups` to live membership. |
| **F-04** | ArgoCD OIDC does not request the `groups` scope while RBAC expects it; the `platform-admins → role:admin` mapping may be inert. Fails safe. | Low (observation) | Investigate | Verify by inspecting a live ID token's claims, or by adding `groups` to `requestedScopes` in `kubernetes/core/argocd/values.yaml:286`. Not owned by a work package. |
| **F-05** | `claude-platform-owner` holds cluster-admin via a binding that exists nowhere in git, with a 39-day-old non-expiring static token Secret. | **Critical** | Revoke | RISK-09; **WP3** is remediating. Replacement scoped role must be verified working before the token is deleted. |
| **F-06** | `infraweaver-console-sa-token` is a second non-expiring static SA token (55 days). Git-declared and bound only to scoped reader roles, so far less severe than F-05 — but still a violation of the no-static-tokens rule. **This one was not in the original audit and was found by this review.** | Medium | Reduce | Migrate to projected/bound tokens. Suggest folding into WP3 since it owns `kubernetes/core/rbac/`. |
| **F-07** | 6 ArgoCD Applications in the unrestricted `default` AppProject. | High | Reduce | GAP-H9; **WP1** is remediating. |
| **F-08** | OpenBao policies were not enumerated and no audit device is configured, so secret access cannot be reviewed at all. | High | Investigate | GAP-M6; **WP10** enables the audit device. The next review must include an OpenBao policy enumeration — this review could not perform one. |
| **F-09** | **Zero MFA enrolment platform-wide**, including the account that holds `platform-admins`, `authentik Admins`, and effectively every downstream right. | **Critical** | Reduce | RISK-07; **WP11** is remediating, staged behind a break-glass procedure. |
| **F-10** | 15 of 31 Authentik groups have zero members, including `platform-users`, which both `platform.yaml` `console.rbac` and ArgoCD RBAC reference. Unused groups are latent privilege waiting to be granted by accident. | Low | Reduce | Delete the `infra-*` and `nc-*` groups if the services they gated are gone; keep `platform-users` (it is a referenced role target). |

**Counts:** 2 Critical, 3 High, 3 Medium, 2 Low.
**Dispositions:** Retain 5 principals · Reduce 5 findings · Revoke 3 findings · Investigate 2 findings.

---

## 7. Reviewer conclusion

The **human access register is in good shape**: five users, nine grants, complete
provenance, exact 1:1 correspondence between `users.yaml` and active Authentik
accounts, genuinely least-privilege scoping, and correct use of deactivation
rather than deletion. For a platform that had no review procedure at all until
today, that is a better starting position than expected.

The failures are not in *who* has access but in *how strongly it is held and how
it is enforced*:

1. **No second factor exists anywhere.** One password stands between an
   attacker and a Kubernetes cluster, a vault, a hypervisor fleet, and other
   people's personal data. (F-09)
2. **A cluster-admin credential exists outside git and never expires.** (F-05)
3. **Six live applications, including the Proxmox UI, are reachable by any
   authenticated user.** (F-01)
4. **Registration drift in both directions** — `users.yaml` references a service
   and a group that do not exist; Authentik holds seven registrations for
   services that do not exist. (F-02, F-03)

Two findings (F-06, F-01) were **not** present in the 2026-08-07 platform audit
and were surfaced by this review, which is the argument for the procedure
existing at all.

**Next review due 2026-11-02.** It must additionally cover: OpenBao policy
enumeration (impossible this quarter — F-08), verification that MFA enrolment is
non-zero, and a re-check that F-01/F-02/F-03 have been closed.
