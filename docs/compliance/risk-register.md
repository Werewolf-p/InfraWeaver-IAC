# Risk Register

| | |
|---|---|
| **Document ID** | ISMS-REG-001 |
| **Version** | 1.0 |
| **Status** | Active |
| **Opened** | 2026-08-07 |
| **Owner** | Platform Owner (sole risk owner — see caveat below) |
| **Review cadence** | Quarterly, aligned to the access review; plus on any SEV-2+ incident |
| **Controls** | ISO/IEC 27001:2022 cl. 6.1.2, 6.1.3, 8.2, 8.3, A.5.4, A.5.36 · SOC 2 CC3.1–CC3.4, CC5.1, CC9.1 |

---

## How to read this register

Every risk here was **found by audit on 2026-08-07 against the live platform**,
not imagined from a template. Each entry cites the evidence that proves it and,
where a work package is remediating it, names that work package.

**Risk owner caveat.** Every risk below is owned by the same person, who is also
the only person who can accept it. There is no second signature and no risk
committee. Naming a fictitious approver would make this register less useful, not
more, so the register states the truth: **all acceptances below are
self-approved.** An auditor should weigh them accordingly.

**Scoring.** Likelihood (L) and Impact (I) on 1–5; Score = L × I.

| Score | Band | Required response |
|---|---|---|
| 15–25 | Critical | Remediate now; acceptance requires an explicit dated rationale and a review date |
| 8–14 | High | Remediate within the current work-package wave |
| 4–7 | Medium | Remediate opportunistically; accept with rationale |
| 1–3 | Low | Accept and monitor |

**Status values:** `Open` (untreated), `Treating` (a work package is active),
`Accepted` (deliberate, with rationale and review date), `Closed`.

---

## Summary

| Band | Count |
|---|---|
| Critical (15–25) | 4 — RISK-02, RISK-05, RISK-07, RISK-09 |
| High (8–14) | 10 |
| Medium (4–7) | 2 |
| Low (1–3) | 1 |
| **Total** | **17** |

| Status | Count |
|---|---|
| Treating (work package active) | 8 |
| Accepted (deliberate, with rationale) | 7 |
| Open (no treatment yet) | 2 — RISK-11 (no runtime detection), RISK-17 (plaintext secrets + Talos CA on the runner) |

RISK-02, RISK-04 and RISK-06 carry two statuses because an interim acceptance is
in force while a work package remediates; they are counted once, under the
status that describes what is true *today*.

---

## RISK-01 — Converged control plane: application workloads share the etcd/API-server nodes

| Field | Value |
|---|---|
| **Category** | Architecture / availability |
| **Gap ref** | GAP-L2 |
| **Controls** | A.8.6, A.8.22, A.8.27, A.8.31 · SOC 2 A1.1, CC6.1 |
| **Likelihood** | 3 — resource contention on this cluster is not hypothetical; cp3 has hit `MemoryPressure` |
| **Impact** | 4 — a runaway workload degrades the control plane, not just itself |
| **Score** | **12 (High)** |
| **Treatment** | **Accept**, with compensating controls |
| **Status** | Accepted |
| **Review** | 2027-02-07, or immediately if a fourth node becomes available |

**Evidence.** All three nodes are control-plane and all are schedulable:

```
kubectl get nodes -o wide
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) taints=\(.spec.taints // "none")"'
```

**Rationale for acceptance.** This is a self-hosted platform on two Proxmox
hosts with 64 GiB and 15.5 GiB of RAM respectively. Dedicating three nodes to
control-plane duty and adding three worker nodes is not affordable in either RAM
or hardware. The alternative — a single-node control plane plus workers — trades
a real availability gain (etcd quorum across three nodes) for a theoretical
isolation gain. Quorum was judged the better buy.

**Compensating controls.** Pod Security Admission (cluster default `baseline`
enforce, `restricted` warn/audit); Kyverno resource-governance policies;
LimitRanges; PriorityClasses ensuring control-plane components outrank
application pods; per-namespace NetworkPolicy/CiliumNetworkPolicy.

**What would change this.** A fourth physical host, or the memory pressure on
cp3 (RISK-05) becoming chronic rather than episodic.

---

## RISK-02 — The change gate is not technically enforceable: branch protection is unavailable and a push to `main` auto-applies infrastructure

