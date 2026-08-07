# Backup and Restore Runbook

**Scope:** Longhorn persistent volumes, Talos/etcd control-plane state.
**Owner:** platform admin. **Created:** 2026-08-07 (WP2 / GAP-C2, GAP-M7).
**Related:** [`kubernetes/core/etcd-maintenance/snapshot-README.md`](../kubernetes/core/etcd-maintenance/snapshot-README.md) ·
[`PRIVATE-PUBLIC-GITOPS-AND-DR.md`](PRIVATE-PUBLIC-GITOPS-AND-DR.md)

---

## 0. READ THIS FIRST — current honest state

> **Updated 2026-08-07 — §4a is now VERIFIED; everything else is still not.**
>
> A Longhorn volume backup and restore was performed end to end and verified by
> checksum on 2026-08-07. See the drill log in §7 for the row, the timings, and
> the defect that had to be fixed first (the backup target was configured but
> unreachable, and no backup had *ever* been taken). §4a is therefore a proven
> procedure.
>
> Still unproven, and to be treated as such in any compliance evidence:
> **§4b** (destructive restore over a live volume), **§4c** (full rebuild), and
> **§5** (etcd / control plane) — no etcd restore or tabletop has been done.
> The §7 drill also used a purpose-built scratch volume, so no *production*
> volume has yet been restored.

As of 2026-08-07, the measured state that this runbook's changes repair:

| Fact | Evidence |
|---|---|
| Longhorn `BackupTarget/default` had `backupTargetURL: ""`, `available: false`, condition `Unavailable: backup target URL is empty` | `kubectl get backuptarget -n longhorn-system -o yaml` |
| `longhorn-manager` had been rejecting the configured target for the life of the cluster | log: `failed to parse nfs://${TRUENAS_HOST}:/mnt/pool/k8s-longhorn-backups as url: invalid character "{" in host name` |
| **Zero** `backups.longhorn.io` resources had ever existed | `kubectl get backups.longhorn.io -A` → `No resources found` |
| The nightly RecurringJob had been finding nothing and exiting 0 for 54 days | job log: `Found 0 volumes with recurring job truenas-backup-daily` |
| `longhorn-backup-verifier` last run **Failed**, no `lastSuccessfulTime` ever | `kubectl get cronjob -n longhorn-system longhorn-backup-verifier -o jsonpath='{.status}'` |
| No etcd snapshot schedule existed anywhere | searched cluster CronJobs, ops host crontabs, both repos |
| Velero not deployed | `bootstrap/app-velero.yaml.disabled`; `velero` namespace holds only `minio-velero` |

**Two volumes deserve special attention** because they hold backups of *other*
things and were themselves entirely unprotected:

- `infraweaver-console/infraweaver-backup-datastore` — the WordPress fleet
  backup datastore. The one backup system previously verified working stored its
  data on a Longhorn volume that had no volume-level backup.
- `velero/minio-velero-data` — the S3 bucket Velero would restore *from*.

---

## 1. What is protected, and what is not

| Data | Mechanism | Frequency | Off-box? | Restore tested? |
|---|---|---|---|---|
| Longhorn PV contents | Longhorn RecurringJob `backup` → TrueNAS NFS | 01:00 daily (retain 7), 02:00 Sun weekly (retain 4) | Yes — `nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups` | **NO** |
| Longhorn local snapshots | RecurringJob `snapshot` | 00:00 daily (retain 3) | **No** — same replicas as the volume | **NO** |
| etcd / control-plane state | `talosctl etcd snapshot` from ops host | 03:40 UTC daily (local retain 7, remote retain 30) | Yes — TrueNAS SMB | **NO** |
| Kubernetes API objects | **Git** (ArgoCD, 61 Applications) | every commit | Yes — GitHub | Partially (redeploys happen) |
| WordPress site data | signed datastore, separate path | per site policy | Yes | Yes (verified 2026-07-30) |
| Talos machine configs | `params/mc-talos-prod-cp*.yaml`, committed **2026-06-10** | **never refreshed** | Yes — Git | **NO** |
| Authentik Postgres, other `local-path` PVCs | **NOTHING** | — | — | — |

