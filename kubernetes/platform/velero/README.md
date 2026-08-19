# Velero — what it covers, what it deliberately does not, and how to restore

**Status:** authored 2026-08-15. Manifests only — **not applied**. Closes the
open half of GAP-C2.
**Scope:** local-path PVC data + granular per-namespace object restore.
**Companion docs:** [`docs/BACKUP-AND-RESTORE-RUNBOOK.md`](../../../docs/BACKUP-AND-RESTORE-RUNBOOK.md)
(Longhorn + etcd), [`core/etcd-maintenance/snapshot-README.md`](../../core/etcd-maintenance/snapshot-README.md).

---

## 1. The measured starting position

Everything below was measured against the live cluster on 2026-08-15, not assumed.

| Layer | State | Evidence |
|---|---|---|
| Velero controller | **Absent** | `kubectl get crd \| grep velero` → no output. No BSL, no schedules, no backups. |
| `minio-velero` | Running, but **only the S3 target** | `velero/minio-velero` Deployment 1/1, Service ClusterIP `10.96.59.43` :9000/:9001, PVC `minio-velero-data` **50Gi** on `longhorn-retain` (re-measured 2026-08-19; it was 20Gi when this row was written), 2 replicas, healthy. |
| The backup bucket | **In use** | Re-measured 2026-08-19: `df -h /data` → `50G  2.6G  47G  6%`. The "empty, never used" reading below dates from before the first successful run. |
| MinIO credentials | OpenBao via ESO, **live** | `ExternalSecret velero/minio-velero-credentials` → `SecretSynced True`, path `secret/platform/minio-velero` (`access_key`, `secret_key`). |
| `velero-s3-credentials` | **Declared but never applied** | Present in `platform/minio-velero/manifests/minio.yaml`, but no Application owns that dir. `kubectl -n velero get externalsecret` returns only `minio-velero-credentials`. |
| GitOps ownership of `velero` ns | **NONE** | Every object in the namespace has `app.kubernetes.io/instance = None`. Hand-applied 62 days ago; nothing reconciles it. |
| **Longhorn volume data** | **Already backed up, and working** | Target `nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups`, `available: true`. RecurringJobs `truenas-backup-daily` (01:00, retain 7) and `truenas-backup-weekly` (Sun 02:00, retain 4) on the `default` group, which Longhorn auto-applies to every volume. **185 Completed / 24 Error of 209.** |
| **etcd / API objects** | **Already snapshotted**, off-cluster | Daily `scripts/etcd-snapshot.sh` on the ops host (`10.1.0.108`). ~37 MB gzipped. |
| CSI snapshot stack | **Not installed** | `kubectl get volumesnapshotclass` → *"the server doesn't have a resource type"*. No `snapshot.storage.k8s.io` CRDs, no snapshot-controller. Only `snapshots.longhorn.io`. |
| **local-path PVC data** | **COVERED BY NOTHING** | 19 bound local-path PVCs across 7 namespaces. |

### The actual hole

The premise "there is no backup safety net" turned out to be **half true**, and
the half that is true is the important half. Volume data on Longhorn is backed
up. Cluster object state is snapshotted. What has **zero** coverage is:

1. **Every local-path PVC.** Longhorn cannot snapshot them — they are node-local
   bind mounts on the host filesystem, not Longhorn volumes. There is no CSI
   snapshotter either. Nothing reads them.
2. **Granular restore.** An etcd snapshot is all-or-nothing: recovering one
   deleted namespace means reverting the entire cluster to a point in time. That
   is not a tool you can use on a Tuesday afternoon.

Those two things — and *only* those two — are what this Velero deployment is for.

### The 19 uncovered local-path PVCs