| Field | Value |
|---|---|
| **Category** | Change management |
| **Gap ref** | GAP-C1 |
| **Controls** | A.5.15, A.8.4, A.8.9, A.8.32 · SOC 2 CC8.1 |
| **Likelihood** | 3 — the operator pushes to these repos daily; one mistargeted push is enough, as is one compromised token |
| **Impact** | 5 — a push to `InfraWeaver-base:main` runs `make apply` against live Proxmox with no human gate |
| **Score** | **15 (Critical)** |
| **Treatment** | **Mitigate** (WP1), with the residual accepted |
| **Status** | Treating |
| **Review** | On WP1 merge; then 2026-11-07 |

**Evidence.**

```
gh api repos/example-owner/InfraWeaver-infra/branches/main/protection
# → 403 {"message":"Upgrade to GitHub Pro or make this repository public…"}
grep -nE 'on:|branches:|make apply' <infrastructure>/.github/workflows/tofu.yml
# → push: branches: [main, ontwikkel]  …  run: ENV=… make apply   (line 151)
```

All three repositories are private on a GitHub free plan, where branch
protection and required status checks are a paid feature. The CI gates
(`validate-iac`, `validate-code`) therefore **run** on pull requests but cannot
be made **required**. Nothing technically blocks a direct push to `main`.

**Decision taken (2026-08-07).** Do not purchase GitHub Pro, and do not make the
repositories public to obtain protection — publishing infrastructure manifests
to gain a merge gate is a net security loss. Instead, move the enforcement point
into the workflow itself, where the free plan cannot remove it:

1. Remove the `push`-triggered `make apply` from `tofu.yml`; apply becomes
   `workflow_dispatch`-only with a typed environment confirmation and an
   uploaded plan artifact.
2. Add a job step that verifies the checked-out SHA corresponds to a merged pull
   request before applying.
3. Add `CODEOWNERS` to all three repositories (advisory on the free plan, but it
   surfaces review expectations on every PR).

**Residual risk, accepted.** CODEOWNERS is advisory and a determined or careless
push to `main` still lands manifests that ArgoCD will sync. What WP1 removes is
the *automatic infrastructure mutation*; what it cannot remove is the ability to
push. Accepted because the alternative costs money or exposes the repositories.

---

## RISK-03 — Volume backups have never successfully run; there is no cluster-state or etcd backup at all

| Field | Value |
|---|---|
| **Category** | Availability / data loss |
| **Gap ref** | GAP-C2, GAP-M7 |
| **Controls** | A.5.29, A.5.30, A.8.13, A.8.14 · SOC 2 A1.2, A1.3 |
| **Likelihood** | 2 — node or volume loss is uncommon but has precedent on this platform |
| **Impact** | 5 — total, unrecoverable loss of every PVC; 39 PVCs / 19 Longhorn volumes in scope |
| **Score** | **10 (High)** — *rated 25 before the RPO caveat below; see note* |
| **Treatment** | **Mitigate** (WP2) — no acceptable acceptance exists for this one |
| **Status** | Treating |
| **Review** | Weekly until the verifier reports a success, then quarterly |

**Evidence (re-verified 2026-08-07).**

```
kubectl get backuptarget -n longhorn-system -o json | jq -r '.items[] | "url=[\(.spec.backupTargetURL)] available=\(.status.available)"'
# → url=[] available=false          (git declares nfs://${TRUENAS_HOST}:/mnt/pool/k8s-longhorn-backups)
kubectl get backups.longhorn.io -n longhorn-system
# → No resources found in longhorn-system namespace.
kubectl get cronjob -n longhorn-system longhorn-backup-verifier -o jsonpath='{.status.lastSuccessfulTime}'
# → (empty — has NEVER succeeded)
kubectl get pods -n velero
# → only minio-velero; Velero itself is not deployed
```

The BackupTarget URL is empty and `available=false` while
`kubernetes/core/longhorn/values.yaml:58` declares an NFS target — a
substitution or reset failure. Zero `backups.longhorn.io` resources have ever
existed. The `longhorn-backup-verifier` CronJob is scheduled (03:30 daily), has
run, and has **never** recorded a `lastSuccessfulTime`. Velero is not deployed,
so there is no Kubernetes object-level backup. No etcd or Talos snapshot
schedule exists in any repository.

