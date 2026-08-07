# Statement of Applicability — ISO/IEC 27001:2022 Annex A

| | |
|---|---|
| **Document ID** | ISMS-SOA-001 |
| **Version** | 1.1 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner / Approver** | Platform Owner (self-approved — see `risk-register.md` risk-owner caveat) |
| **Next review** | 2027-02-07, and on completion of any work package WP1–WP11 |
| **Standard** | ISO/IEC 27001:2022, Annex A (93 controls) |
| **Controls** | ISO/IEC 27001:2022 cl. 6.1.3 d) |

---

## 1. How to read this document

This SoA covers **all 93 Annex A controls**. For each it records whether the
control is **applicable**, its **implementation status**, and either the artifact
that evidences it or the risk-register entry that accepts its absence.

**This SoA deliberately contains a large number of open items.** Sixty-seven of
the eighty-three applicable controls are partially or not implemented. That is
the honest position of a platform whose ISMS artifacts did not exist until
2026-08-07 and whose backup system produced and passed its first verified
restore on that same day — after 54 days of silent failure — and has yet to
demonstrate a single unattended scheduled backup.

An SoA with open items is auditable — an auditor can see exactly what is missing,
who owns it, and when it is due. An SoA that claims 93 green controls on this
platform would be false, and a false SoA is worse than no certification.

**Status values**

| Status | Meaning |
|---|---|
| **Implemented** | The control operates and can be evidenced today by a command in `evidence-index.md` |
| **Partial** | Some elements operate; named elements do not. The shortfall is stated |
| **Not implemented** | The control does not operate. A risk-register entry accepts it or a work package remediates it |
| **N/A** | The control does not apply to this platform. A justification is given — "we are small" is never sufficient on its own |

**Cross-reference key:** `RISK-nn` → `risk-register.md`; `GAP-xn` → the
2026-08-07 audit gap register; `WPn` → in-flight work package; `F-nn` →
`access-review-2026-Q3.md` finding.

## 2. Summary

| | Count |
|---|---|
| **Total Annex A controls** | **93** |
| **Applicable** | **83** |
| **Not applicable** | **10** |
| — Implemented | **16** |
| — Partial | **53** |
| — Not implemented | **14** |
| **Open items (Partial + Not implemented)** | **67** |

By control family:

| Family | Total | N/A | Implemented | Partial | Not implemented |
|---|---|---|---|---|---|
| A.5 Organizational | 37 | 1 | 9 | 21 | 6 |
| A.6 People | 8 | 5 | 0 | 3 | 0 |
| A.7 Physical | 14 | 2 | 0 | 9 | 3 |
| A.8 Technological | 34 | 2 | 7 | 20 | 5 |
| **Total** | **93** | **10** | **16** | **53** | **14** |

**The 14 not-implemented controls**, so they are impossible to miss:
A.5.3 (segregation of duties), A.5.6 (special interest groups),
A.5.7 (threat intelligence), A.5.13 (labelling), A.5.20 (supplier agreements),
A.5.35 (independent review),
A.7.4 (physical security monitoring), A.7.12 (cabling security),
A.7.14 (secure disposal), A.8.1 (user endpoint devices),
A.8.5 (secure authentication — **MFA**), A.8.7 (protection against malware),
A.8.12 (data leakage prevention), A.8.13 (information backup).
A.5.30 (ICT readiness for business continuity) moved to Partial on 2026-08-07
after the first executed restore drill; see its row.

The two that materially threaten the platform are **A.8.13** (backup chain
proven end to end exactly once, on a scratch volume; no unattended scheduled
backup has ever run) and **A.8.5** (no MFA anywhere — zero enrolled second
factors, re-verified 2026-08-07). **A.5.30** moved to Partial on 2026-08-07:
one restore drill has now been executed and verified, but restore of a
production volume, destructive restore, full rebuild and etcd recovery all
remain unproven. The rest are either scale-appropriate omissions or
physical-environment controls that a residential deployment cannot meet.

---

## 3. A.5 — Organizational controls (37)