| Namespace | PVC | Claim / **actual** | Node |
|---|---|---|---|
| **game-hub** | `gt-new-horizons-container-local` | 30Gi / **2.4G** | **cp1** |
| wordpress | `hihi-wp-data`, `hihi-db-data` | 5Gi ea / 102M + db | cp1 |
| wordpress | `lol-wp-data`, `lol-db-data` | 5Gi ea / 102M + 163M | cp3 |
| wordpress | `yonavaarwater-nl-wp-data` / `-db-data` | 5Gi ea / 271M db | cp1 / cp3 |
| wordpress | `zonnevaarwater-nl-wp-data` / `-db-data` | 5Gi ea / **1.4G** + 274M | cp3 |
| wordpress | `hi2-wp-data-slot-b`, `test-db-data` | 5Gi ea | cp2 |
| nextcloud | `nextcloud-data-lp`, `postgresql-nextcloud-data-lp` | 100Gi+10Gi / **1.1G** | cp1 |
| n8n-prod | `n8n-data`, `postgresql-n8n-data` | 2Gi + 5Gi | cp1 |
| authentik | `data-authentik-postgresql-0`, `redis-…-master-0` | 2Gi + 256Mi | cp1 / cp3 |
| jellyfin | `jellyfin-data-0-lp` | 5Gi (config) | cp1 |
| registry | `zot-data` | 20Gi | cp3 |

**10 of the 19 are on `talos-prod-cp1`.** `talos-prod-cp2` is currently cordoned
(`node.kubernetes.io/unschedulable:NoSchedule`, applied 2026-08-15T08:38Z).

---

## 2. The decision: Longhorn-native **and** Velero, with a hard split

**Recommendation: keep Longhorn-native backups as the primary mechanism for all
Longhorn volume data, and add Velero for exactly two jobs it alone can do.**

This is not a "use both, hedge your bets" answer. The two systems are given
**disjoint, non-overlapping** responsibilities, and Velero is explicitly
configured *not* to touch what Longhorn already owns.

### Why not Velero for everything

Velero's usual answer for volume data is CSI snapshots. **That is not available
here** — there is no external-snapshotter, no `VolumeSnapshotClass`, no
`snapshot.storage.k8s.io` CRDs. The previous `values.yaml` set
`features: "EnableCSI"` and declared a `volumeSnapshotLocation` anyway; both were
inert. Making CSI snapshots work would mean installing and operating a whole
additional controller to duplicate a Longhorn capability that is already running
and already producing 185 completed backups to off-cluster NFS.

The alternative — pointing Velero's file-system backup at *every* volume — would
copy multi-gigabyte Longhorn volumes into a **50Gi** MinIO PVC that is itself a
Longhorn volume in the same cluster. That is strictly worse than what exists.

### Why not Longhorn for everything

Because it physically cannot reach a local-path PV. That is not a configuration
gap; local-path volumes are `hostPath`-style bind mounts that the Longhorn engine
has no handle on. No Longhorn setting closes this.

### Why not "exclude Velero entirely"

`docs/BACKUP-AND-RESTORE-RUNBOOK.md` §8 drafted (but did not ratify) the opposite
recommendation — formally exclude Velero and delete `minio-velero` — on the
grounds that *"the design stores Velero's data in MinIO on a Longhorn volume
inside the same cluster … a two-hop chain whose first hop already requires the
thing Velero exists to protect."*

**That criticism is correct, and it is answered rather than ignored:**

- It is fatal to the *old* design, which used Velero as a second, redundant copy
  of data Longhorn already held. For that purpose the circularity made it
  worthless. Agreed — and that design is deleted here.
- It is **not** fatal to the new scope. For local-path data the comparison is not
  "Velero-in-MinIO vs Longhorn-to-NFS", it is **"Velero-in-MinIO vs nothing at
  all."** A backup with an imperfect chain strictly dominates no backup.
- The chain does terminate off-cluster: `minio-velero-data` is on
  `longhorn-retain` and carries the `default` recurring-job group, so TrueNAS
  holds a nightly copy of the MinIO volume. Restoring after a total cluster loss
  is Longhorn-restore-MinIO-volume → then Velero-restore, which is documented in
  §5 below.
- The honest residual risk is stated in §6. It is a real limitation, not a solved
  problem.

### Provider and BackupStorageLocation

`velero-plugin-for-aws` **v1.14.2** against the in-cluster MinIO. v1.14.x is the
release matched to Velero v1.18.x by the upstream compatibility table; the
previous file pinned **v1.10.0**, which pairs with Velero 1.14 — a mismatch left
behind when nothing was ever deployed to expose it.

```yaml
backupStorageLocation:
  - name: default
    provider: aws
    bucket: velero-backups
    prefix: infraweaver-prod        # keeps a future 2nd cluster from colliding
    default: true
    validationFrequency: 1h
    config:
      region: minio
      s3ForcePathStyle: "true"
      s3Url: http://minio-velero.velero.svc.cluster.local:9000
```