**Note on the score.** The raw exposure is 25 (5×5). It is recorded as 10
because two partial mitigations genuinely exist and were verified: the
`truenas-backup-daily` and `local-snapshot-daily` CronJobs *do* record recent
`lastSuccessfulTime` values, and the WordPress fleet has its own signed,
independently verified backup path. Neither covers cluster state or non-WordPress
PVCs. **This is the single largest real risk on the platform and it is not
accepted at any level.**

**In-flight (2026-08-07 10:39).** WP2 committed `1b3e871` repairing the git-side
target to a literal NFS URL at `values.yaml:98`. Re-verified at 10:47: the live
BackupTarget was still `url=[] available=false` and zero Backup CRs existed.
**This risk closes on evidence of a successful backup, not on a merged commit.**

**Treatment (WP2).** Reconcile the live BackupTarget with git; confirm Backup
CRs appear and the verifier goes green; add a scheduled `talosctl etcd snapshot`
from the ops host with an off-node copy; run and document one volume restore and
one etcd-restore tabletop; publish `docs/BACKUP-AND-RESTORE-RUNBOOK.md`.

**Until WP2 lands, `business-continuity-plan.md` states an honest RPO of
"undefined for cluster state, ~24h for the WordPress fleet only".**

---

## RISK-04 — The `ontwikkel` Terraform state is stale; an apply would recreate ~5 destroyed VMs and endanger cp3's host

| Field | Value |
|---|---|
| **Category** | Change management / availability |
| **Gap ref** | GAP-C1 (compounding) |
| **Controls** | A.8.9, A.8.32, A.8.6 · SOC 2 CC8.1, A1.1 |
| **Likelihood** | 2 — requires a push to the `ontwikkel` branch, which is not routine but is one command away |
| **Impact** | 5 — recreating dead VMs on the 15.5 GiB microserver would starve or evict `talos-prod-cp3`, breaking etcd quorum tolerance |
| **Score** | **10 (High)** |
| **Treatment** | **Accept** short-term with a hard procedural control; **Mitigate** via WP1 |
| **Status** | Accepted (interim) → Treating |
| **Review** | On WP1 merge |

**Evidence.** `.github/workflows/tofu.yml` triggers on `push: branches: [main,
ontwikkel]` and runs `make apply`. `envs/ontwikkel/nodes.yaml` still declares
`nodes:` (`pve-dev1`, `pve-dev2`), `cloud_init_templates:` and `github_runners:`
whose VMs no longer exist on the hypervisor. `talos-prod-cp3` (VM 9302, 6 cores,
10240 MB, `balloon_mb: 0`) runs on that same host.

**Interim control.** The `ontwikkel` branch is treated as frozen: no push to it
under any circumstances until WP1 removes push-triggered apply *and* the state
has been reconciled against reality by a supervised `tofu plan` review. This
constraint is recorded here rather than relying on memory.

**Rationale for interim acceptance.** Reconciling the state requires a plan
review and possibly state surgery, which is a supervised operation and cannot be
safely bundled into the current documentation wave. The freeze costs nothing —
the ontwikkel environment is not in active use.

---

## RISK-05 — Proxmox memory is overcommitted and `talos-prod-cp3` runs starved

| Field | Value |
|---|---|
| **Category** | Capacity / availability |
| **Gap ref** | GAP-M10 |
| **Controls** | A.8.6 · SOC 2 A1.1 |
| **Likelihood** | 5 — **not a possible future state: cp3 is under `MemoryPressure=True` right now** |
| **Impact** | 3 — pod eviction and scheduling failure on one of three nodes; degraded, not down |
| **Score** | **15 (Critical)** |
| **Treatment** | **Accept**, monitored — but see the escalation note below |
| **Status** | Accepted |
| **Review** | **Monthly** while the condition persists, not quarterly |

**Evidence.**

```
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) \(.status.capacity.memory)"'
# → cp1 24587224Ki, cp2 24587228Ki, cp3 10161128Ki
kubectl describe node talos-prod-cp3 | grep -A6 Conditions
```

**Live at 2026-08-07 10:45 CEST**, re-verified while compiling this register:

```
MemoryPressure   True   KubeletHasInsufficientMemory   kubelet has insufficient memory available
taints: [{"effect":"NoSchedule","key":"node.kubernetes.io/memory-pressure","timeAdded":"2026-08-07T08:45:17Z"}]
```

