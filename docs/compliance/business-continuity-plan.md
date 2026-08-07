# Business Continuity Plan

| | |
|---|---|
| **Document ID** | ISMS-PLA-002 |
| **Version** | 1.0 |
| **Status** | Active — **but see §0. Several capabilities this plan describes are not currently functional.** |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | On WP2 completion (mandatory), then 2027-02-07 |
| **Controls** | ISO/IEC 27001:2022 A.5.29, A.5.30, A.8.13, A.8.14, A.8.6 · SOC 2 A1.1, A1.2, A1.3, CC7.5 |

---

## 0. Status statement — read this first

A business continuity plan that describes a backup regime which has never
produced a backup is worse than no plan, because it creates false confidence.
So, stated at the top:

| Capability | Claimed by design | **Actually true on 2026-08-07** |
|---|---|---|
| Longhorn volume backup to TrueNAS NFS | Nightly, all annotated PVCs | **Not functional.** BackupTarget URL is empty, `available=false`, **zero** `backups.longhorn.io` resources have ever existed, and `longhorn-backup-verifier` has **never** recorded a successful run |
| Velero cluster-state backup | Optional group | **Not deployed.** The `velero` namespace contains only `minio-velero` |
| etcd / Talos snapshot | — | **Does not exist.** No schedule in any repository |
| WordPress fleet backup | Signed, content-addressed datastore | **Working and independently verified** (2026-07-30) |
| Local Longhorn snapshots | `local-snapshot-daily` CronJob | **Running** — last success 2026-08-07T00:00:04Z. Same-cluster only; not a backup |
| TrueNAS-side jobs | `truenas-backup-daily`, `truenas-backup-weekly` | **Running** — last success 2026-08-07T01:00:10Z. Scope must be re-verified as part of WP2 |
| Restore drill | — | **Never performed** for Longhorn or etcd |

**Everything in §5 (RTO/RPO) is therefore an objective, not a measured
capability, except where explicitly marked.** WP2 exists to close this and is
the single highest-priority remediation on the platform (RISK-03).

**In-flight as of compilation (2026-08-07 10:47).** WP2 committed
`1b3e871 fix(longhorn): repair the backup target that has never once produced a
backup` at 10:39, setting a literal `nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups`
in `kubernetes/core/longhorn/values.yaml:98`. **Git is fixed; the live
BackupTarget was still `url=[] available=false` eight minutes later.** Do not
mark A.8.13 or A.5.30 as met on the strength of a commit — the control is met
when `kubectl get backups.longhorn.io` returns objects and the verifier records
a `lastSuccessfulTime`, not before.

Re-verify this table before relying on it:

```bash
kubectl get backuptarget -n longhorn-system -o json | jq -r '.items[] | "url=[\(.spec.backupTargetURL)] available=\(.status.available)"'
kubectl get backups.longhorn.io -n longhorn-system
kubectl get cronjob -n longhorn-system -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,LASTSUCCESS:.status.lastSuccessfulTime
kubectl get pods -n velero
```

## 1. Scope and objectives

This plan covers restoring the InfraWeaver platform after loss of a node, a
hypervisor host, a storage volume, or the whole cluster. It also covers the
degraded-but-running cases that are far more common than total loss.

**What "the business" is here.** A self-hosted platform serving five users, a
small WordPress fleet (personal and family sites), media services, a private
Nextcloud, and internal tooling. There is no revenue at risk and no contractual
SLA. That is why the recovery objectives below are measured in hours and days
rather than minutes, and why that is a legitimate engineering choice rather than
a shortfall.

**What is genuinely irreplaceable:** user data in PVCs — Nextcloud files,
WordPress databases and uploads, Jellyfin metadata, OpenBao's storage, Authentik's
database. Everything else (manifests, images, configuration) is reproducible from
git.

## 2. Business impact analysis

| Tier | Services | Impact if lost | Max tolerable outage |
|---|---|---|---|
| **1 — Foundational** | Talos/Kubernetes control plane, etcd, OpenBao, Authentik, Traefik, cert-manager, External Secrets | Everything stops. Without Authentik there is no human access to anything; without OpenBao no secret syncs | 4 hours |
| **2 — User-facing data** | WordPress fleet, Nextcloud, Jellyfin, NAS shares | Other people's data unavailable or lost. **Data loss here is unrecoverable in a way an outage is not** | 8 hours outage; **zero tolerance for loss** |
| **3 — Platform operations** | ArgoCD, console, registry, monitoring, Loki | Cannot deploy or observe; the platform runs but is unmanageable and unobservable | 24 hours |
| **4 — Discretionary** | Game Hub / game servers, tradesphere, n8n, private-test | Annoyance | 72 hours |