`publicUrl` is **removed**. The old value was
`https://minio-velero.int.${BASE_DOMAIN}` in a **Helm valueFile**, which never
passes through the `envsubst-v1.0` CMP — that literal `${BASE_DOMAIN}` would have
shipped to the cluster verbatim. This is the identical failure that produced
GAP-C2 in `core/longhorn/values.yaml` (`nfs://${TRUENAS_HOST}:/...` was rejected
by longhorn-manager, silently emptying the backup target).

### Schedules and retention

`uploaderType: kopia`, `defaultVolumesToFsBackup: **false**` globally — volume
copying is **opt-in per schedule**, so no schedule can accidentally start
duplicating Longhorn.

| Schedule | When (UTC) | Scope | Volume data | TTL |
|---|---|---|---|---|
| `daily-objects` | 03:30 daily | all ns except `kube-*`, `velero` | **none** | 30d |
| `daily-wordpress` | 03:45 daily | `wordpress` | kopia FSB (Longhorn PVCs only) | 7d |

**`daily-gamehub` and `weekly-localpath` were DELETED on 2026-08-19.** Both
produced **0 PodVolumeBackups on every run they ever made** (counted, per run:
gamehub 08-16/08-17/08-18 → 0, 0, 0; localpath 08-16 → 0 and PartiallyFailed),
because every PVC they named is `local-path`, i.e. `hostPath`-backed, which
Velero's file-system backup skips by design. They were retained for a while on
the argument that their *object* capture was still worth having; that argument
was then measured and failed. Downloading both backups' `BackupResourceList` and
set-differencing them against the **same-day** `daily-objects` run over durable
kinds gives **0 objects captured by either that `daily-objects` did not also
capture** (game-hub 36 vs 36; nextcloud+jellyfin+authentik 103 vs 103) — and
`daily-objects` runs daily with a 720h TTL against their 168h/336h, so deleting
them lengthened retention. Existing backups were left alone; schedule-created
Backups carry no `ownerReferences`, so they age out on their own TTL.

Measured footprint **2.6 GB** of a **50Gi** MinIO PVC (6%) on 2026-08-19 (kopia
deduplicates and compresses across snapshots). See §6 for the headroom caveat.

#### The 08:30 game-hub slot was never load-bearing (and the schedule is gone)

The reasoning that put `daily-gamehub` at 08:30 read: *scale-down runs at 00:00
and takes game-hub to zero replicas, FSB reads volumes through a running pod, so
a 02:00 run would find no pod.* Both halves were false. Both scale jobs ship
**dormant** — measured in the live ConfigMap `game-hub/game-hub-scale-schedule-config`:
`scaleDownEnabled: "false"`, `targetDeployments: ""`, and the job logs say
*"scale-down is disabled; exiting"*. The server runs 24/7. And the schedule could
not have copied the world at any hour, because the PV is `hostPath`-backed.

The lesson survives its schedule: *"A green job that backs up nothing is worse
than a red one."* That is why the schedule was deleted rather than re-timed.

#### Why `daily-objects` excludes volume data

It is a few MB of YAML with a 30-day TTL, and it is the only thing in the cluster
that can restore **one namespace** without reverting everything. That capability
is worth far more than its cost, which is why it runs cluster-wide while the
expensive volume schedules stay narrowly targeted.

### Credentials

No credential is created, and nothing is hardcoded.
`manifests/externalsecret.yaml` reads the **already-provisioned** OpenBao path
`secret/platform/minio-velero` — the same one `minio-velero` itself uses, proven
live by `minio-velero-credentials` being `SecretSynced True` — and renders it
into an AWS INI file under key `cloud`:

```yaml
target:
  template:
    data:
      cloud: |
        [default]
        aws_access_key_id={{ .access_key }}
        aws_secret_access_key={{ .secret_key }}
```

The chart mounts that Secret at `/credentials` and sets
`AWS_SHARED_CREDENTIALS_FILE=/credentials/cloud`.

### The PSA change is required, not incidental