> ⚠️ **Known uncovered gap.** `authentik/data-authentik-postgresql-0` and
> `authentik/redis-data-authentik-redis-master-0` carry the
> `recurring-job-group.longhorn.io/truenas-backup: enabled` annotation but are
> **not Longhorn volumes** — they are on `local-path`, i.e. a single node's
> disk. The annotation is inert there. Authentik is the SSO for every admin
> surface on this platform; losing that node loses the identity provider.
> Migrating those PVCs to Longhorn (or dumping Postgres on a schedule) is
> **out of WP2's file ownership** and is tracked as a follow-up in §8.

---

## 2. Configuration reference

### Longhorn backup target

Declared in [`kubernetes/core/longhorn/values.yaml`](../kubernetes/core/longhorn/values.yaml):

```yaml
backupTarget: "nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups"
allowRecurringJobWhileVolumeDetached: true
```

The host is a **resolved literal on purpose**. That file is a Helm valueFile
consumed by ArgoCD-native Helm (`kubernetes/bootstrap/appset-core.yaml`), which
does **not** run the `envsubst-v1.0` CMP — only sources declaring
`plugin: { name: envsubst-v1.0 }` do. A `${TRUENAS_HOST}` here reaches the
cluster verbatim. The same rule is already recorded in `core/openbao/values.yaml`,
`platform/authentik/values.yaml` and `platform/external-dns/values.yaml`.

**Do not "fix" this by changing `TRUENAS_HOST` in `.env`.** That parameter is
also consumed by the console Deployment and the Authentik LDAP outpost; its
live value (`10.1.0.5`) is a *different host* with no NFS and no SMB listener,
and correcting it is outside WP2's scope. See §8.

Verified 2026-08-07 by `MOUNTPROC3_EXPORT` RPC against `10.1.0.135`:

```
EXPORT /mnt/pool/k8s-longhorn-backups   clients=['10.0.0.0/24']
```

The export exists and is ACL'd to exactly the cluster node subnet.

### etcd snapshots

`InfraWeaver-base` (infrastructure repo):
- `scripts/etcd-snapshot.sh` — the snapshot/ship/prune script
- `ansible/playbooks/etcd-snapshot-cron.yml` — installs it on the
  `etcd_snapshot_hosts` inventory group

Design rationale (why ops host and not in-cluster):
[`snapshot-README.md`](../kubernetes/core/etcd-maintenance/snapshot-README.md).

---

## 3. Health checks (run these first, always)

```bash
export KUBECONFIG=~/.kube/config-platform-productie

# 1. Is the backup target actually usable?
kubectl get backuptarget -n longhorn-system default \
  -o jsonpath='{.spec.backupTargetURL}{"  available="}{.status.available}{"\n"}'
# WANT: nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups  available=true

# 2. Do backups exist?
kubectl get backups.longhorn.io -n longhorn-system
# WANT: one or more rows. "No resources found" means backups are NOT happening.

# 3. Did the verifier succeed?
kubectl get cronjob -n longhorn-system longhorn-backup-verifier \
  -o jsonpath='{.status.lastSuccessfulTime}{"\n"}'
# WANT: a timestamp within the last 24h. Empty = never succeeded.

# 4. Are volumes actually enrolled? (the silent-failure check)
kubectl get volumes.longhorn.io -n longhorn-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\n"}{end}' \
  | grep -c 'recurring-job-group'
# Compare against the total volume count. A job scoped to a group that no
# volume belongs to logs "Found 0 volumes" and exits 0.

# 5. etcd snapshots present and fresh (on the ops host)
ls -l /var/backups/etcd/etcd-*.db.gz | tail -3
smbclient //10.1.0.135/infraweaver -A /etc/infraweaver/etcd-snapshot-smb.auth \
  -c 'cd etcd-snapshots; ls' | tail -5
```

**Alerting.** `LonghornBackupVerifierMissedSuccess` exists in
`kubernetes/monitoring/alerts/manifests/prometheus-rules.yaml`. Delivery is
Discord-only with no escalation (GAP-M4) — do not rely on it as the sole signal.
There is **no alert at all** for the etcd snapshot cron; add one (§8).

---

## 4. Restore: a Longhorn volume

> **UNVERIFIED.** No volume restore has been performed on this platform.
> Do the drill in §7 before you ever need this for real.

### 4a. Restore a single volume to a NEW PVC (non-destructive — start here)

This is the safe shape: it never touches the live volume, so a mistake costs
disk space and nothing else. Use it for the drill and for
"recover one file from yesterday".

