# etcd snapshots — design decision

**Status:** implemented 2026-08-07 (WP2 / GAP-C2, GAP-M7).
**Restore procedure:** [`docs/BACKUP-AND-RESTORE-RUNBOOK.md`](../../../docs/BACKUP-AND-RESTORE-RUNBOOK.md).

> **This directory intentionally contains no manifests.** It holds the design
> record only. `kubernetes/bootstrap/appset-core.yaml` generates an ArgoCD
> Application for every `kubernetes/core/*/application.yaml`; there is no
> `application.yaml` here, so nothing is deployed from this path. That is the
> point — see below.

---

## The measured problem

The compliance audit of 2026-08-07 found **no etcd or Talos machine-level
snapshot schedule anywhere**: not as a cluster `CronJob`, not on any host, not
in the `InfraWeaver-base` infrastructure repo. The cluster is three *converged*
control-plane nodes (`talos-prod-cp1/2/3`) that also run every workload. Loss of
all three — a hypervisor pool failure, a bad rolling upgrade, a corrupt etcd
quorum — was **unrecoverable**, because there was nothing to recover *from*.

Measured at the time of writing (`talosctl etcd status`):

| Member | DB size | In use | Raft term |
|---|---|---|---|
| `10.0.0.90` | 314 MB | 39 MB (12.4%) | 10 |
| `10.0.0.91` | 310 MB | 39 MB (12.6%) | 10 |
| `10.0.0.92` | 311 MB | 39 MB (12.5%) | 10 |

A snapshot is ~314 MB raw and **~37 MB gzipped** — small enough that daily
retention is essentially free.

---

## Decision: the snapshot runs on the OPS HOST, not in the cluster