`kubernetes/core/psa/namespace-labels.yaml` moves `velero` from
`enforce: baseline` → `enforce: privileged`. The node-agent DaemonSet mounts
`hostPath: /var/lib/kubelet/pods` and `/var/lib/kubelet/plugins` and runs as
uid 0. **PSA `baseline` forbids hostPath volumes**, so without this change the
DaemonSet is rejected at admission and the entire local-path capability silently
does not exist. `audit`/`warn` stay `restricted` so any future non-host-access
pod in this namespace still shows up as an outlier.

Kyverno needs **no** change — `velero` is already excluded from every Enforce
ClusterPolicy, and the exclusion comment names `restic` (this node-agent) as the
reason. The `infraweaver.io/type: catalog-app` label, which arms those policies,
is deliberately absent and must stay absent.

---

## 3. Files in this change set

| File | Change |
|---|---|
| `kubernetes/platform/velero/application.yaml` | **new** — AppSet parameter file; generates Application `platform-velero`. Chart `12.1.*` (appVersion 1.18.1). |
| `kubernetes/platform/velero/values.yaml` | **rewritten** — see §4 for what was wrong before. |
| `kubernetes/platform/velero/manifests/externalsecret.yaml` | **new** — `velero-s3-credentials` from OpenBao. |
| `kubernetes/platform/velero/README.md` | **new** — this file. |
| `kubernetes/bootstrap/app-velero-manifests.yaml` | **new** — Application for the manifests dir. |
| `kubernetes/bootstrap/app-velero.yaml.disabled` | **deleted** — hardcoded the removed `onedev` repoURL; superseded by the AppSet idiom. |
| `kubernetes/core/psa/namespace-labels.yaml` | **edited** — `velero` baseline → privileged (blocking, see §2). |
| `platform.yaml` | **edited** — `groups.core-platform.apps.velero.enabled: false → true`. |
| `scripts/sync-groups.sh` | **edited** — `COMPANIONS` now points at `app-velero-manifests.yaml`. |

### Five real defects inherited from the old `values.yaml`

1. `features: "EnableCSI"` — no CSI snapshot stack exists in this cluster.
2. `publicUrl: …${BASE_DOMAIN}` — Helm valueFiles never see the envsubst CMP.
3. `velero-plugin-for-aws:v1.10.0` — pairs with Velero 1.14, not 1.18.
4. `nodeAgent.enabled: true` — **not a key in this chart.** It is `deployNodeAgent`
   at the top level; the node-agent would simply never have been deployed.
5. Schedules at 02:00 — inside the game-hub scale-down window.

---

## 4. Validation performed (nothing applied)

```
$ helm template velero ./velero --namespace velero \
    --values kubernetes/platform/velero/values.yaml --set replicaCount=1
EXIT=0        # 17 objects, no VolumeSnapshotLocation, no Secret (existingSecret used)

$ kubectl apply --dry-run=client -f rendered.yaml
serviceaccount/velero-server created (dry run)
configmap/velero-repo-maintenance created (dry run)
clusterrolebinding.rbac.authorization.k8s.io/velero-server created (dry run)
role.rbac.authorization.k8s.io/velero-server created (dry run)
rolebinding.rbac.authorization.k8s.io/velero-server created (dry run)
service/velero created (dry run)
daemonset.apps/node-agent created (dry run)
deployment.apps/velero created (dry run)
serviceaccount/velero-server-upgrade-crds created (dry run)
clusterrole.rbac.authorization.k8s.io/velero-upgrade-crds created (dry run)
clusterrolebinding.rbac.authorization.k8s.io/velero-upgrade-crds created (dry run)
job.batch/velero-upgrade-crds created (dry run)
resource mapping not found for kind "BackupStorageLocation" / "Schedule"
  -> EXPECTED: Velero CRDs are not installed yet. Validated below instead.

# BSL + Schedules validated against the chart's own bundled CRD OpenAPI schemas:
PASS  BackupStorageLocation   default
PASS  Schedule                velero-daily-gamehub      # deleted 2026-08-19
PASS  Schedule                velero-daily-objects
PASS  Schedule                velero-daily-wordpress
PASS  Schedule                velero-weekly-localpath   # deleted 2026-08-19

$ kubectl apply --dry-run=server -f manifests/externalsecret.yaml
externalsecret.external-secrets.io/velero-s3-credentials created (server dry run)
  # server-side => also passed Kyverno Enforce validate-externalsecret-storeref

$ envsubst < kubernetes/bootstrap/app-velero-manifests.yaml | kubectl apply --dry-run=client -f -
application.argoproj.io/platform-velero-manifests created (dry run)

$ kubectl apply --dry-run=server -f <velero namespace doc from namespace-labels.yaml>
namespace/velero configured (server dry run)

$ bash -n scripts/sync-groups.sh           # OK
$ YAML parse, all 6 changed files          # OK (1,1,1,1,26,1 docs)
$ grep '${' on non-comment lines of values.yaml   # none
```