1. **Find the backup.** Longhorn UI (`https://longhorn.int.example.com`) →
   *Backup* → pick the volume → note the backup name and timestamp. Or:

   ```bash
   kubectl get backups.longhorn.io -n longhorn-system \
     -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,CREATED:.status.backupCreatedAt,SIZE:.status.size
   ```

2. **Restore into a new Longhorn volume** via the UI:
   *Backup → select → Restore Latest Backup*, and give it a **new name**
   (e.g. `restore-drill-<date>`). Do **not** reuse the original volume name.

3. **Create a PV/PVC bound to the restored volume.** In the Longhorn UI:
   *Volume → select the restored volume → Create PV/PVC*, targeting a scratch
   namespace. Confirm:

   ```bash
   kubectl get pvc -n <scratch-ns>
   ```

4. **Mount it read-only from a throwaway pod and verify the contents** —
   file count, a known file's checksum, database `SELECT count(*)`. *Restoring a
   volume is not the test; reading correct data out of it is.*

5. **Clean up** the scratch PVC and restored volume when done.

### 4b. Restore over an existing, in-use volume (destructive)

1. **Scale the workload to zero** and confirm no pod holds the PVC:
   `kubectl scale deploy/<name> -n <ns> --replicas=0`
2. **Snapshot the current state first** (Longhorn UI → Volume → *Take Snapshot*).
   Even a corrupt current state is evidence; do not destroy it.
3. Restore to a **new** volume per §4a, verify the data, then swap the PVC's
   `volumeName` / recreate the PVC against the restored PV.
4. Scale the workload back up and verify at the application level.

Never restore in place over a volume that a running pod has attached.

### 4c. Full cluster rebuild

`scripts/restore-from-truenas.sh` restores all known volumes from the TrueNAS
NFS target **before** apps deploy. Read its header before running; it needs
`kubectl`, `jq`, Longhorn deployed, and a reachable backup target. Run its
`--dry-run` first — it lists available backups without restoring.

---

## 5. Restore: etcd / control plane

> **UNVERIFIED and HIGH RISK.** An etcd restore rewrites the entire cluster
> state. It is a last resort, after node-level recovery has been ruled out.

### 5a. Decide whether you actually need it

| Symptom | Do NOT restore etcd |
|---|---|
| One control-plane node down | Talos + etcd tolerate 1 of 3 lost. Repair the node. |
| Cluster reachable, one app broken | Fix the app or revert the Git commit. |
| ArgoCD out of sync | GitOps, not DR. |

Restore etcd only when **quorum is permanently lost** (2 of 3 members gone with
unrecoverable disks) or etcd data is corrupt on all members.

### 5b. Procedure (Talos)

1. **Fetch the snapshot and check it before trusting it.**

   ```bash
   # on the ops host
   ls -l /var/backups/etcd/
   cat /var/backups/etcd/etcd-infraweaver-prod-<stamp>.db.gz.meta   # hash/revision/keys
   sha256sum -c <(printf '%s  %s\n' \
     "$(cat /var/backups/etcd/etcd-...db.gz.sha256)" \
     "/var/backups/etcd/etcd-...db.gz")
   gzip -t /var/backups/etcd/etcd-...db.gz && echo "archive OK"
   gunzip -k /var/backups/etcd/etcd-...db.gz
   ```

   The `.meta` sidecar holds `talosctl`'s own line, e.g.
   `snapshot info: hash 339f8856, revision 58686692, total keys 4700`.
   A revision far behind what you expect means you grabbed the wrong file.

2. **Confirm you have a current machine config for each node.** A restore needs
   both. `params/mc-talos-prod-cp*.yaml` were committed 2026-06-10 and may have
   drifted — capture the live ones *now* if the nodes are still reachable:

   ```bash
   talosctl -n 10.0.0.90 get mc v1alpha1 -o yaml > mc-cp1-$(date -u +%F).yaml
   ```

3. **Bootstrap the recovery.** With the cluster down, on the node that will
   become the first member:

   ```bash
   talosctl -n <node> bootstrap --recover-from ./etcd-...db
   ```

   Talos brings up a single-member etcd from the snapshot. Consult the Talos
   docs for the running version (`talosctl version`) before typing this —
   **the flag set has changed between Talos releases**; this repo's cluster is
   Talos v1.13.0 with a v1.12.7 client.

4. **Rejoin the other two members** by resetting them and letting them join the
   recovered quorum. Do them **one at a time**, confirming
   `talosctl -n <all> etcd status` shows a healthy raft after each.