The dependency that dominates everything: **Authentik and OpenBao are Tier 1 for
every other tier.** A restore sequence that brings up WordPress before Authentik
produces a site nobody can administer.

## 3. Threat scenarios and response

### 3.1 Loss of one Kubernetes node

**Likelihood: moderate.** Three converged control-plane nodes; losing one leaves
a two-node etcd quorum with **zero further fault tolerance** (RISK-01).

Response: confirm which node (`kubectl get nodes`), confirm etcd health, let
Kubernetes reschedule. Longhorn replicas should carry the volumes — verify
`kubectl get volumes.longhorn.io -n longhorn-system` shows healthy replica
counts, and check `longhorn-replica-guardian` (runs every 15 minutes, last
success 2026-08-07T08:15:06Z).

**Critical caveat:** if the lost node is `talos-prod-cp3`, it lives on the
*other* hypervisor (`10.1.0.4`, 15.5 GiB) and cannot simply be recreated
elsewhere — its host has no spare RAM (RISK-05), and the `ontwikkel` Terraform
state on that host is stale in a way that would recreate five dead VMs if applied
(RISK-04). **Do not run `tofu apply` against `ontwikkel` to recover cp3.**

### 3.2 Loss of a hypervisor host

**Productie host `10.1.0.3`** carries cp1, cp2, TrueNAS, the runner, the
backup-server, and the Traefik/AdGuard VM. Losing it loses etcd quorum *and* the
NFS backup target *and* the automation host simultaneously. This is the worst
realistic scenario and there is currently no tested recovery for it.

**Ontwikkel host `10.1.0.4`** carries cp3 only. Losing it degrades to §3.1.

### 3.3 Loss of a storage volume

Longhorn replicates across nodes, so single-replica loss self-heals. Loss of all
replicas of a volume requires restore from backup — **which does not currently
work.** Until WP2 lands, the honest answer for a non-WordPress PVC is: the data
is gone.

### 3.4 Total cluster loss

Documented path: `docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md` §Phase 2 — a full DR
rebuild with all-new secrets. It is explicitly marked **SUPERVISED; catastrophic
if unattended**. Summarised: rotate source credentials first → destroy cluster
and init VM → re-run the init flow → OpenBao comes up fresh and is re-seeded →
ArgoCD bootstraps the app-of-apps from the private GitHub repository → validate
every tier.

This path **rebuilds the platform but not the data.** It assumes volume backups
exist to restore into it. They do not yet.

### 3.5 Compromise rather than failure

Route to `incident-response-plan.md`. Restoring from a backup taken after a
compromise reinstates the compromise; establish the timeline before restoring.

### 3.6 Loss of the operator

RISK-08. The mitigations are documentation-based and partly pending: everything
is in git; `PRIVATE-PUBLIC-GITOPS-AND-DR.md` documents the rebuild; this
compliance pack documents the control picture; WP2 will produce a restore runbook
a third party could follow; WP11 will produce a break-glass procedure. There is
currently **no key escrow and no named successor**, so a third party would today
be unable to unseal OpenBao or authenticate to Authentik.

## 4. Backup design (target state, WP2)

| Layer | Mechanism | Destination | Frequency | Retention |
|---|---|---|---|---|
| Volume data | Longhorn recurring backup jobs | TrueNAS NFS `10.1.0.135:/mnt/pool/k8s-longhorn-backups` | Nightly 01:00 | Per `logging-and-retention-policy.md` §6 |
| Volume snapshots | Longhorn local snapshots (`local-snapshot-daily`) | In-cluster | Daily 00:00 | Short — **not a backup**, same failure domain |
| Cluster state | `talosctl etcd snapshot` from the ops host | Off-node, TrueNAS + a second copy | Daily | 30 days |
| Machine config | Talos machineconfig export | Alongside the etcd snapshot | On change | Indefinite |
| Kubernetes objects | Git (the manifests **are** the backup) | GitHub, plus the public sanitised mirror | Every commit | Indefinite |
| WordPress sites | Signed content-addressed datastore | Separate path, HMAC-signed manifests | Per site schedule | Per site |
| Secrets | **Not backed up by design** | — | — | Rebuilt from source-of-truth credentials during DR (`PRIVATE-PUBLIC-GITOPS-AND-DR.md` Phase 2 step 1 rotates them anyway) |