> **On `kubectl kustomize`:** there is deliberately **no** `kustomization.yaml`
> here. No directory under `kubernetes/platform/` uses kustomize — Helm
> components use `application.yaml` + `values.yaml`, and manifest dirs are plain
> directory-recurse. Introducing kustomize would be off-idiom. The equivalent
> render was validated instead by reproducing what the CMP actually does
> (`find . -name '*.yaml'` concatenated) and dry-running the result.

---

## 5. RESTORE RUNBOOK

Velero is not installed yet. **Step 0 must be done once, and step 6 must be
rehearsed, before any of this is trustworthy.**

### 0. Install the CLI (do this now, not during an incident)

```bash
VELERO_VERSION=v1.18.1
curl -sL "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C /tmp
sudo install /tmp/velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero
velero version
```

### 1. Triage — is there anything to restore from?

```bash
velero backup-location get       # PHASE must be Available
velero backup get                # STATUS Completed, and check the age
velero backup describe <name> --details
velero backup logs <name> | tail -50
```

> If `backup-location` is not `Available`, stop and fix MinIO first — restores
> read from the same bucket. `kubectl -n velero get pods` / `logs deploy/minio-velero`.

### 2. Restore ONE namespace (the common case)

```bash
# Preview first — never restore blind.
velero backup describe <backup> --details | grep -A40 'Resource List'

velero restore create restore-$(date +%s) \
  --from-backup <backup> \
  --include-namespaces wordpress \
  --existing-resource-policy=none      # do NOT overwrite live objects

velero restore describe <restore-name>
velero restore logs   <restore-name>
```

`--existing-resource-policy=none` skips anything that already exists — the safe
default. Use `update` **only** when you intend to overwrite live objects.

### 3. Restore a single application / PVC

> ## ⚠️ STOP — this section used to be a data-loss trap. Corrected 2026-08-19.
>
> It previously said *"For a local-path PVC the data comes back via kopia"* and
> then told you to **delete the damaged PVC** and restore from
> `velero-daily-gamehub-<timestamp>`. Every one of those backups contains **zero
> volume bytes** — measured, per run, 0 PodVolumeBackups — because local-path PVs
> are `hostPath` and Velero's FSB skips them. Following the old steps would have
> deleted a live PVC and restored nothing into its replacement.
>
> **Velero can restore the OBJECT graph of a namespace. For any `local-path` PVC
> it cannot restore the DATA. Never delete a PVC on the strength of a Velero
> backup without first proving that backup holds bytes for that exact volume:**
>
> ```bash
> kubectl -n velero get podvolumebackups.velero.io \
>   -l velero.io/backup-name=<backup> \
>   -o custom-columns=POD:.spec.pod.name,VOL:.spec.volume,PHASE:.status.phase,BYTES:.status.progress.totalBytes
> ```
>
> An empty result means the backup protects **nothing** for that volume.

Restoring the object graph of one application (safe — creates, does not delete):

```bash
velero restore create restore-gtnh-$(date +%s) \
  --from-backup velero-daily-objects-<timestamp> \
  --include-namespaces game-hub \
  --include-resources persistentvolumeclaims,deployments,configmaps,secrets \
  --selector app=gt-new-horizons
```

**Where the DATA actually comes from, per storage class:**