5. **Expect divergence.** Everything that happened after the snapshot's revision
   is gone: tokens minted, PVCs created, secrets rotated. Cross-check
   immediately afterwards:
   - ArgoCD: `kubectl get applications -A` → drive to Synced/Healthy from Git.
   - ExternalSecrets: `kubectl get externalsecrets -A` → all `Ready=True`.
   - Longhorn: `kubectl get volumes.longhorn.io -n longhorn-system` → volume CRs
     must match the PVs actually on disk. **etcd restore does not restore volume
     data** — Longhorn replica data lives on the nodes' disks, not in etcd. If
     the disks are also gone, restore volumes per §4c *after* the control plane
     is back.

---

## 6. Rollback of this runbook's changes

| Change | Rollback |
|---|---|
| `core/longhorn/values.yaml` backupTarget literal | revert the commit; ArgoCD returns Longhorn to the empty target (the previously broken state) |
| `allowRecurringJobWhileVolumeDetached: true` | revert; detached volumes go back to being silently skipped |
| `manifests/backup-jobs.yaml` group `default` | revert; jobs return to matching zero volumes |
| ops-host cron | `ansible.builtin.cron: state=absent` with the same `cron_file`, or `rm /etc/cron.d/infraweaver-etcd-snapshot` |

None of these changes can destroy data. The worst case of a bad backup target is
the state the platform was already in.

---

## 7. Drill log

> **⛔ THE FIRST REQUIRED ACTION FOR THIS PLATFORM IS TO FILL IN A ROW HERE.**
> A backup system that has never restored anything is a hypothesis. GAP-C2 went
> unnoticed for 54 days precisely because nothing ever tried to read the backups
> back. Until a row exists below, this platform's DR posture is "untested",
> not "working" — say so in any compliance evidence.

Run drills **quarterly** and after any change to the backup target, the NAS, or
the Longhorn/Talos version.

| Date | Type | Operator | Source artifact | Target | Result | Data verified how | Time to restore | Issues found |
|---|---|---|---|---|---|---|---|---|
| 2026-08-07 | Longhorn volume, §4a non-destructive | platform admin (assisted) | `drill-backup-20260807` of `pvc-f53b7533…4650` — a purpose-built 1 GiB scratch volume in ns `restore-drill`, 201 files including a 16 MiB urandom blob | new volume `restore-drill-20260807` + scratch PVC `drill-restored`, mounted **read-only** | **PASS** | `sha256sum -c MANIFEST.sha256` inside the restored volume → `OK_LINES=201`, `FAILED_LINES=0`; independent fingerprint `sha256(MANIFEST.sha256)` read back as `9609c60a8bbfbef3dfb9a93ed53935ab68c6d4062be705c1f72b0569136e3a33`, byte-identical to what the writer pod printed before the backup existed | backup 8 s (86 MB stored, lz4); restore + verify 2 m 18 s (17:10:31Z → 17:12:49Z) | The drill could not start until a real defect was fixed — see below. Two follow-ups opened (§8). |

**What this row proves, and what it does not.** It proves the whole chain —
snapshot → NFS upload → BackupVolume → restore into a new volume → PV/PVC →
mounted filesystem — moves bytes correctly and losslessly, and that the §4a
procedure as written is executable. It does **not** prove any *production*
volume has ever been restored: the source was a scratch volume built for the
drill. The next drill should use a real `game-hub` volume.

**Blocker found and fixed on the way in.** `BackupTarget/default` still read
`available=false` and *zero* `backups.longhorn.io` existed, even after the
`${TRUENAS_HOST}` placeholder fix — so §0's table was accurate about the
symptom but the diagnosis was incomplete. Cause:
`longhorn-system/airgap-baseline` permitted egress only to
`cluster/host/remote-node/kube-apiserver` plus DNS, so the NAS — an external
host — was denied. Measured from inside a `longhorn-manager` pod before the fix:
`10.1.0.135:111` and `:2049` both timed out. That file's own header had
predicted this exact requirement on 2026-06-29; the note sat unactioned for 39
days. Fixed by a `toCIDR: [10.1.0.135/32]` egress on 2049+111 (commit
`71371b3`), after which `available=true` on the first resync.

The router was investigated and **not** changed: `productie` and `Homelab`
share the UniFi `Internal` zone, whose intra-zone policy is allow-all, and a pod
in `infraweaver-console` reached `10.1.0.135:2049` at the same moment a
`longhorn-manager` pod could not. A firewall rule created during diagnosis was
proved to change nothing and was deleted; the perimeter is unchanged.