Verification is the part that failed here, so it is stated as a requirement, not
a nicety: the `longhorn-backup-verifier` CronJob must record a
`lastSuccessfulTime`, and `BackupCronJobMissedSuccess` /
`BackupCronJobNeverSucceeded` (`kubernetes/monitoring/alerts/cronjob-health.yaml`,
both `severity: critical`) must alert when it does not.

**Correction, 2026-08-07: the detection did NOT work.** The predecessor rule
`LonghornBackupVerifierMissedSuccess` computed
`time() - kube_cronjob_status_last_successful_time`, and that series does not
exist for a CronJob with zero successes — which is precisely the state
`longhorn-backup-verifier` was in for all 54 days. The alert could not have
fired. It has been replaced by the pair above, of which
`BackupCronJobNeverSucceeded` covers exactly the never-succeeded case, plus
`BackupCronJobAbsent` for a deleted CronJob. Delivery still terminates at one
Discord webhook (RISK-12 / GAP-M4).

## 5. Recovery objectives

**Objectives, not measurements.** None has been validated by drill.

| Tier | RTO (target) | RPO (target) | RPO **actual, today** |
|---|---|---|---|
| 1 — Foundational | 4 h | 24 h | **Undefined** — no etcd snapshot exists |
| 2 — User data (WordPress) | 8 h | 24 h | **~24 h** — the one path that genuinely works |
| 2 — User data (Nextcloud, Jellyfin, other PVCs) | 8 h | 24 h | **Total loss** — no functioning volume backup |
| 3 — Platform operations | 24 h | Git commit | **Git commit** — genuinely met; manifests are the backup |
| 4 — Discretionary | 72 h | 7 d | Total loss |

## 6. Restore procedures

Detailed procedures belong in `docs/BACKUP-AND-RESTORE-RUNBOOK.md`, a **WP2
deliverable that does not yet exist**. This plan states the required sequence so
that WP2 has a specification to satisfy:

1. **Restore the substrate** — Proxmox hosts, then Talos nodes.
2. **Restore etcd** from snapshot, or rebuild the cluster per
   `PRIVATE-PUBLIC-GITOPS-AND-DR.md` Phase 2.
3. **Restore OpenBao first**, then unseal it. Nothing else can start without
   secrets. Note that `openbao-0`'s seal mode must be confirmed before any
   restart — it is called out as a hazard in WP5 for the same reason.
4. **Restore Authentik's database.** Without it there is no human access.
5. **Let ArgoCD reconcile** the remaining ~59 applications from git.
6. **Restore volume data** into the reconciled PVCs. `scripts/restore-from-truenas.sh`
   exists for this and is referenced in `platform.yaml` — **its function has not
   been verified since the BackupTarget broke**, so WP2 must test it, not assume
   it.
7. **Verify** with `evidence-index.md` commands, not with a dashboard.

## 7. Testing

| Test | Frequency | Last performed |
|---|---|---|
| Volume restore to a scratch PVC | Quarterly | **Never** |
| etcd restore tabletop | Annually | **Never** |
| Full DR rebuild (documented, not executed) | On major change | **Never executed** |
| Node-loss drill | Annually | **Never** |

The console has DR game-day tooling (`api/dr/game-days`) that is unused. WP2's
acceptance criteria include performing and documenting the first volume restore
and the first etcd-restore tabletop. **Until one restore has succeeded, this
platform has backups in intent only.**

## 8. Capacity management (A.8.6, SOC 2 A1.1)

Continuity depends on having somewhere to run. Current position:

- Productie host `10.1.0.3`: 64 GiB total. cp1 and cp2 hard-pin 48 GiB
  (`balloon_mb: 0`); the remaining ~16 GiB is shared by TrueNAS, the runner, the
  backup-server, the Traefik/AdGuard VM and the init VM. **There is no spare
  capacity for a replacement node.**
- Ontwikkel host `10.1.0.4`: 15.5 GiB, carrying cp3 at a 10 GiB hard pin. cp3
  reported 94% memory utilisation on 2026-08-06 and has hit `MemoryPressure`.
- 21 workloads currently violate the Kyverno memory request/limit policy in
  Audit mode, which directly worsens scheduling headroom (WP5).

**Operational rule (learned the hard way):** `qm config` reports the *staged*
value, not the running one. Only `qm pending <vmid>` shows what a live guest
actually has, and `qm set --balloon` does not retarget a running balloon. Any
capacity decision made from `qm config` alone is wrong.

Monitoring: node memory alerts exist in the `platform-alerts` PrometheusRule;
a `node-memory-rebalancer` exists. Both are detective, not corrective — there is
no capacity to add.