cp3 is **currently tainted `NoSchedule` by the kubelet**, so the cluster is
effectively running on two schedulable nodes while still depending on three for
etcd quorum. This is why the score was raised from 12 to 15 during compilation:
the audit found a historical condition; the register found an active one.

`envs/productie/nodes.yaml` documents the budget explicitly: the productie host
has 64 GiB total, cp1 and cp2 hard-pin 48 GiB between them (`balloon_mb: 0`), and
the remaining VMs share ~16 GiB. cp3 lives on the 15.5 GiB microserver with a
10 GiB hard pin and cannot be grown. Its own inventory entry records 94% memory
utilisation as of 2026-08-06.

**Rationale for acceptance.** cp3 cannot be grown (its host has no spare RAM) and
cannot be shrunk (it is already the tightest node). Growing it means buying
hardware. Shrinking cp1 or cp2 to donate reboots a control-plane node while cp3
is already pressured — a worse trade.

**Compensating controls.** A `node-memory-rebalancer` exists; Prometheus alerts
on node memory pressure; LimitRanges and Kyverno memory policies constrain
per-pod appetite (though 21 workloads currently violate the memory
request/limit policy in Audit mode — GAP-H4/WP5, which is a *direct* contributor
to this risk).

**Operational rule.** `qm config` reports the staged value, not the running one.
Only `qm pending <vmid>` shows what a live guest actually has. Any capacity
decision based on `qm config` alone is unsound.

---

## RISK-06 — `bitwarden.example.com` is publicly reachable with no edge authentication and no rate limit

| Field | Value |
|---|---|
| **Category** | Edge exposure |
| **Gap ref** | GAP-H6 |
| **Controls** | A.5.15, A.8.5, A.8.20, A.8.21, A.8.23 · SOC 2 CC6.1, CC6.6 |
| **Likelihood** | 3 — a public, unauthenticated, unrate-limited endpoint is continuously scanned |
| **Impact** | 4 — it is a password manager; the vault is the highest-value asset it could reach |
| **Score** | **12 (High)** |
| **Treatment** | **Accept the exception, mitigate the exposure** (WP9) |
| **Status** | Accepted (exception) → Treating (rate-limit + headers) |
| **Review** | On WP9 merge; then quarterly |

**Evidence.**

```
kubectl get ingressroutes -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) mw=\([.spec.routes[].middlewares[]?.name] | join(","))"'
# → bitwarden route carries secure-headers only; no forward-auth, no rate-limit
```

**Why the exception exists.** Bitwarden-compatible native clients (mobile,
desktop, browser extension) authenticate against the vault API directly and
cannot complete a Traefik `forward-auth` browser redirect. Putting the platform
SSO in front of this route breaks every non-browser client. Every other admin
surface on the platform *is* behind forward-auth (argocd, grafana, longhorn,
n8n, openbao, truenas, homepage, console, gatus, wp-admin) — this is a genuine
technical exception, not an oversight.

**Compensating controls.**
- Open registration was disabled at the application source (commit `db3cab4`,
  "signups are off at the source") after the earlier incident where this host
  was a **public password manager with open registration**.
- Application-level authentication with the vault's own key derivation.
- `secure-headers` middleware is applied at the edge.
- **Pending WP9:** a `rate-limit-public` middleware on this route, plus
  authentication-failure alerting.

**Explicitly not accepted:** the absence of rate limiting. That is a WP9
deliverable, not an exception.

**In-flight (2026-08-07 10:50).** WP9 landed `2a897d3 security(edge): rate-limit
the four unauthenticated public routes`, attaching a `rate-limit-public-cf`
middleware (100/s, burst 200, bucketed on `Cf-Connecting-IP`) to the bitwarden
route, and `rate-limit-public` to jellyfin, nextcloud and the cluster routes.
Git is fixed; **verify live convergence before treating the rate-limit half as
closed**:

```bash
kubectl get ingressroutes -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \([.spec.routes[].middlewares[]?.name] | join(","))"'
```

That commit also records a correction worth keeping: an edge *block* was
deliberately removed in `db3cab4` because the invite token travels in the request
body, so no path/method rule can distinguish an invite from a self-registration.
Registration is shut off at the origin instead. **Do not re-add an edge block
here** — it breaks invite acceptance without adding protection.

---

## RISK-07 — Multi-factor authentication is not enforced anywhere and no user has ever enrolled a second factor