**Chosen:** a cron job on the ops host (`10.1.0.108`) running
[`scripts/etcd-snapshot.sh`](https://github.com/example-owner/InfraWeaver-base)
in the `InfraWeaver-base` (infrastructure) repo, installed by
`ansible/playbooks/etcd-snapshot-cron.yml`.

### Why not a Kubernetes `CronJob`

1. **The credential must not live in the blast radius.** `talosctl etcd snapshot`
   authenticates with an **`os:admin`** client certificate. That certificate can
   read *and rewrite* the entire control plane. Storing it in a Kubernetes Secret
   would mean anyone who can read secrets in that namespace — or anyone who
   compromises the cluster — inherits full Talos node control, including the
   ability to destroy the very backups meant to survive that compromise.
2. **A backup must not depend on the thing it backs up.** An in-cluster CronJob
   cannot run when the cluster is down. That is precisely the scenario an etcd
   snapshot exists for. The failure mode is not theoretical for a 3-node
   converged cluster with a documented cp3 memory-pressure history.
3. **Talos API access is host-shaped, not pod-shaped.** The ops host already
   holds `~/.talos/config` with the `infraweaver-prod` context and reaches all
   three nodes on the Talos API. Nothing new has to be provisioned or exposed.

### Why not the Proxmox hypervisors

They can reach the Talos nodes and have root, but putting the `os:admin`
certificate on the hypervisors spreads the most powerful credential in the
platform onto two more machines for no gain. The ops host already has it.

### Why not Velero

Velero backs up *Kubernetes API objects*, not etcd itself, and it is not
deployed (`bootstrap/app-velero.yaml.disabled`). Deliberately out of scope for
this change — one backup change at a time. See the Velero follow-up section of
the runbook.

---

## What the schedule does

| Property | Value | Why |
|---|---|---|
| Schedule | **03:40 UTC daily** | After the Longhorn window (00:00 snapshot, 01:00 daily backup, 02:00 Sunday weekly) and after `longhorn-backup-verifier` at 03:30, so the two backup systems never contend for NAS or node I/O. The playbook `assert`s the hour is outside 00–02. |
| Local staging | `/var/backups/etcd`, retain **7** | ~260 MB gzipped. The ops host root filesystem has run at 88% used / 6.2 GB free; the script refuses to start below `MIN_FREE_MB` (default 2048). |
| Off-box copy | TrueNAS `10.1.0.135` via **`smbclient`** | The ops host kernel has **neither `nfs` nor `cifs` in `/proc/filesystems`**, so it cannot *mount* the NAS. `smbclient` is userspace and already installed. TrueNAS SSH (22) is closed, so `rsync`/`scp` is not an option. |
| Off-box retention | **30** | ~1.1 GB on the NAS. |
| Compression | gzip -6 | 314 MB → 37 MB, verified with `gzip -t` after write. |
| Integrity | `.sha256` + `.meta` sidecars | `.meta` holds `talosctl`'s own `hash / revision / total keys` line, so a restore can be sanity-checked before it is trusted. |
| Concurrency | `flock` | An overrunning run can never overlap the next cron tick. |

### The failure mode this design explicitly rejects

A backup job that exits `0` while storing nothing. The script therefore:

- **fails the whole run** if an off-box copy is required and does not succeed
  (`REQUIRE_REMOTE=1`, the default for any transport but `none`);
- **refuses to start** if `REMOTE_TRANSPORT=none` while `REQUIRE_REMOTE=1`,
  rather than quietly degrading to a same-host copy;
- **refuses to prune** without a positive integer retention count, only ever
  considers files matching its own `etcd-*-*Z.db.gz` pattern at `-maxdepth 1`,
  and deletes nothing when fewer files exist than the retention count.

This is the same class of defect as the Longhorn one repaired alongside it: the
nightly Longhorn job logged `Found 0 volumes` and exited `0` for 54 days.

---

## Outstanding

1. **An etcd restore drill has never been performed.** A snapshot that has never
   been restored is a hypothesis, not a backup. This is the first required
   action in the runbook.
2. **The SMB destination on TrueNAS must be created and credentialed** before
   the playbook is run with `etcd_snapshot_transport: smb` — the share
   `//10.1.0.135/infraweaver` exists (it backs the Jellyfin and Nextcloud PVs),
   but no `etcd-snapshots` directory or dedicated credential has been provisioned.
3. **Talos machine configs are not yet covered.** `params/mc-talos-prod-cp*.yaml`
   are committed snapshots from 2026-06-10 and may have drifted. A restore needs
   both etcd *and* a current machine config. Adding
   `talosctl -n <node> get mc -o yaml` to the same schedule is the natural next
   step and is tracked in the runbook.
4. **Nothing observes this schedule.** Measured on the ops host (10.1.0.108) on
   2026-08-07: no user or root crontab entry, no `/etc/cron.d` entry, no systemd
   timer, and no `/var/backups/etcd` directory. The control is designed and
   documented; it is **not installed**. Prometheus also scrapes nothing on the
   ops host, so even once installed there would be no in-cluster signal. See the
   verifier design below.

---

## Observability: the `etcd-snapshot-verifier` fold-in

The alerting side is pre-wired and costs nothing on the day this ships. The name
**`etcd-snapshot-verifier` is already reserved** in the backup-chain selectors of
`kubernetes/monitoring/alerts/cronjob-health.yaml`, where it matches nothing
today and is therefore silent. The moment a CronJob by that name exists in
namespace `monitoring` (or `longhorn-system`), all of
`BackupCronJobMissedSuccess`, `BackupCronJobNeverSucceeded` and
`BackupCronJobSuspended` cover it at **critical** severity with zero rule
changes.

Design, to be built alongside the prerequisites in items 2 and 4 above:

- **Shape:** a Kubernetes CronJob in namespace `monitoring`, schedule
  `10 4 * * *` — after the 03:40 snapshot, and clear of both the 00–02 window
  this README's assertion protects and the Longhorn backup window.
- **What it asserts (the OUTCOME, not the mechanism):** list
  `//10.1.0.135/infraweaver/etcd-snapshots/`; the newest `etcd-*Z.db.gz` must be
  younger than 26h, larger than 10 MiB, and accompanied by its `.sha256`
  sidecar. Exit non-zero otherwise. This is the same reason
  `longhorn-backup-verifier` exists: a control is proven by a fresh restorable
  artifact off-box, never by the fact that a schedule is configured.
- **Pod shape:** mirror `longhorn-backup-verifier` in
  `kubernetes/core/longhorn/manifests/automation-jobs.yaml` — `runAsNonRoot`,
  `activeDeadlineSeconds: 900`, `failedJobsHistoryLimit: 1`,
  `successfulJobsHistoryLimit: 2`, alpine + smbclient.
- **Credential:** a **read-only** SMB credential scoped to `etcd-snapshots`,
  minted at the same time as the write credential in item 2. This does not put
  `os:admin` in the cluster — the red line this whole design exists to hold. A
  read-only listing credential is an acceptable exposure; a snapshot-taking
  credential is not.
- **NetworkPolicy:** egress from the verifier pod to `10.1.0.135:445`. This is
  the exact shape that silently killed Longhorn backups for 54 days — the
  `airgap-baseline` policy denied the NAS while everything looked configured.
  Test from inside the pod on first deploy; do not infer it from the manifest.
- **THE ONE RULE CHANGE, and it must be in the SAME commit as the CronJob:** add
  `or absent(kube_cronjob_spec_suspend{namespace="monitoring",cronjob="etcd-snapshot-verifier"})`
  to `BackupCronJobAbsent`. Adding it any earlier fires a permanent false
  critical; adding it later leaves a deleted verifier undetectable.

Until that lands, etcd snapshots are **uninstalled and unmonitored**, and this
paragraph is the honest record of it.