| Volume | Class | Restore source (the real one) |
|---|---|---|
| `game-hub/gt-new-horizons-container-local` | `local-path-retain` | the world archive on `longhorn-retain` — `kubernetes/catalog/game-hub/manifests/world-archive.yaml` (00:30), a save-flushed zip, then the Longhorn → TrueNAS chain |
| `wordpress/hihi-wp-data`, `wordpress/yonavaarwater-nl-wp-data` | `local-path-retain` | `wp-data-archive-group-a` (00:35) → `longhorn-retain` → NAS |
| `nextcloud/nextcloud-data-lp` | `local-path-retain` | `catalog/nextcloud/manifests/data-archive.yaml` (00:45) |
| any other local-path volume | `local-path*` | the catch-all `core/local-path/localpath-offnode-backup.yaml` (00:40) → NFS |
| every Longhorn volume | `longhorn-*` | Longhorn snapshot + TrueNAS backup; check `kubectl -n longhorn-system get backupvolumes.longhorn.io` and read `.status.lastBackupAt` |
| every Postgres | — | the `*-pg-dump` CronJobs → `longhorn-retain`. A logical dump is the only restore-grade DB artefact here. |

The RTO for a local-path volume is therefore: extract the archive tarball/zip
into a fresh PVC and point the workload at it — **not** a Velero restore.

> **local-path is node-pinned.** A newly provisioned local-path PVC binds
> wherever the pod is scheduled, which may be a **different node** than before.
> That is useful when evacuating a node — but the bytes still have to come from
> an archive, not from Velero.

### 4. Evacuating a node before a wipe (the live use case)

```bash
# 1. force a fresh backup of everything pinned to that node, while pods still run
# ⚠️ --default-volumes-to-fs-backup does NOT reach a local-path PVC (hostPath).
# This captures the OBJECT graph plus any LONGHORN volumes in those namespaces.
# For the local-path ones, trigger the archive CronJobs instead (see §3's table)
# and confirm the archive landed BEFORE the node is touched.
# n8n-prod was deleted 2026-08-18 — naming a namespace that does not exist still
# reports Completed, which is the same lie this file exists to prevent.
velero backup create evac-cp1-$(date +%s) \
  --include-namespaces game-hub,wordpress,nextcloud,jellyfin,authentik \
  --default-volumes-to-fs-backup \
  --wait

# 2. VERIFY before touching the node — a Completed backup with 0 items is a lie
velero backup describe evac-cp1-<ts> --details | grep -E 'Phase|Items|Errors'
kubectl -n velero get podvolumebackups \
  -o custom-columns=NAME:.metadata.name,PVC:.spec.volume,NODE:.spec.node,PHASE:.status.phase,SIZE:.status.progress.totalBytes

# 3. only then cordon/drain
kubectl cordon talos-prod-cp1
kubectl drain talos-prod-cp1 --ignore-daemonsets --delete-emptydir-data
```

Step 2 is not optional. Every failure in this repo's backup history has been a
job that reported success while moving zero bytes.

### 5. Total cluster loss

Order matters — Velero's own store lives inside the cluster it is restoring.

1. **Rebuild control plane** from the ops-host etcd snapshot, or reinstall Talos
   and re-bootstrap. See `docs/BACKUP-AND-RESTORE-RUNBOOK.md` §5.
2. **Restore Longhorn + its backup target**, then restore the
   `minio-velero-data` volume from TrueNAS
   (`nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups`) — this is the step that
   makes the Velero bucket exist again. `scripts/restore-from-truenas.sh`.
3. **Bring ArgoCD up** and let GitOps reconcile manifests from GitHub.
4. **Deploy `minio-velero`, then Velero**, pointing at the restored bucket.
5. `velero backup get` — Velero re-syncs backup metadata from the bucket
   automatically (`backupSyncPeriod`).
6. **Restore local-path data** per §2/§3. Everything on Longhorn came back at
   step 2 and must **not** be restored again through Velero.

### 6. Rehearsal — do this before trusting any of it

```bash
kubectl create ns velero-drill
kubectl -n velero-drill create deploy nginx --image=nginx
velero backup create drill-$(date +%s) --include-namespaces velero-drill --wait
kubectl delete ns velero-drill
velero restore create --from-backup drill-<ts> --wait
kubectl -n velero-drill get all      # must come back
kubectl delete ns velero-drill
```

> A backup system that has never restored anything is a hypothesis.

---

## 6. Honest gaps — what this does NOT cover

**Read this section before claiming the cluster is protected.**

1. **`registry/zot-data` (20Gi claim, local-path on cp3) is NOT backed up.**
   A deliberate exclusion: it is a container-image cache, rebuildable from source
   via buildkit, and it is the single largest local-path consumer. Including it
   would risk filling the MinIO PVC. **If cp3 is wiped, the Zot registry
   contents are lost and images must be rebuilt and re-pushed.**