| Field | Value |
|---|---|
| **Category** | Identity |
| **Gap ref** | GAP-C5 |
| **Controls** | A.5.17, A.8.5 · SOC 2 CC6.1 |
| **Likelihood** | 3 — password-only SSO in front of every admin surface, credentials phishable |
| **Impact** | 5 — Authentik is the single lock on the entire platform; compromise of the `admin` account is total compromise |
| **Score** | **15 (Critical)** |
| **Treatment** | **Mitigate** (WP11) |
| **Status** | Treating |
| **Review** | On WP11 stage 4; then quarterly |

**Evidence (measured 2026-08-07, read-only query against the Authentik
database — this upgrades the finding from "not demonstrable" to "confirmed not
enforced").**

```
kubectl exec -n authentik authentik-postgresql-0 -- bash -c \
 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"|" -c "
  SELECT '"'"'totp'"'"', count(*) FROM authentik_stages_authenticator_totp_totpdevice
  UNION ALL SELECT '"'"'webauthn'"'"', count(*) FROM authentik_stages_authenticator_webauthn_webauthndevice
  UNION ALL SELECT '"'"'static'"'"', count(*) FROM authentik_stages_authenticator_static_staticdevice
  UNION ALL SELECT '"'"'duo'"'"', count(*) FROM authentik_stages_authenticator_duo_duodevice
  UNION ALL SELECT '"'"'sms'"'"', count(*) FROM authentik_stages_authenticator_sms_smsdevice;"'
# → totp|0  webauthn|0  static|0  duo|0  sms|0
```

Zero enrolled devices of any type, across all 5 human accounts. Setup flows
exist (`default-authenticator-totp-setup`, `default-authenticator-webauthn-setup`)
but nothing binds an authenticator-validation stage into
`default-authentication-flow`. Authentik flow configuration lives only in its
database — there is no blueprint in git, so this state is neither versioned nor
reviewable.

**Why not accepted.** There is no rationale that survives contact with the fact
that one password protects a Kubernetes cluster, a vault, a hypervisor fleet, and
other people's personal data.

**Treatment (WP11), staged because of lockout risk.** Export current Authentik
configuration to blueprints in git (evidence of present state) → create and
verify break-glass access → add TOTP/WebAuthn enrolment as optional and enrol the
platform admin → make authenticator-validation required for `platform-admins`
only → widen to all users after one week.

**Interim risk owner note:** the lockout risk is real and material — a single
admin enforcing MFA on themselves with no break-glass path is a self-inflicted
denial of service. Break-glass first is mandatory, not advisory.

---

## RISK-08 — Single-person dependency

| Field | Value |
|---|---|
| **Category** | Organisational / continuity |
| **Gap ref** | (organisational; underpins GAP-C4) |
| **Controls** | A.5.2, A.5.3, A.5.29, A.5.30, A.5.35, A.6.x · SOC 2 CC1.3, CC1.4, CC2.2 |
| **Likelihood** | 2 — illness, absence, or loss of interest are ordinary events |
| **Impact** | 5 — no other person can currently restore, operate, or make changes to this platform |
| **Score** | **10 (High)** |
| **Treatment** | **Accept**, with documentation-based mitigation |
| **Status** | Accepted |
| **Review** | Semi-annual |

**Rationale for acceptance.** There is no second operator and no budget to hire
one. The risk cannot be eliminated; it can only be made survivable.

**Mitigations (partly pending).**
- The entire platform is declared in git and reproducible — this is the primary
  mitigation and it is real today.
- `docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md` documents a full DR rebuild path.
- **Pending WP2:** a restore runbook a third party could follow.
- **Pending WP11:** a documented break-glass credential procedure.
- This compliance pack itself: an inheriting operator can read
  `evidence-index.md` and reconstruct the control picture without tribal
  knowledge.

**Explicitly not mitigated:** there is no key escrow, no documented handover, and
no named successor. Segregation of duties (A.5.3) is not achievable and is marked
as such in the Statement of Applicability.

---

## RISK-09 — A standing, non-expiring cluster-admin credential exists outside git

| Field | Value |
|---|---|
| **Category** | Privileged access |
| **Gap ref** | GAP-C3 |
| **Controls** | A.5.15, A.5.16, A.5.18, A.8.2, A.8.18 · SOC 2 CC6.1, CC6.2, CC6.3 |
| **Likelihood** | 3 — a static token that never expires only has to leak once, ever |
| **Impact** | 5 — cluster-admin is total cluster compromise |
| **Score** | **15 (Critical)** |
| **Treatment** | **Mitigate** (WP3) |
| **Status** | Treating |
| **Review** | On WP3 merge |

**Evidence.**

```
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | "\(.metadata.name): \([.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(","))"'
# → claude-platform-owner: ServiceAccount/infraweaver-system/claude-platform-owner
# → cluster-admin: Group/-/system:masters
# → longhorn-support-bundle: ServiceAccount/longhorn-system/longhorn-support-bundle
kubectl get secret -n infraweaver-system            # → claude-platform-owner-token (static, kubernetes.io/service-account-token)
grep -rln claude-platform-owner .                   # → no YAML hit: the binding is NOT in git
```

`claude-platform-owner` holds cluster-admin, is defined nowhere in the GitOps
repository, and carries a static `kubernetes.io/service-account-token` Secret
that does not expire. No pod uses it — it exists purely as a standing human/
automation credential.

**Treatment (WP3), sequenced to avoid self-lockout.** Define a scoped
ClusterRole in git for the automation harness → verify a short-lived
`kubectl create token` works with it → *then* delete the static Secret and the
unmanaged binding. For `longhorn-support-bundle`, check `ownerReferences` first:
if the Longhorn operator owns it, deleting it is futile and it must be documented
as an operator-managed exception instead.

---

## RISK-10 — Policy enforcement is advisory: 18 of 19 Kyverno policies are Audit-only

| Field | Value |
|---|---|
| **Category** | Preventive control effectiveness |
| **Gap ref** | GAP-H1, GAP-H4 |
| **Likelihood** | 3 | **Impact** | 3 | **Score** | **9 (High)** |
| **Controls** | A.8.9, A.8.19, A.8.27 · SOC 2 CC6.6, CC7.1 |
| **Treatment** | **Mitigate** (WP4 ratchet, gated on WP5) |
| **Status** | Treating |
| **Review** | On each WP4 stage |

**Evidence.**

```
kubectl get cpol -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction
# → 18 Audit, 1 Enforce (validate-externalsecret-storeref)
kubectl get polr -A -o json | jq -r '[.items[].summary] | {pass:(map(.pass)|add), fail:(map(.fail)|add), error:(map(.error)|add)}'
# → {"pass":2024,"fail":39,"error":2}
```

39 live failures and 2 policy *errors* (the `require-pod-probes` policy itself
errors on the console Deployment — a broken policy, not merely a failing
workload). A policy in Audit mode records a violation; it does not prevent one.

**Why the ratchet is staged rather than flipped.** Enforce mode blocks pod
*restarts* of any violating workload at an arbitrary future time — a latent
outage. The mandated order is: fix the broken policy → complete the PSA label
source of truth → fix the 39 workload violations (WP5) → only then flip security
policies to Enforce, one policy per PR, with explicit infrastructure-namespace
exclusions. Resource-governance policies stay in Audit-and-alert deliberately.

---

## RISK-11 — No runtime threat detection

| Field | Value |
|---|---|
| **Category** | Detection |
| **Gap ref** | GAP-H8 |
| **Likelihood** | 2 | **Impact** | 4 | **Score** | **8 (High)** |
| **Controls** | A.8.7, A.8.16 · SOC 2 CC7.1, CC7.2 |
| **Treatment** | **Mitigate** (WP8) or formally accept with Hubble as the compensating control |
| **Status** | Open |
| **Review** | On WP8 decision |

**Evidence.** `kubectl get pods -n falco` → no resources; the Falco application
is `app-falco-manifests.yaml.disabled`. There is no antimalware, no host
behavioural monitoring, and no container runtime detection anywhere. Cilium
Hubble provides network flow observability only.

**Note.** This is deliberately left `Open` rather than `Accepted`. WP8 must
either deploy Falco (canaried on one node — eBPF on the Talos 6.18 kernel is
unproven here) or write an explicit acceptance naming Hubble + Kubernetes audit
logs as the compensating detection surface. Silence is not an answer.

---

## RISK-12 — Log and metric retention is too short and partly undefined; API audit logs never leave the node

| Field | Value |
|---|---|
| **Category** | Logging / evidence |
| **Gap ref** | GAP-H5 |
| **Likelihood** | 4 — this is not a possible future state, it is the current state |
| **Impact** | 2 — no direct security loss, but it defeats investigation and Type II evidence windows |
| **Score** | **8 (High)** |
| **Controls** | A.5.28, A.5.33, A.8.15, A.8.16 · SOC 2 CC7.2, CC7.3 |
| **Treatment** | **Mitigate** (WP8 technical; this pack supplies the policy text) |
| **Status** | Treating |

**Evidence.** Prometheus `retention: 3d` / `retentionSize: 8GB`
(`kubernetes/monitoring/kube-prometheus-stack/values.yaml:99-100`). Loki
`table_manager.retention_period: 168h` with deletes disabled — retention is
undefined in practice. API server audit logs are written to
`/var/log/audit/kube/kube-apiserver.log` on-node with 30-day file rotation and
are **not shipped to Loki**, so an incident that costs a node also costs its
audit trail. OpenBao has no audit device configured, so secret access is
unevidenced.

**Consequence stated plainly.** A SOC 2 Type II observation window is typically
3–12 months. With 3 days of metrics and undefined log retention, **this platform
cannot currently evidence continuous operation of monitoring controls over an
audit period.** `logging-and-retention-policy.md` sets the target periods; WP8
implements them.

---

## RISK-13 — The secrets pipeline is degraded and one credential is in plaintext in a pod spec

| Field | Value |
|---|---|
| **Category** | Secrets management |
| **Gap ref** | GAP-H7 |
| **Likelihood** | 3 | **Impact** | 3 | **Score** | **9 (High)** |
| **Controls** | A.5.17, A.8.24, A.8.12 · SOC 2 CC6.1 |
| **Treatment** | **Mitigate** (WP10) |
| **Status** | Treating |

**Evidence.**

```
kubectl get externalsecrets -A -o json | jq -r '.items[] | select([.status.conditions[]?|select(.type=="Ready")|.status]|index("True")|not) | "\(.metadata.namespace)/\(.metadata.name)"'
# → game-hub/game-hub-server-credentials, infraweaver-console/infraweaver-iwsl-iw-keys,
#   tradesphere/tradesphere-ai, tradesphere/tradesphere-binance, tradesphere/tradesphere-inspect
```

5 of 28 ExternalSecrets fail to sync. Separately, the `game-hub/gt-new-horizons`
pod carries `RCON_PASSWORD` and `_IW_RCON_PASSWORD` as literal environment
values, readable by anyone with pod-read in that namespace — a direct violation
of §6 of the information security policy.

---

## RISK-14 — Seven namespaces have no network policy of any kind

| Field | Value |
|---|---|
| **Category** | Network segmentation |
| **Gap ref** | GAP-H2 |
| **Likelihood** | 2 | **Impact** | 3 | **Score** | **6 (Medium)** |
| **Controls** | A.8.20, A.8.22 · SOC 2 CC6.6 |
| **Treatment** | **Mitigate** (WP6, staged per namespace) |
| **Status** | Treating |

**Evidence.** `kubectl get netpol,cnp -A` shows zero policies in `default`,
`velero` (which runs `minio-velero`), `metallb-system`, `local-path-storage`,
`bootstrap`, `crds`, and `cilium-secrets`. `kube-system` is also unpolicied and
is accepted as a system namespace.

**Why staged.** Egress-deny in `monitoring` breaks scraping of every namespace;
egress-deny in `traefik` breaks every backend. WP6 requires 24h of Hubble flow
observation per namespace before applying, one namespace per commit for atomic
revert.

---

## RISK-15 — No container image vulnerability scanning; unpinned and `:latest` images in use

| Field | Value |
|---|---|
| **Category** | Supply chain |
| **Gap ref** | GAP-L3, GAP-M1 |
| **Likelihood** | 3 | **Impact** | 2 | **Score** | **6 (Medium)** |
| **Controls** | A.5.21, A.8.7, A.8.8, A.8.19 · SOC 2 CC7.1 |
| **Treatment** | **Accept** for now; partial mitigation in WP5/WP4 |
| **Status** | Accepted |
| **Review** | 2026-11-07 |

**Evidence.** Checkov covers IaC only. No Trivy/Grype scan exists in either
repository's CI. `disallow-latest-tag` is in Audit and currently violated by
`bitnami/kubectl:latest` (4 Kyverno cleanup CronJobs),
`benjojo/alertmanager-discord:latest`, and an untagged
`lscr.io/linuxserver/jellyfin`. Measured 2026-08-07: **83 distinct container
images in use, 36 of them from `docker.io`** (31 by implicit default, 5 explicit),
none pinned by digest.

**Rationale for acceptance.** Adding a scanner is cheap; acting on its output is
not — an unfunded scanner producing thousands of unactioned CVEs is worse than
none, because it creates the appearance of a control. Accepted until there is
capacity to triage. WP5 pins the three `:latest` offenders and WP4 adds a
registry allowlist (Audit → Enforce), which addresses the provenance half of the
risk without the triage burden.

---

## RISK-16 — API server lacks `--kubelet-certificate-authority`; kubelet has no PID limit

| Field | Value |
|---|---|
| **Category** | Hardening |
| **Gap ref** | GAP-M2, GAP-M5, GAP-L1, GAP-L4 |
| **Likelihood** | 1 | **Impact** | 3 | **Score** | **3 (Low)** |
| **Controls** | A.8.9, A.8.20 · CIS 1.2.6, 4.2.x |
| **Treatment** | **Accept** until the next Talos maintenance window (WP12) |
| **Status** | Accepted |
| **Review** | On WP12 scheduling |

**Evidence.** `--kubelet-certificate-authority` absent from the API server
command; `podPidsLimit: -1` in the kubelet config; `--service-account-issuer` is
`https://10.0.0.90:6443` (cp1's IP — a SPOF-shaped issuer URL).

**Rationale for acceptance.** Each fix is a Talos machine-config change requiring
a rolling restart of all three control-plane nodes. Doing that while cp3 is
memory-pressured (RISK-05) and while backups do not work (RISK-03) is a worse
risk than the one being fixed. **WP12 is explicitly blocked on WP1 and WP2.**

---

## RISK-17 — The runner VM holds plaintext secrets and the unencrypted Talos CA private key

| Field | Value |
|---|---|
| **Category** | Secrets management / key management |
| **Gap ref** | Pre-existing operator actions C-1 and C-4 in `docs/SECURITY-REMEDIATION-RUNBOOK.md` (open since 2026-06-11) |
| **Controls** | A.5.17, A.8.24, A.8.5, A.8.12 · SOC 2 CC6.1 |
| **Likelihood** | 2 — the VM is internal-only, but it is also where all automation runs |
| **Impact** | 5 — the Talos CA private key is the root of trust for the entire cluster; `.env` holds live Cloudflare, Proxmox, SMTP and deployer-SSH credentials |
| **Score** | **10 (High)** |
| **Treatment** | **Accept** short-term (rotation is disruptive); **Mitigate** by encrypting at rest |
| **Status** | Open |
| **Review** | 2026-11-07, or immediately on any suspicion of runner-VM compromise |

**Evidence.** `docs/SECURITY-REMEDIATION-RUNBOOK.md` §C-1 records that "the real
secrets live in `InfraWeaver-{infra,platform}/.env` on the runner (plaintext,
untracked)" and §C-4 records that "`envs/productie/generated/` holds the Talos CA
private key + admin kubeconfig/talosconfig (unencrypted on the runner)". Both
items are marked OPERATOR ACTION and neither is closed. The runner is
`github-runner`, VM 107 on Proxmox host `10.1.0.3` (8 GiB, `balloon_mb: 8192`),
per `envs/productie/nodes.yaml`.

**Consequence, stated plainly.** Compromise of one VM is equivalent to compromise
of the cluster certificate authority *and* of the hypervisor API credential.
`incident-response-plan.md` §2 therefore classifies runner-VM compromise as
SEV-1 by definition rather than by investigation.

**Rationale for interim acceptance.** The C-4 remediation is
`talosctl rotate-ca --init`, which re-issues node and admin certificates and is
disruptive to a three-node converged cluster with no working volume backups
(RISK-03) and one memory-starved node (RISK-05). Rotating the cluster CA before
backups work is the wrong order.

**Sequencing.** WP2 (backups) → then CA rotation and SOPS/age encryption of
`envs/*/generated/` in the same maintenance window as WP12.

---

## Register maintenance

Add a risk when: an audit or incident surfaces one; a control is deliberately not
implemented; or an exception is granted. Never grant an exception without an
entry here — an exception not in this register does not exist (see
`information-security-policy.md` §9).

Close a risk only when the evidence command in its entry demonstrates the
condition no longer holds. Record the closing evidence, do not just flip the
status.