This is precisely the "a control can read as present and be absent" failure this
platform keeps hitting. It was caught by *trying to use* the control, not by
reading its configuration.

### Drill template — Longhorn volume (do this one first)

1. Pick a **low-value** volume with a backup (a `game-hub` test volume is ideal;
   do **not** drill on `infraweaver-backup-datastore` or `minio-velero-data`).
2. Note the expected content: file count, a checksum, a row count.
3. Restore to a **new** volume + scratch PVC per §4a. Never over the original.
4. Mount read-only, verify against step 2. **Record the actual verification
   command and its output**, not "looked fine".
5. Record start/end time. Delete the scratch objects.
6. Add a row above. If anything failed, that is the *valuable* outcome — record
   it and fix it before claiming DR works.

### Drill template — etcd (tabletop first, live only in a maintenance window)

1. Fetch the newest snapshot, verify sha256, `gzip -t`, and read the `.meta`.
2. Confirm a **current** machine config exists for each of cp1/cp2/cp3.
3. Walk §5b aloud against the Talos docs for the *running* version; record every
   step whose flags differ from what is written here and correct this document.
4. Only attempt a live restore on a scratch cluster or during a declared window
   with a full Longhorn backup completed first.

---

## 8. Follow-ups (not done in this change)

### Velero — deliberate decision to defer

Velero was **not** re-enabled here, deliberately. One backup change at a time:
Longhorn volume backups have never once worked, and mixing a second, untested
backup system into the same change would make it impossible to tell which one
produced any given result. Velero and Longhorn are complementary, not
alternatives (Velero = API objects, Longhorn = volume data), and Git already
covers the API objects for all 61 ArgoCD-managed Applications.

**Decision required after the first successful Longhorn drill (§7):**
either (a) re-enable `bootstrap/app-velero.yaml.disabled` to capture the
non-GitOps objects Git does not hold, or (b) formally document Velero as
excluded, with Git-as-source-of-truth plus etcd snapshots named as the
compensating control in the Statement of Applicability. Note that
`minio-velero` is *already running* and consuming a Longhorn volume while
serving no backup — that alone should be resolved either way.

### Other open items

| # | Item | Why it matters |
|---|---|---|
| ~~1~~ | ~~**Run the first restore drill** (§7)~~ — **DONE 2026-08-07**, PASS | Superseded by: drill a *production* volume next; §4b/§4c/§5 remain unproven |
| ~~2~~ | ~~Verify `available=true` and ≥1 `backups.longhorn.io`~~ — **DONE 2026-08-07** | `available=true` reached only after the `airgap-baseline` egress fix (`71371b3`); a backup was created, restored, verified and cleaned up |
| 2a | **Confirm the 01:00 recurring run actually produces backups** | All 21 volumes carry a `recurring-job` group label and the jobs include group `default`, so the enrolment gap is closed *on paper*. The first unattended nightly run is the proof. Check the morning after `71371b3` landed. |
| 2b | **7 orphaned backups (~1.4 GB) sit on the NAS from a previous cluster** | Once the target became readable, 7 `backups.longhorn.io` from 2026-05-08…05-18 appeared, for volumes (`pvc-ebc6736d…`, `pvc-3b784d59…`, `pvc-55cdbec9…`) that no longer exist. No retention job will ever prune them — recurring-job retention only prunes volumes it manages. Decide: delete, or keep and count them in the capacity plan (item 8). |
| 3 | `TRUENAS_HOST=10.1.0.5` in the CMP substitutions is wrong (no NFS/SMB there; the NAS is `10.1.0.135`) | Also consumed by the console and Authentik LDAP outpost — check what else it has silently broken |
| 4 | Authentik Postgres/Redis on `local-path` have **no backup** | SSO for every admin surface; single-node disk |
| 5 | No alert on etcd-snapshot cron failure | The Longhorn verifier alert has no etcd counterpart |
| 6 | Talos machine configs in `params/` last refreshed 2026-06-10 | An etcd restore needs a current machine config |
| 7 | Provision the TrueNAS `etcd-snapshots` SMB directory + dedicated credential | Prerequisite before the ansible playbook runs with `transport: smb` |
| 8 | Capacity: NAS free space vs 19 volumes × (7 daily + 4 weekly) | ~48 GiB actual data today; first full backup ~48 GiB |