| # | Control | Applicable | Status | Justification and evidence |
|---|---|---|---|---|
| A.5.1 | Policies for information security | Yes | **Implemented** | `information-security-policy.md` (ISMS-POL-001) plus the four subordinate policies listed in its §8. Approved and dated 2026-08-07. Closes GAP-C4 |
| A.5.2 | Information security roles and responsibilities | Yes | Partial | `information-security-policy.md` §3 names the *functions* and assigns them all to one person. No independent approver, no security function. RISK-08 |
| A.5.3 | Segregation of duties | Yes | **Not implemented** | **Impossible.** One person authors, approves and applies every change. Compensating controls — GitOps, 7 CI gates, admission control — are documented in `information-security-policy.md` §4 and `secure-development-policy.md` §3. RISK-08 |
| A.5.4 | Management responsibilities | Yes | Partial | The operator is also management; there is no management layer to hold anyone to account. Policy approval and risk acceptance are self-performed and labelled as such |
| A.5.5 | Contact with authorities | Yes | Partial | GDPR Art. 33 notification path to the Dutch DPA identified in `incident-response-plan.md` §6. Never exercised or rehearsed; no other authority contacts established |
| A.5.6 | Contact with special interest groups | Yes | **Not implemented** | No security forum, ISAC or vendor-security-list memberships. Upstream project advisories are consumed ad hoc. Accepted: at this scale the control's cost exceeds its value |
| A.5.7 | Threat intelligence | Yes | **Not implemented** | No threat-intelligence feed, no CVE monitoring for deployed components. Related to RISK-15 (no image scanning). Accepted with the same rationale: unactioned intelligence is not a control |
| A.5.8 | Information security in project management | Yes | Partial | The WP1–WP11 structure requires blast radius, acceptance test, staging order and rollback per package — a genuine security-in-project control. Not formalised as a repeatable process outside this programme |
| A.5.9 | Inventory of information and other associated assets | Yes | **Implemented** | `asset-inventory.md`, generated by `scripts/generate-asset-inventory.py` from `platform.yaml` + live cluster + Proxmox VM inventory. Regenerable, therefore not subject to rot. Closes part of GAP-C4 |
| A.5.10 | Acceptable use of information and other associated assets | Yes | **Implemented** | `information-security-policy.md` §7 |
| A.5.11 | Return of assets | **No** | N/A | No employees, contractors or issued equipment exist. There is nothing to return. User account deprovisioning — the nearest analogue — is covered by A.5.18 and `access-control-policy.md` §3 |
| A.5.12 | Classification of information | Yes | **Implemented** | Three classes (Secret / Personal / Operational) in `information-security-policy.md` §6, applied in `asset-inventory.md` §Classification |
| A.5.13 | Labelling of information | Yes | **Not implemented** | No labelling scheme. Classification is enforced by *location* (secrets only in OpenBao/SOPS) rather than by label. Accepted: labels add no protection when the storage boundary is the control |
| A.5.14 | Information transfer | Yes | Partial | TLS on every published endpoint (Let's Encrypt, TLS 1.2+/1.3); SMTP with `smtp_require_tls: true`. No formal transfer agreements; no encryption-in-transit requirement for NAS SMB/NFS on the internal LAN |
| A.5.15 | Access control | Yes | Partial | `access-control-policy.md`; RBAC across Kubernetes, ArgoCD, console and Authentik; default-deny defaults. **Gap (F-01), partly remediated:** the `50-unbound-application-policies` blueprint is armed and applied (BlueprintInstance `successful`) and unbound Authentik applications fell from 13 to 7; five of F-01's six live applications — `proxmox`, `grafana`, `tradesphere`, `route-truenas`, `infraweaver-console` — now carry bindings (measured 2026-08-07 evening). `vaultwarden` remains unbound, possibly by design (see A.8.21). **Binding existence was measured; enforcement was not** — F-01 stays open until a live challenge test on `proxmox`, the highest-value surface, has been run |
| A.5.16 | Identity management | Yes | **Implemented** | Authentik is the single identity provider. `users.yaml` is the register of record with full `grantedBy`/`grantedAt` provenance. The 2026-Q3 review verified **exact 1:1 correspondence** between the register and active Authentik accounts, in both directions |
| A.5.17 | Authentication information | Yes | Partial | SSO everywhere, forward-auth on admin surfaces, 8h console JWT lifetime, built-in ArgoCD admin disabled, secrets in OpenBao. **Closed 2026-08-07:** the three permanent Authentik credentials — `iw-admin-token` (never-expiring API token owned by the sole superuser; bypassed the login flow and therefore every MFA control) and the permanent recovery tokens `recovery-admin` / `manual-recovery-admin` — were deleted. The console now authenticates as service account `svc-infraweaver-console` with a token expiring 2027-08-07; verified live post-deletion (grant/revoke round-trip from a running console pod), and re-verified 2026-08-07 evening that only the outpost token and `iw-console-api-token` remain (`docs/BREAK-GLASS.md` §10). **Not met:** no MFA (RISK-07, and see A.8.5); no password policy declared as code; the replacement token's expiry is unwatched and its service account is still a superuser (backlog P1.1, P1.4) |
| A.5.18 | Access rights | Yes | Partial | Provisioning/modification/deprovisioning defined (`access-control-policy.md` §3); quarterly review procedure defined and **first review executed** (`access-review-2026-Q3.md`). **Open:** 10 findings from that review, including register drift in both directions (F-02, F-03) |
| A.5.19 | Information security in supplier relationships | Yes | Partial | `vendor-register.md` records every supplier, the data it can see, criticality and exit path. **No security requirements are agreed with any supplier** — all are on standard free/consumer terms with no negotiating position |
| A.5.20 | Addressing information security within supplier agreements | Yes | **Not implemented** | No bespoke supplier agreements exist. Standard published terms accepted as-is. `vendor-register.md` §1 and §4 state this plainly rather than implying otherwise |
| A.5.21 | Managing information security in the ICT supply chain | Yes | Partial | Components are pinned in git and deployed through a reviewable GitOps path. **Not met:** no SBOM, no image signature verification, no CVE scanning. Measured 2026-08-07: 83 distinct images in use, 36 from `docker.io`, none digest-pinned. RISK-15 |
| A.5.22 | Monitoring, review and change management of supplier services | Yes | Partial | Availability monitored (Gatus, Prometheus). Supplier security posture is not reviewed. Vendor review is quarterly per `vendor-register.md` §6 — first cycle due 2026-11-02 |
| A.5.23 | Information security for use of cloud services | Yes | **Implemented** | Cloud use is deliberately minimal: GitHub, Cloudflare, Let's Encrypt, container registries, SMTP. **No user content leaves the platform** — WordPress, Nextcloud, Jellyfin and NAS data are all self-hosted (`vendor-register.md` §3) |
| A.5.24 | Information security incident management planning and preparation | Yes | **Implemented** | `incident-response-plan.md` — severity matrix, response sequence, playbook, post-mortem template, and an explicit statement of single-responder constraints |
| A.5.25 | Assessment and decision on information security events | Yes | **Implemented** | `incident-response-plan.md` §3 severity classification with the escalate-when-unclear rule for a lone responder |
| A.5.26 | Response to information security incidents | Yes | Partial | Documented (`incident-response-plan.md` §4, §7) but **never exercised**. First tabletop due 2026-11-07 |
| A.5.27 | Learning from information security incidents | Yes | Partial | Mechanism defined — post-mortem template, mandatory new detection per incident (§4 Phase 5). Never used, because no incident has been formally recorded |
| A.5.28 | Collection of evidence | Yes | Partial | Kubernetes API audit log at Metadata level for all requests; git history; PolicyReports. **Weak:** audit logs are on-node only with 30-day rotation and share a failure domain with the node they record; Loki retention is undefined in practice. RISK-12, WP8 |
| A.5.29 | Information security during disruption | Yes | Partial | `business-continuity-plan.md` defines tiers, scenarios and objectives. **Most of the capabilities it depends on remain unproven:** a single Longhorn volume restore was executed and checksum-verified on 2026-08-07 (`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §7), but routine unattended backups, production-volume restore, full rebuild and etcd recovery have not been demonstrated — see A.5.30 and A.8.13. RISK-03 |
| A.5.30 | ICT readiness for business continuity | Yes | Partial | First restore drill executed 2026-08-07 and **PASSED**: a Longhorn backup was restored to a new volume, mounted read-only, and checksum-verified 201/201 files (`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §7 drill row; §4a is now a proven procedure — and the drill itself surfaced and fixed the egress defect that had silently blocked all backups for 54 days). **Not proven:** restore of any *production* volume (the drill source was a purpose-built scratch volume — backlog P1.5; the production drill is now *written* and blocked on the first unattended backup run), destructive restore over a live volume (§4b), full cluster rebuild (§4c), and etcd/control-plane restore (§5 — **etcd remains at zero: never snapshotted, never restored, never tabletopped**; backlog P2.5). An SSO-database dump chain now exists in git but is unproven live. RISK-03, WP2 |
| A.5.31 | Legal, statutory, regulatory and contractual requirements | Yes | Partial | GDPR identified as the binding obligation (personal data of five users plus hosted site data); notification path documented. No comprehensive register of legal obligations; no contractual obligations exist |
| A.5.32 | Intellectual property rights | Yes | Partial | Open-source components used under their licences; the public template mirror is published deliberately through a sanitising pipeline. No formal IP or licence-compliance register |
| A.5.33 | Protection of records | Yes | Partial | Git history, access grants, review records and incident records are retained indefinitely (`logging-and-retention-policy.md` §3). **Weak:** operational logs and metrics are retained for days, not months; nothing is tamper-evident, and cluster-admin can alter logs (RISK-09) |
| A.5.34 | Privacy and protection of PII | Yes | Partial | Personal data classified and inventoried; retention defined (`logging-and-retention-policy.md` §6); no user content leaves the platform. **Stated limitations:** no automated DSAR pipeline, and access-grant provenance in git history is never rewritten — an explicit, justified exception to erasure |
| A.5.35 | Independent review of information security | Yes | **Not implemented** | **No external or independent review has ever taken place.** Substituted by automated review (CI gates, Kyverno PolicyReports) and AI-assisted audit — including the 2026-08-07 audit that produced this pack. Both are self-commissioned. `information-security-policy.md` §3 records this. RISK-08 |
| A.5.36 | Compliance with policies, rules and standards | Yes | Partial | Compliance checking is largely automated: 7 CI gates, 19 Kyverno ClusterPolicies, PSA. **But** 18 of 19 policies are Audit-only, and 39 live violations plus 2 policy errors exist. RISK-10, WP4/WP5 |
| A.5.37 | Documented operating procedures | Yes | **Implemented** | `docs/gitops-operating-model.md`, `docs/SECURITY-REMEDIATION-RUNBOOK.md`, `docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md`, `docs/CILIUM-HUBBLE-MIGRATION-RUNBOOK.md`, `docs/cluster-builder.md`, `docs/ADDING-A-NODE.md`, plus this pack. Materially better documented than most platforms of this size |

---

## 4. A.6 — People controls (8)

Five of eight are not applicable. This is the family where a small self-hosted
platform diverges most sharply from the standard's assumptions, and the
justifications below are specific rather than a blanket "no employees".

| # | Control | Applicable | Status | Justification and evidence |
|---|---|---|---|---|
| A.6.1 | Screening | **No** | N/A | There are no employees, contractors or candidates. The only person with access is the platform owner, who is also the data controller. There is no party to screen and no authority to screen them |
| A.6.2 | Terms and conditions of employment | **No** | N/A | No employment relationship exists. Platform users are family and friends granted access to hosted services, not personnel |
| A.6.3 | Information security awareness, education and training | Yes | Partial | The operator's own security learning is self-directed and continuous (this audit is an instance of it). **Platform users receive no security guidance** — no onboarding note about account sharing, phishing or password reuse. With MFA absent (RISK-07), user credential hygiene is the only remaining defence, which makes this gap more material than its size suggests |
| A.6.4 | Disciplinary process | **No** | N/A | No employment relationship, therefore no disciplinary authority. The equivalent sanction for a platform user is access removal, covered by A.5.18 |
| A.6.5 | Responsibilities after termination or change of employment | **No** | N/A | No employment. The analogous control — removing access when a user's relationship ends — is covered by A.5.18 and `access-control-policy.md` §3, which specifies the full deprovisioning set (`users.yaml`, Authentik account, group memberships, per-app groups, NAS assignments) |
| A.6.6 | Confidentiality or non-disclosure agreements | **No** | N/A | No staff or contractors to bind. AI coding agents operate under their provider's terms and under the operator's permission controls; their output passes the same pull-request gates as any other change (`secure-development-policy.md` §8) |
| A.6.7 | Remote working | Yes | Partial | **All** access is remote by construction; the VPN tier was retired deliberately and internal `*.int.` hostnames are protected by forward-auth rather than network position (`access-control-policy.md` §8). **This makes Authentik the only boundary**, which is why RISK-07 is scored Critical. No managed device fleet, no MDM (see A.8.1) |
| A.6.8 | Information security event reporting | Yes | Partial | Automated detection is reasonably broad (`incident-response-plan.md` §5). **There is no formal channel for a platform user to report a suspected incident** — with five users known personally to the operator this is handled by direct contact. Stated as a limitation, not claimed as a control |

---

## 5. A.7 — Physical controls (14)

The platform runs on self-owned hardware in a **private residence**, not a data
centre. Rather than claim data-centre controls or dismiss the whole family, each
control below states what actually exists.

The honest summary: **physical security is residential-grade.** The compensating
argument is that the equipment is not an attractive physical target and that the
data's real exposure is network-borne, not physical. The exception is A.7.14 —
disposal of a disk holding user data is a genuine unaddressed risk.

| # | Control | Applicable | Status | Justification and evidence |
|---|---|---|---|---|
| A.7.1 | Physical security perimeters | Yes | Partial | Standard domestic building envelope and locks. No facility-grade perimeter, no security zones. Accepted as inherent to a residential deployment |
| A.7.2 | Physical entry | Yes | Partial | Residential access control only. No visitor log, no badge system, no separate equipment-area access control |
| A.7.3 | Securing offices, rooms and facilities | **No** | N/A | No offices, dedicated server rooms or facilities exist. The equipment sits in a residence; the applicable protections are recorded under A.7.1 and A.7.8 rather than duplicated here |
| A.7.4 | Physical security monitoring | Yes | **Not implemented** | No CCTV, alarm or intrusion detection covering the equipment. Accepted: residential setting, no facility monitoring capability |
| A.7.5 | Protecting against physical and environmental threats | Yes | Partial | Domestic environment; equipment is sited away from obvious water and heat hazards. No fire suppression, no environmental sensors, no flood detection specific to the equipment |
| A.7.6 | Working in secure areas | **No** | N/A | No designated secure areas exist to define working rules for. The single operator works from general-purpose spaces; A.7.7 covers the applicable behaviour |
| A.7.7 | Clear desk and clear screen | Yes | Partial | Screen locking is used. No documented clear-desk policy; with one operator in a private residence the control's residual value is low, but it is not zero given that credentials appear on screen during administration |
| A.7.8 | Equipment siting and protection | Yes | Partial | Proxmox hosts `10.1.0.3` and `10.1.0.4` and the NAS are sited within the residence. No rack security, no physical locks on the machines themselves — physical access to the host is physical access to every VM |
| A.7.9 | Security of assets off-premises | Yes | Partial | Administration is performed from the operator's personal machines, off-premises, over the internet. Those devices hold cluster credentials. No MDM, no remote wipe, no encryption verification — see A.8.1 |
| A.7.10 | Storage media | Yes | Partial | Storage is fixed: NAS arrays and host disks. No removable-media handling procedure, no media register, no encryption-at-rest verification for the NAS pools |
| A.7.11 | Supporting utilities | Yes | Partial | Mains power and domestic internet. **No documented UPS coverage or generator.** A residential power cut takes the entire platform down; this is consistent with — and is the practical reason for — the multi-hour RTOs in `business-continuity-plan.md` §5 |
| A.7.12 | Cabling security | Yes | **Not implemented** | Domestic cabling with no physical protection, conduit or segregation of power and data runs. Accepted as inherent to the setting |
| A.7.13 | Equipment maintenance | Yes | Partial | Maintenance is reactive and ad hoc. No maintenance schedule, no spares inventory, no vendor support contracts. `docs/ADDING-A-NODE.md` documents the node procedure, which is the closest thing to a maintenance standard |
| A.7.14 | Secure disposal or re-use of equipment | Yes | **Not implemented** | **No documented disposal or sanitisation procedure.** This is the most consequential gap in this family: a retired NAS or host disk carries other people's WordPress databases, Nextcloud files and media. Requires a procedure (cryptographic erase or physical destruction) before any disk leaves the premises |

---

## 6. A.8 — Technological controls (34)

| # | Control | Applicable | Status | Justification and evidence |
|---|---|---|---|---|
| A.8.1 | User endpoint devices | Yes | **Not implemented** | No MDM, no endpoint protection, no device inventory, no disk-encryption verification for the machines used to administer the platform. Declared as a scope exclusion in `information-security-policy.md` §2 rather than claimed. Compounds A.7.9 |
| A.8.2 | Privileged access rights | Yes | Partial | Privileged access defined and bounded (`access-control-policy.md` §6); short-lived tokens are the stated norm. **Not met:** `claude-platform-owner` holds cluster-admin via a binding that is not in git with a 39-day-old non-expiring static token (RISK-09, F-05, WP3), and a second static token exists (F-06) |
| A.8.3 | Information access restriction | Yes | Partial | Scoped role assignments in `users.yaml` (path-scoped), console RBAC by group, ArgoCD `policy.default: role:readonly`, Kubernetes RBAC. **Gaps:** unbound Authentik applications are now 7, down from 13, after the `50-unbound-application-policies` backfill landed — five of F-01's six live applications are bound, `vaultwarden` is not (measured 2026-08-07 evening; enforcement untested, so F-01 remains open — see A.5.15); 44 pods on automounted `default` ServiceAccount tokens (GAP-H3, WP4) |
| A.8.4 | Access to source code | Yes | Partial | Three private repositories, single owner, no additional collaborators. Public mirror is sanitised through a gated pipeline with a `pre-push` hook blocking direct pushes. **Not met:** branch protection is unavailable (HTTP 403, free plan) so repository authorisation is account-level only. RISK-02, WP1 |
| A.8.5 | Secure authentication | Yes | **Not implemented** | SSO and forward-auth are in place, but the control's core requirement is not: **zero enrolled second factors of any type across every account** (re-verified live 2026-08-07 evening), and the one authenticator-validation stage bound to the authentication flow carries `not_configured_action: skip`, so it challenges nobody — present in shape, absent in effect (`kubernetes/platform/authentik/manifests/blueprints/10-authentication-current-state.yaml`). Groundwork laid 2026-08-07: the permanent MFA-bypass API token was deleted (see A.5.17) and the enforcement blueprints are written, reviewed and deliberately deferred behind the break-glass gate (WP11 stages 2–4). RISK-07, F-09, WP11 |
| A.8.6 | Capacity management | Yes | Partial | Monitored (Prometheus node alerts, `node-memory-rebalancer`) and documented (`business-continuity-plan.md` §8). **Not met:** capacity is genuinely exhausted — **cp3 was under `MemoryPressure=True` with a live `NoSchedule` taint at 2026-08-07 10:45**, on a host with no spare RAM, and 21 workloads violate the memory request/limit policy. RISK-05 (escalated to Critical on this evidence), GAP-M10 |
| A.8.7 | Protection against malware | Yes | **Not implemented** | No anti-malware, no runtime detection, no host behavioural monitoring. Falco is disabled (`app-falco-manifests.yaml.disabled`; the `falco` namespace has no pods). Cilium Hubble provides network flow visibility only. RISK-11, WP8 must either deploy Falco or formally accept Hubble + audit logs as the compensating surface |
| A.8.8 | Management of technical vulnerabilities | Yes | Partial | **Covered:** IaC (Checkov fail-on-HIGH, tfsec fail-on-CRITICAL/HIGH), manifests (kubeconform, Kyverno, netpol-port gate), shell/Python (shellcheck, ruff). **Not covered:** container images (no Trivy/Grype anywhere) and application dependencies. RISK-15 |
| A.8.9 | Configuration management | Yes | Partial | GitOps is the configuration management system: 61 ArgoCD Applications, 60 auto-sync, self-heal reverts drift. **Gaps:** the PSA label file declares itself the single source of truth but covers 17 of 37 namespaces with a duplicate entry (GAP-M3); 5 applications are persistently Degraded/OutOfSync, which weakens the "git is truth" claim; **four Authentik BlueprintInstances sit in `error`** — `ArgoCD and OpenBao OAuth2 Setup`, `Platform Users Setup`, `Forward-Auth (auto-generated)` and `authentik Bootstrap`, measured 2026-08-07 evening, cause not yet diagnosed — declared identity configuration that the live system has not applied, and a pre-existing baseline that will mask the next blueprint failure until it is cleared |
| A.8.10 | Information deletion | Yes | Partial | Retention and deletion defined (`logging-and-retention-policy.md` §6). **Two recorded collateral-damage incidents** shape the procedure: deleting a root-domain WordPress site removed the domain's MX and SPF records, and deleting a site orphaned its backups permanently because the sweep prunes by the current site list. Mitigations are documented; automation is not |
| A.8.11 | Data masking | **No** | N/A | No use case exists. Production personal data is never copied into test or analytics environments — test sites use synthetic content (`secure-development-policy.md` §7) — so there is no dataset requiring masking |
| A.8.12 | Data leakage prevention | Yes | **Not implemented** | No DLP tooling or egress content inspection. **Partial compensations exist and are real:** the CI secret-leak gate (ratcheting, baseline currently empty) prevents secrets entering git and therefore the public mirror; airgap-baseline egress policies restrict outbound traffic in 25 namespaces. Accepted (GAP-L5) — full DLP is disproportionate here |
| A.8.13 | Information backup | Yes | **Not implemented** | Materially improved 2026-08-07 but not yet operating: the backup target is now reachable (`available=true`, after fixing both the `${TRUENAS_HOST}` placeholder and the `airgap-baseline` egress denial — commit `71371b3`), all **19** live volumes are enrolled in the recurring jobs, and one backup was taken, restored and checksum-verified end to end (`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §7 — a scratch volume, cleaned up after the drill). **Still true, measured 2026-08-07 evening:** no production volume has ever been backed up — the target now holds **zero** `backups.longhorn.io` and zero `backupvolumes.longhorn.io`, the 6 orphaned BackupVolumes from a previous cluster (May 2026) having been deleted on 2026-08-07 precisely because the verifier iterates every BackupVolume and could never have recorded a success while they remained; the unattended nightly schedule has never once run to success (first run pending — backlog P0.3); the backup verifier has never recorded a success; Authentik's Postgres/Redis sit on `local-path` with no backup of any kind, and a nightly `pg_dump` chain is now in git but unproven live (backlog P1.6); no etcd snapshot has ever been taken anywhere (backlog P2.5). The WordPress fleet's separate signed datastore remains the one routinely working backup path (verified 2026-07-30). Moves to Partial when the first unattended nightly run produces backups of real volumes AND the verifier records a `lastSuccessfulTime`. RISK-03, WP2.<br><br>**Velero — exclusion drafted 2026-08-07, status PENDING.** The wording to adopt, once its precondition is met, is: *"Velero is excluded by decision of `<date>`. API-object protection is provided by five named compensating controls: (1) Git as the source of truth for the 63 ArgoCD Applications; (2) **etcd snapshots** covering the console-provisioned WordPress and game-hub objects, which carry no ArgoCD tracking-id and exist only in etcd — first snapshot verified end-to-end on `<DATE — DOES NOT EXIST YET>`; (3) the WordPress fleet's signed datastore, verified 2026-07-30; (4) Longhorn volume backups to the TrueNAS NFS target; (5) the console provisioning path, which can re-create site objects. The `minio-velero` MinIO instance was removed on `<date>` — it was hand-applied outside GitOps, served zero backups for 54 days, and stored Velero data on a Longhorn volume **inside the cluster it would restore**, a circular dependency that never made it a usable DR path."* The precondition is a verified etcd snapshot, which does not yet exist; until then this row states the exclusion as drafted, not adopted |
| A.8.14 | Redundancy of information processing facilities | Yes | Partial | 3-node etcd quorum, Longhorn cross-node volume replication, Traefik at 2 replicas, MetalLB. **Not met:** all three nodes are converged with workloads (RISK-01); two of three nodes share one hypervisor host, so losing that host loses quorum *and* the NFS target *and* the automation runner simultaneously; no site redundancy |
| A.8.15 | Logging | Yes | Partial | API server audit logging at Metadata level for all requests; container logs to Loki; Traefik access logs; Authentik events; ArgoCD events. **Not met:** OpenBao has **no audit device**, so secret access is entirely unevidenced (F-08, GAP-M6, WP10); audit logs never leave the node |
| A.8.16 | Monitoring activities | Yes | Partial | Prometheus (37 PrometheusRules), Loki, Gatus synthetics, Hubble, Kyverno PolicyReports. **Three delivery defects verified 2026-08-07:** every alert reaches only Discord; the **Watchdog dead-man's-switch alert is routed to the `null` receiver**, so a monitoring-stack outage is invisible by construction; and the `email-admin` fallback is both unrouted and configured with an unsubstituted `${BASE_DOMAIN}` placeholder. RISK-12, GAP-M4, WP8 |
| A.8.17 | Clock synchronization | Yes | **Implemented** | Talos manages NTP on all three nodes. Verify: `talosctl -n 10.0.0.90 time`. Without this, cross-source log correlation would be worthless |
| A.8.18 | Use of privileged utility programs | Yes | Partial | Talos is an immutable OS with **no shell and no package manager** on the nodes — a strong structural control. `talosctl` and `kubectl` privilege is controlled by credential possession. **Not met:** the Talos CA private key and admin kubeconfig sit unencrypted on the runner VM (RISK-17), so possession is weakly protected |
| A.8.19 | Installation of software on operational systems | Yes | **Implemented** | Talos immutability makes ad-hoc installation structurally impossible on the nodes. All software arrives as OCI images through ArgoCD from git. A Kyverno registry allowlist (Audit→Enforce) is a WP4 addition that will further constrain provenance |
| A.8.20 | Networks security | Yes | Partial | Cilium CNI with default-deny ingress+egress in 9 namespaces and airgap-baseline CiliumNetworkPolicies across 25; TLS on all published endpoints; forward-auth on admin surfaces. **Not met:** 7 namespaces have no policy at all, including `velero` which runs `minio-velero` (RISK-14, WP6). *Note:* the recommended resolution for `velero` is deletion, not a policy — see the A.8.13 Velero exclusion and the teardown step in `docs/BACKUP-AND-RESTORE-RUNBOOK.md` §8. That drops the unpolicied count to 6 |
| A.8.21 | Security of network services | Yes | Partial | Traefik with `secure-headers` on most routes; rate-limit middleware exists but is applied **only** to the Authentik route. **Remediation landed in git 2026-08-07** (`2a897d3`, WP9): `rate-limit-public-cf` on bitwarden, `rate-limit-public` on jellyfin/nextcloud/cluster routes. **Still not met until live convergence is verified**, and the bitwarden forward-auth exception remains permanent by design (native clients cannot complete a browser SSO redirect) — RISK-06 |
| A.8.22 | Segregation of networks | Yes | Partial | Namespace-level segregation via NetworkPolicy and CiliumNetworkPolicy; `airgap-baseline` pattern with a `pending/` staging directory for safe rollout. **Not met:** the 7 unpolicied namespaces in A.8.20; `monitoring`, `traefik` and `apps-grafana` lack egress deny. RISK-14 |
| A.8.23 | Web filtering | Yes | Partial | AdGuard provides DNS-level filtering on the network (VM 100). This is network hygiene rather than an enterprise web-filtering control, and it is not integrated with platform logging or alerting |
| A.8.24 | Use of cryptography | Yes | Partial | Strong in practice: etcd secrets encrypted at rest (`secretbox` first, `identity` fallback, `secrets` resource); TLS 1.2 minimum on the API server, TLS 1.3 on kubelet/KCM/scheduler with a modern cipher list; Let's Encrypt certificates; SOPS/age for Terraform variables; HMAC-signed WordPress backup manifests. **Not met:** no key-management policy document, no documented rotation schedule, and the Talos CA private key is stored unencrypted (RISK-17) |
| A.8.25 | Secure development life cycle | Yes | **Implemented** | `secure-development-policy.md` documents a genuinely strong SDLC: GitOps-only deployment, 7 automated gates, staged high-blast-radius changes with mandatory rollback notes. This is a control the platform already operated and had simply never written down |
| A.8.26 | Application security requirements | Yes | Partial | Security requirements are applied through review standards and automated reviewers rather than through a written requirements specification per application. No threat model exists for any individual application |
| A.8.27 | Secure system architecture and engineering principles | Yes | Partial | Documented principles (`docs/ZERO-TRUST-COMPLETION-PLAN.md`, `docs/gitops-operating-model.md`, `information-security-policy.md` §5), the airgap-baseline network pattern, PSA baseline floor, no-secrets-in-git. **Not met:** converged control plane (RISK-01); `--service-account-issuer` is cp1's IP, a SPOF-shaped identity issuer (GAP-L4) |
| A.8.28 | Secure coding | Yes | **Implemented** | Standards documented in `secure-development-policy.md` §6 and enforced by shellcheck, ruff, automated code review, and a TDD workflow with an 80% coverage target |
| A.8.29 | Security testing in development and acceptance | Yes | **Implemented** | Seven blocking gates across the two repositories, several derived from specific production incidents — notably the netpol-port gate (which exists because a Service-vs-pod port mismatch broke every SSO login) and the cron-secret seed gate (which exists because a missing seeded key made a CronJob fail silently forever). **Limitation:** no DAST and no penetration test has ever been performed |
| A.8.30 | Outsourced development | **No** | N/A | No development is outsourced. All work is performed by the platform owner, assisted by AI coding agents operating under the owner's direction and permission controls; their output passes identical pull-request gates, so they are not an outsourcing relationship in the control's sense |
| A.8.31 | Separation of development, test and production environments | Yes | Partial | Kustomize `base/` vs `overlays/prod`; `private-test` and `tradesphere` namespaces; a separate `ontwikkel` Terraform environment holding no user data. **Not met:** there is one Kubernetes cluster — test namespaces share the production control plane and nodes (compounds RISK-01) |
| A.8.32 | Change management | Yes | Partial | Strong process and strong automation (`secure-development-policy.md` §3, §5). **Not met at the enforcement point:** branch protection is unavailable on all three repositories, and `InfraWeaver-base` runs `make apply` on push to `main`/`ontwikkel`, so an unreviewed push is an automatic live infrastructure mutation. RISK-02, RISK-04, GAP-C1, WP1 |
| A.8.33 | Test information | Yes | **Implemented** | No production personal data in test fixtures; test sites use synthetic content; the `ontwikkel` environment holds no user data; placeholder credentials use literal `change-me` values that the secret-leak gate recognises as non-real |
| A.8.34 | Protection of information systems during audit testing | Yes | **Implemented** | The 2026-08-07 audit that produced this pack, and every evidence command in `evidence-index.md`, is **strictly read-only** — `kubectl get`/`describe`, `talosctl read`, `gh api` GETs, and read-only SQL SELECTs. The asset-inventory generator refuses any kubectl verb other than `get` by construction. No audit activity has mutated a production system |

### PENDING VERIFICATION — not a status, not in force

The paragraph below is **pre-drafted text, held here deliberately unapplied.**
A.8.13's status above is **Not implemented** and stays that way until the
evidence named here has actually been observed. Nothing in this block may be
read as a current claim, and it must not be applied on "the schedule should
have run" — that assumption is what cost 54 days of silent backup failure, and
nothing alerts on a missed run (`LonghornBackupVerifierMissedSuccess` is
Discord-only).

**Trigger to apply (backlog P0.3, all of it, verified by command):**
`backups.longhorn.io` rows exist for *production* volumes, dated after an
unattended 01:00 run, **and** `longhorn-backup-verifier` reports a
`lastSuccessfulTime`.

**Then, and only then:** change A.8.13's status cell to `Partial`; delete the
sentence beginning "the unattended nightly schedule has never once run to
success" and the verifier clause; insert *"Nightly unattended backups verified
running as of `<date>` (`backups.longhorn.io` rows for production volumes dated
after 01:00; verifier `lastSuccessfulTime` `<timestamp>`)."*; and update §2
accordingly — Partial 53→54, Not implemented 14→13, the not-implemented list
becomes 13 entries, and the "two that materially threaten" paragraph is
rewritten. Record the change in §7 as v1.2.

> ⛔ **PENDING: the Velero exclusion in A.8.13 / A.5.30 is drafted, not adopted.**
>
> The exclusion rests on compensating control (2), etcd snapshots. As of
> 2026-08-07 **no etcd snapshot has ever been taken** — the script and ansible
> playbook exist in `InfraWeaver-base` but were never installed, and the
> `etcd_snapshot_hosts` inventory group they target was defined nowhere
> (`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §1 callout). Adopting an exclusion whose
> named compensating control has never executed is the precise failure this
> platform keeps paying for: a control that reads as present and is absent.
>
> **Gate:** the first etcd snapshot verified end-to-end — taken, shipped to the
> NAS, and read back with a matching sha256 (runbook §8 item 6, `ROUNDTRIP_OK`).
> Only then: replace `<DATE — DOES NOT EXIST YET>` with the real date, remove
> this callout, and move A.8.13's Velero clause from PENDING to adopted.
>
> The `minio-velero` teardown is **not** gated on this — it is an unrelated
> hand-applied component serving zero backups, and its removal is an operator
> step in runbook §8. Only the *SoA wording* waits.

---

## 7. Approval and review

**Approved:** 2026-08-07 by the Platform Owner. There is no independent approver
(A.5.35), and this SoA says so in its own header rather than leaving it to be
discovered.

**Amended 2026-08-07 (v1.1).** A.5.30 moved Not implemented → Partial on the
strength of the first executed and verified restore drill
(`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §7, PASS). A.8.13 and A.5.29
justifications rewritten to the measured post-drill state — statuses
unchanged, because no unattended scheduled backup has yet succeeded. A.5.17
records the deletion of the permanent Authentik API and recovery tokens and
their expiring service-account replacement (`docs/BREAK-GLASS.md` §10). A.8.5
justification corrected (a validation stage is bound but inert). Summary
counts updated (Partial 52→53, Not implemented 15→14; open items remain 67).

**Review triggers:** completion of any work package WP1–WP11 (each changes the
truth of specific rows above), any SEV-2 or higher incident, any change to the
scope in `information-security-policy.md` §2, and in any case by 2027-02-07.

**Expected movement.** If WP1–WP11 complete as planned, these rows change status:

| Work package | Controls it moves |
|---|---|
| WP1 (change gate) | A.8.4, A.8.32 → Implemented; RISK-02/RISK-04 residual only |
| WP2 (backups/DR) | **A.8.13 and A.5.30 → Implemented**; A.5.29 → Implemented |
| WP3 (RBAC) | A.8.2 → Implemented |
| WP4/WP5 (policy ratchet, conformance) | A.5.36, A.8.9, A.8.3 → Implemented |
| WP6 (segmentation) | A.8.20, A.8.22 → Implemented |
| WP8 (logging/detection) | A.5.28, A.8.15, A.8.16 → Implemented; **A.8.7 → Implemented or formally accepted** |
| WP9 (edge) | A.8.21 → Implemented |
| WP10 (secrets/audit) | A.8.15 completed; A.5.17 improved |
| WP11 (MFA) | **A.8.5 → Implemented**; A.5.17 → Implemented |

That would leave the structurally unfixable set — A.5.3, A.5.35, A.8.1, A.7.x
residential controls — as the permanent accepted residue of a one-person,
one-residence platform. **Naming that residue in advance is the point of this
document.**