2. **File-system backup only captures volumes of RUNNING pods.** Anything scaled
   to zero at schedule time is silently skipped, and the backup still reports
   `Completed`. This affects game-hub every night (hence the 08:30 slot) and any
   WordPress site parked at 0 replicas. **Always verify `podvolumebackups`, not
   just the Backup phase.**

3. **Game-server backups are crash-consistent, not quiesced.** GTNH is running
   and writing at 08:30. A restored world may need chunk repair. The in-pod
   `/home/container/backups` (1.6G of the 2.4G) partially compensates but has
   only ~6h retention.

4. **The MinIO PVC sizing concern is CLOSED.** The recommended expansion happened:
   re-measured 2026-08-19, `minio-velero-data` is **50Gi** and `df -h /data`
   reports `50G  2.6G  47G  6%` — a real kopia-repo number, not a `du` estimate.
   Deleting `daily-gamehub` and `weekly-localpath` on the same day reduced it
   further. What is still **open** is the alerting: if the bucket ever fills,
   backups fail, and nothing watches for that beyond the ServiceMonitor added
   here. That is the follow-up worth doing, not more capacity.

5. **`minio-velero` is still NOT GitOps-managed, and this change set does not fix
   it.** Every object in the `velero` namespace was hand-applied 62 days ago and
   carries no ArgoCD tracking. **Velero's storage backend is therefore an
   unmanaged, unreconciled workload** — if someone deletes it, GitOps will not
   bring it back. This was left out deliberately to keep the change reviewable:
   adopting live resources also means `platform/minio-velero/manifests/minio.yaml`
   declaring the `velero` Namespace, which would contend with
   `core-psa-manifests` for label ownership under SSA. **Required follow-up, as
   its own commit:**
   - repoint `app-minio-velero.yaml.disabled` from the dead
     `http://onedev.onedev.svc.cluster.local/...` to `${DEPLOY_REPO_URL}`;
   - add `plugin: { name: envsubst-v1.0 }` — `minio.yaml:221` contains a live
     `Host(\`minio-velero.int.${BASE_DOMAIN}\`)` that would otherwise ship verbatim;
   - remove the `Namespace` object from `minio.yaml` (PSA labels are owned solely
     by `core/psa/namespace-labels.yaml`);
   - fix the **duplicated `forward-auth` middleware** listed twice in that
     IngressRoute;
   - set `platform.yaml` `minio-velero.enabled: true`.

6. **The circular dependency is reduced, not eliminated.** Velero's store is a
   Longhorn volume in the cluster it protects. TrueNAS holds a nightly copy of
   that volume, so a full rebuild is possible (§5) — but it is a two-hop
   restore, and the first hop is Longhorn. **A genuinely independent target
   (TrueNAS-hosted S3/MinIO, or an off-site bucket) would be strictly better**
   and is the right long-term fix. Not done here: it needs a TrueNAS S3 endpoint
   and credentials that were not available.

7. **~11% of Longhorn's own backups are failing** (24 Error / 209). Errors are
   mostly transient engine/replica RPC failures consistent with the cp2/cp4 node
   churn of the last 18h, plus `test-wp-data` whose volume is currently
   `faulted`. Out of scope here, but it is the *primary* data-protection layer
   and it is not fully green.

8. **Assumptions made, flagged for review:**
   - The MinIO credential at `secret/platform/minio-velero` is reused for Velero.
     This is an assumption that MinIO's **root** credential is acceptable for
     Velero. A dedicated, least-privilege MinIO service account would be better;
     creating one requires MinIO admin access not exercised here.
   - Schedule times are **UTC** (cluster default). Local wall-clock in
     Europe/Amsterdam is UTC+2 in August — 08:30 UTC is 10:30 local. If the
     game-hub scale windows are ever reasoned about in local time, re-check the
     08:30 slot against them.
   - No NetworkPolicy is authored for `velero`. None currently covers the
     namespace, so nothing blocks Velero today. **If the airgap baseline is ever
     extended to `velero`, egress to `minio-velero.velero.svc:9000` and to the
     Kubernetes API must be allowed explicitly** — Longhorn's NAS backups
     silently failed for 39 days on exactly this mistake.
