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
>
> **Updated 2026-08-07 ~21:00 UTC.** The production restore drill is now written
> in full (§7, "Drill — restore a PRODUCTION volume") with its candidate chosen
> and verified, and it is **blocked, not skipped**: no backup of any production
> volume exists yet, because the first unattended 01:00 run has not happened.
> An etcd tabletop was performed and recorded as **PARTIAL/BLOCKED** — it could
> not reach step 1 for the same reason, but the two steps it did complete found
> five real defects in §5b, including archived machine configs that would not
> have restored this cluster. §5 is still unproven and §1's etcd row now says so.

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
| etcd / control-plane state | **NOTHING RUNS.** The script and playbook exist (`InfraWeaver-base` `scripts/etcd-snapshot.sh` + `ansible/playbooks/etcd-snapshot-cron.yml`) but have **never been installed** — see the callout below | designed 03:40 UTC daily; **has never fired** | designed TrueNAS SMB; the `etcd-snapshots` directory and its credential **do not exist yet** | **NO — no snapshot has ever been taken** |
| Kubernetes API objects | **Git** (ArgoCD, 61 Applications) | every commit | Yes — GitHub | Partially (redeploys happen) |
| WordPress site data | signed datastore, separate path | per site policy | Yes | Yes (verified 2026-07-30) |
| Talos machine configs | `params/mc-talos-prod-cp*.yaml` on the ops host. Refreshed 2026-08-07 (`…-cp{1,2,3}-2026-08-07.yaml`, `talosctl validate` OK); the 2026-06-10 set is kept alongside and is **stale in five fields that would break a restore** — see the §5b step 2 callout | on demand, manually | **NO — and the §1 row used to claim "Yes — Git".** `params/` is gitignored (`.gitignore:55`) and `git log -- params/` is empty. These files exist **only on this VM's disk**, and this VM is a guest on the same Proxmox cluster as the nodes they would rebuild | **NO** |
| Authentik Postgres (SSO database) | `pg_dump -Fc` CronJob → Longhorn PVC `authentik-pg-dumps` → the 01:00 Longhorn NAS backup (`platform/authentik/manifests/pg-backup.yaml`) | 00:15 daily, 14 dumps retained on the PVC | Yes — via the Longhorn chain, one hop | **NO — not yet restore-tested** (procedure: §4d) |
| Authentik Redis | **NOTHING, by decision 2026-08-07** — accepted loss | — | — | N/A — sessions/cache/task queue only |
| Other `local-path` PVCs | **NOTHING** | — | — | — |

> ⛔ **The etcd row above used to read "03:40 UTC daily … Yes — TrueNAS SMB".**
> That described the *design*, not reality, and it was written the same day the
> design was authored. Corrected 2026-08-07 ~19:00 UTC against the ops host
> (10.1.0.108), by measurement:
>
> | Check | Command | Result |
> |---|---|---|
> | cron entry installed? | `ls /etc/cron.d/` | `.placeholder`, `e2scrub_all`, `php`, `sysstat` — **no infraweaver entry** |
> | user crontab? | `crontab -l` | only the Claude crash collector |
> | any snapshot on disk? | `ls /var/backups/etcd/` | **directory does not exist** |
> | inventory group the playbook targets? | `grep -rn etcd_snapshot_hosts InfraWeaver-base/` | only the playbook's own `hosts:` line — **the group is defined nowhere**, so the playbook cannot run |
> | snapshot-freshness alert? | `etcd.health` group in `monitoring/alerts/manifests/prometheus-rules.yaml` | only `EtcdHighCommitDuration` + `EtcdMemberDown` — **no snapshot alert of any kind** |
>
> A runbook that asserts a control which has never executed is the same defect
> class as `BackupTarget` reading "configured" for 54 days while backing up
> nothing (§7). The row stays as written above until a snapshot has been taken,
> shipped, and read back off the NAS — see §8 items 5–7 for the exact remaining
> steps and who owns each.

> ⚠️ **The two Authentik PVCs carry an annotation that protects nothing.**
> `authentik/data-authentik-postgresql-0` (pinned to **talos-prod-cp2**) and
> `authentik/redis-data-authentik-redis-master-0` (pinned to **talos-prod-cp3**)
> both carry `recurring-job-group.longhorn.io/truenas-backup: "enabled"`. It is
> inert twice over: they are `local-path` PVCs, not Longhorn volumes; and PVC
> annotations never propagate to a Longhorn `Volume` CR anyway (only a
> StorageClass `recurringJobSelector` or a label on the Volume enrols anything —
> see `core/longhorn/manifests/backup-jobs.yaml`).
>
> The annotation is **left in place on purpose**, now with that written next to
> it in `platform/authentik/values.yaml` and `manifests/redis.yaml`. It renders
> into each StatefulSet's `volumeClaimTemplates`, and Kubernetes forbids
> updating any StatefulSet spec field other than `replicas`, `ordinals`,
> `template`, `updateStrategy`, `persistentVolumeClaimRetentionPolicy` and
> `minReadySeconds` — deleting it would fail every ArgoCD sync of
> `platform-authentik` / `apps-authentik-manifests` on an immutable-field
> rejection. It is removed in the same window that recreates the StatefulSets.
>
> **What actually protects the SSO database now:** the nightly `pg_dump`
> (`platform/authentik/manifests/pg-backup.yaml`, 00:15 UTC) writing to the
> Longhorn PVC `authentik-pg-dumps`, which the 01:00 RecurringJob ships to the
> NAS. Restore procedure: §4d.
>
> **What is still open, and is accepted:** *availability*, not durability. The
> dump closes "cp2's disk dies and the identity provider is gone forever". It
> does not close "cp2's disk dies and SSO is down for hours" — recovery is
> redeploy-postgres-then-`pg_restore`, not a failover. The optional upgrade is
> migrating `data-authentik-postgresql-0` to `longhorn-retain` (2 replicas,
> block-level nightly NAS backup). **Do not do it as a side effect of a backup
> change:** `volumeClaimTemplates` are immutable, so it needs the StatefulSet
> deleted with `--cascade=orphan` and re-synced (or switched to
> `postgresql.primary.persistence.existingClaim`), with the SSO — and therefore
> ArgoCD, the console, Grafana, the Longhorn UI and the OpenBao UI — down for
> the scale-down → copy → PVC-swap → STS-recreate window. Realistically 15–30
> minutes clean, hours if the Helm/ArgoCD interplay on an immutable field
> misbehaves. It also contradicts the recorded reason `local-path` was chosen
> (`values.yaml`: "stable with 2 nodes/cp3 offline"). Operator-scheduled
> maintenance window, with a fresh dump taken immediately beforehand. Tracked in
> §8.

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

**Correcting `TRUENAS_HOST` will not change this line, and must not.** Helm apps
never pass through the CMP, so the literal above stays a literal whatever the
parameter says. Do not "simplify" it back to `${TRUENAS_HOST}` later.

The parameter itself IS wrong and is being corrected separately: the live
`argocd-cmp-substitutions` ConfigMap carries `TRUENAS_HOST=10.1.0.5`, a
different host that answers HTTPS with a 404 and has no NFS and no SMB listener.
The NAS is `10.1.0.135`. Every real consumer already carries its own resolved
literal (this file; the console's prod kustomize overlay; the OpenBao
`nas/providers` entry), so nothing is broken by it *today* — what is wrong is the
parameter SOURCE, which would re-poison any new consumer and any DR rebuild.
The correction has a hard ordering constraint (the ConfigMap renders itself
through the sidecar that reads it): see
`docs/SECURITY-REMEDIATION-RUNBOOK.md` §P2.4.

An earlier revision of this note said the Authentik LDAP outpost also consumed
this parameter. That outpost was deleted 2026-08-07 — it had never worked.

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
- `ansible/inventory.ini` — **defines that group.** It did not exist until
  2026-08-07; the playbook targeted a group nothing declared, which is why it had
  never been run. Content (no secrets — SMB credentials are passed with `-e` at
  run time and land only in `/etc/infraweaver/etcd-snapshot-smb.auth`, 0600):

  ```ini
  [etcd_snapshot_hosts]
  localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3

  [etcd_snapshot_hosts:vars]
  etcd_snapshot_talos_node_override=10.0.0.90
  etcd_snapshot_talosconfig_override=/home/runner/.talos/config
  ```

  The ops host is this VM — hostname `github-runner`, 10.1.0.108 / 10.0.0.108 —
  because it already holds `~/.talos/config` with the `os:admin` certificate that
  `talosctl etcd snapshot` needs. Deliberately not the Proxmox nodes.

Design rationale (why ops host and not in-cluster):
[`snapshot-README.md`](../kubernetes/core/etcd-maintenance/snapshot-README.md).

**Ops-host readiness, measured 2026-08-07 — two of these block installation:**

| Requirement | State | Note |
|---|---|---|
| `talosctl` | ✅ `/usr/local/bin/talosctl`, client **v1.12.7** | server is v1.13.0; skew is fine for `get mc` and `etcd snapshot`, **not** for the restore path — see §5b |
| talosconfig context | ✅ `infraweaver-prod`, roles `os:admin`, nodes .90/.91/.92, cert valid to 2027-06-13 | `~/.talos/` holds ~15 other config variants incl. `config-recovered` — always `talosctl config info` first |
| `gzip`, `flock`, `smbclient` | ✅ all present | the playbook preflights all three |
| passwordless `sudo` | ✅ `sudo -n true` succeeds | so steps 3–4 are **not** operator-gated on a password prompt |
| `ansible-playbook` | ❌ **NOT INSTALLED**, and the `ansible/Dockerfile` image is not built locally | install `ansible-core` (or build and run that image) before the playbook can run |
| free space at `/var/backups` | ⚠️ **2.9 GB free on `/`, 95% used** | the script's own `MIN_FREE_MB=2048` preflight is ~900 MB from refusing to run. It stages a ~314 MB raw `.db` before gzipping, and keeps `LOCAL_RETAIN=7`. Free space on the ops host, or lower `LOCAL_RETAIN` — the remote copy is the one that matters |
| TrueNAS `etcd-snapshots` dir + credential | ❌ does not exist | operator-gated, §8 item 7 |

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
# AS OF 2026-08-07 BOTH OF THESE FAIL, and that is the correct current answer:
#   ls: /var/backups/etcd/: No such file or directory
#   (no /etc/infraweaver/etcd-snapshot-smb.auth either — the cron was never installed)
# Treat a failure here as "the control does not exist", not "the check is broken",
# until §8 items 5-7 are closed.
ls -l /var/backups/etcd/etcd-*.db.gz | tail -3
smbclient //10.1.0.135/infraweaver -A /etc/infraweaver/etcd-snapshot-smb.auth \
  -c 'cd etcd-snapshots; ls' | tail -5

# 5b. Is the schedule even installed? (run this first — it explains a failing #5)
ls -l /etc/cron.d/infraweaver-etcd-snapshot   # WANT: exists. Today: No such file.
```

**Alerting.** The backup chain is covered by the **critical**-severity
`cronjob.backup.chain` group in `kubernetes/monitoring/alerts/cronjob-health.yaml`:

| Alert | Condition |
|---|---|
| `BackupCronJobMissedSuccess` | no success within 2x the CronJob's own schedule interval (clamped 1h–8d; 48h for the daily verifier) |
| `BackupCronJobNeverSucceeded` | zero successes ever, older than 26h — the case a `time() - lastSuccessfulTime` rule structurally cannot see |
| `BackupCronJobSuspended` | suspended, so every staleness rule above is deliberately blind |
| `BackupCronJobAbsent` | the CronJob object itself is gone (deleted or pruned) |

It replaces `LonghornBackupVerifierMissedSuccess`, which was removed on
2026-08-07: that rule computed `time() - kube_cronjob_status_last_successful_time`
on a CronJob that had **never** succeeded, so the series it subtracted did not
exist and the alert sat green for 54 days. Delivery is still Discord-only in
practice with no working second transport (GAP-M4) — do not rely on it as the
sole signal. There is **no alert at all** for the etcd snapshot cron; the
`etcd-snapshot-verifier` name is already reserved in the backup-chain selectors,
so deploying that verifier CronJob arms all four alerts above with no rule change
— except adding its `absent()` line to `BackupCronJobAbsent` in the same commit
(adding it earlier fires a permanent false critical). See §8.

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

### 4d. Restore the Authentik (SSO) database from a `pg_dump`

> **UNVERIFIED.** Written 2026-08-07 alongside the dump CronJob; no dump has been
> restored yet. Prove it with the verification below **before** counting the SSO
> as protected — a dump that has never been restored is a file, not a backup.

The dumps live on the Longhorn PVC `authentik/authentik-pg-dumps` (14 retained),
and — one hop later — inside each nightly NAS backup of that volume.

**Where the dump comes from, in the two cases that matter:**

| Situation | Get the dump from |
|---|---|
| DB corrupt, cluster fine | the PVC directly — mount it read-only from a scratch pod |
| Cluster/volume lost | restore the Longhorn volume behind `authentik-pg-dumps` per §4a, then mount it |

**Non-destructive verification (this is also the drill — do this first):**

```bash
export KUBECONFIG=~/.kube/config-platform-productie
# The PVC is RWO. Run this only when the dump Job's pod has exited, or it will
# sit Pending on Multi-Attach forever.
kubectl -n authentik get pods -l app.kubernetes.io/name=authentik-pg-dump

# Restore the newest dump into a THROWAWAY postgres and count real rows.
kubectl -n authentik run pg-verify --rm -i --restart=Never \
  --image=docker.io/library/postgres:17.10-bookworm \
  --overrides='{"spec":{"containers":[{"name":"pg-verify","image":"docker.io/library/postgres:17.10-bookworm","env":[{"name":"POSTGRES_PASSWORD","value":"scratch"},{"name":"PGDATA","value":"/tmp/pgdata"}],"command":["bash","-ec","docker-entrypoint.sh postgres & for i in $(seq 30); do pg_isready -U postgres -q && break; sleep 2; done; D=$(ls -1t /restore/*.dump | head -1); echo USING $D; pg_restore -U postgres -d postgres --create \"$D\"; psql -U postgres -d authentik -tc 'select count(*) from core_user;'"],"volumeMounts":[{"name":"dumps","mountPath":"/restore","readOnly":true}],"resources":{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"memory":"1Gi"}}}],"volumes":[{"name":"dumps","persistentVolumeClaim":{"claimName":"authentik-pg-dumps","readOnly":true}}]}}'

# Compare against the LIVE database. Do not echo the password into the log.
kubectl -n authentik exec authentik-postgresql-0 -- env \
  PGPASSWORD="$(kubectl -n authentik get secret authentik-secrets -o jsonpath='{.data.postgresql-password}' | base64 -d)" \
  psql -U authentik -d authentik -tc 'select count(*) from core_user;'
```

**PASS** = the restored `core_user` count equals the live count (allowing for
accounts created since the dump). "pg_restore exited 0" is not a pass.

**Real restore, when the live database is the thing that is broken:**

1. Scale Authentik down so nothing writes during the restore:
   `kubectl -n authentik scale deploy/authentik-server deploy/authentik-worker --replicas=0`
2. Keep the current broken state — rename the database rather than dropping it:
   `psql -U authentik -d postgres -c 'ALTER DATABASE authentik RENAME TO authentik_broken_<date>;'`
   Even a corrupt database is evidence.
3. `pg_restore -U authentik -d postgres --create --exit-on-error /dumps/authentik-<stamp>.dump`
4. Scale Authentik back up, then log in through the real front door
   (`auth.example.com`) — an SSO restore is only proven by an actual login.
5. Record the outcome in §7.

**Known limitation.** The dump does not contain the Authentik `secret-key` or
the Redis state. `secret-key` lives in OpenBao (`authentik-secrets`); restoring
the database against a *different* `secret-key` invalidates existing sessions
and encrypted fields. Restore the secret from OpenBao first, then the database.

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

2. **Confirm you have a current machine config for each node.**

   > ⛔ **The archived configs would NOT have restored this cluster.** Verified
   > 2026-08-07 by capturing all three live configs and diffing them against
   > `params/mc-talos-prod-cp{1,2,3}.yaml` (mtime 2026-06-10). Four differences,
   > any one of which breaks a restore:
   >
   > | Field | Archived (Jun 10) | Live (measured) | Consequence of restoring with the archived file |
   > |---|---|---|---|
   > | `machine.network.interfaces[0].addresses[0]` | cp1 `10.0.0.92/24`, cp2 `.93`, cp3 `.94` (+ five `/32` VIPs) | cp1 `10.0.0.90/24`, cp2 `.91`, cp3 `.92` | cp1 would claim **live cp3's address** — an immediate collision during recovery |
   > | `cluster.controlPlane.endpoint` | `https://10.0.0.92:6443` | `https://10.0.0.90:6443` | control-plane endpoint points at the wrong member |
   > | `cluster.network.cni` | absent (⇒ Talos default CNI) | `{name: none}` | Talos would install flannel over a cluster that runs Cilium |
   > | `machine.registries.{mirrors,config}` for `registry.int.example.com` | absent | present (mirror endpoint + auth + TLS) | the private registry mirror is gone; images that only exist there stop pulling |
   > | **`cluster.secretboxEncryptionSecret`** | one value | **a different value** | **The worst one.** This is the key for encryption-at-rest of Kubernetes Secrets (SoA A.8.24: "secretbox first, identity fallback"). Restore an etcd snapshot from the live cluster onto nodes carrying the archived key and **every Secret in the restored cluster is undecryptable** — the restore "succeeds" and the platform does not come up |
   >
   > The archived set describes an earlier cluster incarnation, not this one. It
   > was never a usable restore artifact; it only looked like one.

   Fresh captures were taken 2026-08-07 as
   `params/mc-talos-prod-cp{1,2,3}-2026-08-07.yaml` (0600, gitignored; the June
   files are kept alongside, not overwritten). Each was validated with
   `talosctl validate -c <file> -m metal` → OK. Re-capture them **whenever the
   nodes are reachable and before any planned control-plane work** — they are a
   point-in-time artifact and drift silently:

   ```bash
   export TALOSCONFIG=~/.talos/config
   talosctl config info      # MUST say context infraweaver-prod — ~/.talos holds
                             # ~15 variants including config-recovered
   cd /home/runner/InfraWeaver-infra/params
   umask 077
   for p in 1:10.0.0.90 2:10.0.0.91 3:10.0.0.92; do
     talosctl -n "${p#*:}" get mc v1alpha1 -o json \
       | jq -r '.spec' > "mc-talos-prod-cp${p%%:*}-$(date -u +%F).yaml"
   done
   ```

   `jq -r '.spec'` is required: `get mc -o yaml` wraps the config in a resource
   envelope (`node:`/`metadata:`/`spec: |`) that is **not** directly appliable;
   `.spec` is the raw multi-document machine config, the same shape as the files
   already in `params/`. These contain the cluster CA key — 0600, never printed,
   never committed (`params/` carries `.public-deny` and is gitignored).

3. **Wipe every control-plane node's ephemeral state FIRST, then bootstrap once.**

   > ⚠️ **The previous version of this step had the order backwards** — it said
   > bootstrap first, then reset the others to rejoin. Checked 2026-08-07 against
   > the Talos **v1.13** disaster-recovery documentation (the running version):
   > all affected control-plane nodes are wiped *before* the recovery bootstrap,
   > and `etcd` must be in `Preparing` on all of them when it is issued.

   ```bash
   # Use a version-MATCHED client for the restore path. The ops host has
   # v1.12.7 against a v1.13.0 cluster; that skew is tolerable for `get mc` and
   # `etcd snapshot` but must not be relied on here.
   talosctl version --nodes 10.0.0.90     # confirm client and server

   # 3a. Replace any hardware-dead node from the machine configs in step 2.
   # 3b. For each control-plane node whose etcd is broken but the node runs:
   talosctl -n 10.0.0.90 reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
   talosctl -n 10.0.0.91 reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
   talosctl -n 10.0.0.92 reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL

   # 3c. Wait until etcd is `Preparing` on ALL of them — do not skip this.
   talosctl -n 10.0.0.90,10.0.0.91,10.0.0.92 services | grep -i etcd

   # 3d. Recover, ONCE, on one node (cp1 by convention here):
   talosctl -n 10.0.0.90 bootstrap --recover-from=./etcd-infraweaver-prod-<stamp>.db
   ```

   Flags confirmed present with these exact names and semantics:
   `--recover-from` (recover etcd cluster from the snapshot) and
   `--recover-skip-hash-check` (**only** when the snapshot was copied straight out
   of the etcd data directory with `talosctl cp` — a snapshot produced by
   `talosctl etcd snapshot`, which is what `etcd-snapshot.sh` writes, carries a
   valid integrity hash and must **not** use this flag).

4. **Watch the other two members rejoin.** After the bootstrap node reports
   recovery, etcd goes healthy, the Kubernetes control plane starts, the endpoint
   comes back, and the remaining members join the recovered cluster. Confirm the
   raft before touching anything else:

   ```bash
   talosctl -n 10.0.0.90,10.0.0.91,10.0.0.92 etcd status
   talosctl -n 10.0.0.90 etcd members
   ```

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

| 2026-08-07 | **etcd — §5b tabletop**, documentation walk only, zero mutations | platform admin (agent-assisted) | **NONE — no etcd snapshot exists to walk against.** Step 1 of the etcd drill template could not be performed | n/a — nothing was restored, reset or bootstrapped | **PARTIAL / BLOCKED at step 1** | Steps 2 and 3 of the template *were* executed for real: three live machine configs captured and `talosctl validate`d, and §5b compared line by line against the Talos **v1.13** disaster-recovery documentation and `talosctl bootstrap --help` | n/a | **5 findings, all corrected in §5b in this commit** — see below |

**Findings from the 2026-08-07 etcd tabletop.**

1. **The archived machine configs would not have restored this cluster.** Five
   fields diverge from live, including `cluster.secretboxEncryptionSecret` —
   restoring with the June files would have produced a cluster in which every
   Kubernetes Secret is undecryptable. Full table in §5b step 2. This is the
   single most valuable thing the tabletop found, and it was only findable by
   *comparing the artifact to reality* rather than confirming the file exists.
2. **§5b had the recovery sequence backwards.** It said bootstrap first, then
   reset the other members to rejoin. Talos v1.13 wipes **all** affected
   control-plane nodes first (`reset --graceful=false --reboot
   --system-labels-to-wipe=EPHEMERAL`), waits for `etcd` to reach `Preparing`
   everywhere, and only then issues one `bootstrap --recover-from`. Corrected.
3. **§5b never mentioned the reset flags at all** — the step that actually
   destroys state was the least specified step in the document. Added.
4. `--recover-from` and `--recover-skip-hash-check` **do still exist under those
   names** in v1.13 (verified against both the docs and `talosctl bootstrap
   --help`). The backlog's warning that flag sets change between releases was
   right to raise it; on this hop the flags are unchanged. Added the note that
   `--recover-skip-hash-check` must **not** be used with a snapshot produced by
   `talosctl etcd snapshot`.
5. **§1 claimed the machine configs were "off-box: Yes — Git".** They are not:
   `params/` is gitignored and has no history. The only copy of the artifact
   needed to rebuild the control plane lives on a VM hosted by the same Proxmox
   cluster as the nodes it would rebuild. Corrected in §1; the off-boxing itself
   is §8 item 6a and is **still open**.

**What the tabletop did NOT prove.** Everything downstream of having a snapshot:
no snapshot has been taken, none has been shipped, none has been read back, and
no `bootstrap --recover-from` has ever been executed here — not even on scratch
hardware. §5b remains **UNVERIFIED**. Re-run this tabletop end to end once §8
item 6 produces a real artifact.

**What the Longhorn row above proves, and what it does not.** It proves the whole chain —
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

### Drill — restore a PRODUCTION volume (§4a, non-destructive). NOT YET RUN

> **Status: written 2026-08-07, BLOCKED.** No backup of any production volume
> exists yet. The only backups that ever existed on this NAS were the six May-era
> orphans, and those were deleted on 2026-08-07 — `kubectl get
> backups.longhorn.io -n longhorn-system` returns **No resources found**. This
> drill becomes runnable the morning after the first unattended 01:00 run
> actually produces backups (§8 item 2a). Do not start it before then; there is
> nothing to restore from.

**Why the 2026-08-07 PASS in the table above is not enough.** Its source was a
purpose-built 1 GiB scratch volume created for the drill. It proved the
mechanism. It did not prove that a volume the platform actually cares about,
written by a real workload over months, restores correctly.

**Candidate — chosen and verified 2026-08-07:**

| | |
|---|---|
| PVC | `game-hub/gt-new-horizons-container` |
| Longhorn volume | `pvc-c611f337-d7fb-40c5-bbe0-f653566dec2b` |
| Size | `spec.size` 64424509440 (60Gi) / `status.actualSize` **2,655,735,808 B (2.66 GB)** |
| State | `detached`, PVC `Bound`, StorageClass `longhorn-game` (Retain, 1 replica) |
| Mounted by anything? | **No.** The running server pod `gt-new-horizons-*` mounts only `gt-new-horizons-container-local` — verified by enumerating every game-hub pod's PVC references |
| Why this one | real GTNH world data, genuinely production, small enough to checksum in minutes, and **not** `infraweaver-backup-datastore` or `minio-velero-data` (both excluded by policy — never drill on the thing that holds other backups) |
| Fallback | `gt-new-horizons-container-portable` → `pvc-17ef1a22-cce3-4c3b-9b17-14f59ce0b376`, 3.53 GB actual, SC `longhorn` — same shape |

> ## ⛔ THE TRAP THAT WILL EAT THIS DRILL
> `longhorn-orphan-cleaner` runs **`0 1 * * *`, unsuspended, with
> `GRACE_HOURS=2`** (all three measured 2026-08-07). It deletes detached Longhorn
> volumes that have **no PV and no PVC** and are older than the grace period. A
> freshly restored volume is *exactly* that shape between step 3 and step 4.
>
> **Therefore: run this drill in ONE sitting, in daylight, entirely outside
> 00:00–03:40 UTC, and never leave it half-done overnight.** Steps 3 and 4 go
> back to back. If you must stop, delete the restored volume and start again
> later — do not leave a nameless restored volume sitting in the cleaner's path.

**1. Fingerprint the SOURCE, read-only.** The production PVC is only ever
attached read-only and is never restored over.

```yaml
# fingerprint-src.yaml
apiVersion: v1
kind: Pod
metadata: {name: drill-fingerprint-src, namespace: game-hub}
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: docker.io/library/alpine:3.20
      command: ["sh","-c","sleep 7200"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
      volumeMounts:
        - {name: data, mountPath: /data, readOnly: true}
        - {name: scratch, mountPath: /scratch}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: gt-new-horizons-container, readOnly: true}
    - name: scratch
      emptyDir: {}
```

```bash
kubectl apply -f fingerprint-src.yaml
kubectl -n game-hub wait --for=condition=Ready pod/drill-fingerprint-src --timeout=300s
kubectl -n game-hub exec drill-fingerprint-src -- sh -c \
  'find /data -type f | wc -l;
   find /data -type f -print0 | sort -z | xargs -0 sha256sum > /scratch/MANIFEST.sha256;
   sha256sum /scratch/MANIFEST.sha256'
# RECORD BOTH: the file count N, and the fingerprint (sha256 of MANIFEST.sha256).
kubectl -n game-hub cp drill-fingerprint-src:/scratch/MANIFEST.sha256 ./drill-MANIFEST.sha256
kubectl -n game-hub delete pod drill-fingerprint-src     # the volume detaches again
```

**2. Identify the backup** (must post-date the run being validated):

```bash
kubectl get backups.longhorn.io -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,CREATED:.status.backupCreatedAt,STATE:.status.state \
  --no-headers | grep pvc-c611f337 | sort -k3 | tail -1
# WANT: STATE=Completed and a timestamp from the run you are validating.
```

**3. Restore into a NEW volume — never the original name.** Longhorn UI
(*Backup → pvc-c611f337… → Restore*, name `restore-drill-<date>`, 1 replica), or:

```yaml
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: {name: restore-drill-YYYYMMDD, namespace: longhorn-system}
spec:
  fromBackup: "nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups?backup=<BACKUP_NAME>&volume=pvc-c611f337-d7fb-40c5-bbe0-f653566dec2b"
  numberOfReplicas: 1
  frontend: blockdev
  size: "64424509440"      # MUST equal the source spec.size exactly
```

```bash
kubectl apply -f restore-volume.yaml
kubectl -n longhorn-system get volumes.longhorn.io restore-drill-YYYYMMDD -w
# until state=detached with the restore complete
```

A 60Gi restore allocates a 60Gi replica on some node even though only 2.66 GB is
real — check node disk headroom in the Longhorn UI first if unsure.

**4. PV + PVC immediately (the orphan-cleaner grace is 2h — do not pause here).**

```bash
kubectl create ns restore-drill      # it does not exist; the previous drill's was removed
```

```yaml
apiVersion: v1
kind: PersistentVolume
metadata: {name: restore-drill-YYYYMMDD}
spec:
  capacity: {storage: 60Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain   # overrides longhorn-static's Delete, on purpose:
                                          # deleting the PVC must not silently eat the volume
                                          # before step 5's verification has been recorded
  storageClassName: longhorn-static
  csi: {driver: driver.longhorn.io, fsType: ext4, volumeHandle: restore-drill-YYYYMMDD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: drill-restored, namespace: restore-drill}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-static
  volumeName: restore-drill-YYYYMMDD
  resources: {requests: {storage: 60Gi}}
```

**5. Mount READ-ONLY and verify — this is the actual test.** Same pod shape as
step 1, in namespace `restore-drill`, claim `drill-restored`, `readOnly: true`:

```bash
kubectl -n restore-drill cp ./drill-MANIFEST.sha256 drill-verify:/scratch/MANIFEST.sha256
kubectl -n restore-drill exec drill-verify -- sh -c \
  'cd / && sha256sum -c /scratch/MANIFEST.sha256 > /scratch/check.out 2>&1;
   echo "OK_LINES=$(grep -c ": OK$" /scratch/check.out) FAILED_LINES=$(grep -vc ": OK$" /scratch/check.out)";
   sha256sum /scratch/MANIFEST.sha256'
```

**PASS** = `OK_LINES` equals the source file count N, `FAILED_LINES=0`, and the
manifest fingerprint is byte-identical to step 1's. "The restore completed" is
not a pass. Reading correct data out is.

**6. Record the row in the table above.** Template — fill with real values,
leave nothing pre-filled, and record a FAIL if it fails:

```
| <YYYY-MM-DD> | Longhorn volume, §4a non-destructive — FIRST PRODUCTION VOLUME
| <operator>
| <BACKUP_NAME> of pvc-c611f337-d7fb-40c5-bbe0-f653566dec2b (game-hub/gt-new-horizons-container,
  60Gi spec / 2.66 GB actual, GTNH world data), backup created <timestamp>
| new volume restore-drill-<date> + PVC restore-drill/drill-restored, mounted read-only
| <PASS | FAIL>
| sha256sum -c MANIFEST (<N> files) → OK_LINES=<N> FAILED_LINES=<n>; fingerprint <hex>,
  identical/NOT identical to the source fingerprint recorded before the restore
| restore <mm:ss> / verify <mm:ss>
| <issues, or "none">
|
```

**7. Clean up, in this order** (reverse of creation, so nothing is orphaned into
the cleaner's path):

```bash
kubectl -n restore-drill delete pod drill-verify
kubectl -n restore-drill delete pvc drill-restored
kubectl delete pv restore-drill-YYYYMMDD
kubectl -n longhorn-system delete volumes.longhorn.io restore-drill-YYYYMMDD
kubectl delete ns restore-drill
kubectl -n longhorn-system get volumes.longhorn.io restore-drill-YYYYMMDD   # WANT: NotFound
```

Leave the drill's **backup** alone — it is a legitimate nightly backup of a live
volume and normal retention prunes it. Do **not** delete its BackupVolume.

**Traps beyond the orphan-cleaner:**

- A read-only mount of an ext4 filesystem that was not cleanly unmounted can fail
  or force a journal replay. If the step-1 pod errors on mount: re-run it once
  with `readOnly: false` on the **source**, let the journal replay, delete the
  pod, take a **fresh** backup, and only then fingerprint — otherwise the
  baseline predates the replay and the comparison is meaningless.
- The source is static (the live server writes only to `-local`), so
  fingerprint-before and fingerprint-after are equivalent *unless* that replay
  happened.
- Rollback is trivial by construction: everything the drill creates is in step
  7's list, and the production volume is only ever attached read-only.

### Drill template — etcd (tabletop first, live only in a maintenance window)

1. Fetch the newest snapshot, verify sha256, `gzip -t`, and read the `.meta`.
   Sanity-check the revision in `.meta` against expectation (≳58.7M per the
   2026-08-07 measurement in `snapshot-README.md`) — a revision far behind that
   means you grabbed the wrong file. **First run of this step: 2026-08-07,
   BLOCKED — no snapshot exists.**
2. Confirm a **current** machine config exists for each of cp1/cp2/cp3 — and
   *diff it against the live one*, do not merely confirm the file is present.
   Pay specific attention to `cluster.secretboxEncryptionSecret`,
   `cluster.controlPlane.endpoint`, `cluster.network.cni` and the per-node
   addresses; those are the four that were wrong on 2026-06-10's set.
3. Walk §5b aloud against the Talos docs for the *running* version
   (`talosctl version --nodes 10.0.0.90`, then the disaster-recovery page for
   that exact minor). Record every step whose flags or ordering differ and
   correct this document in the same commit.
4. Confirm the restore client is version-matched to the server before a live
   attempt; the ops host currently carries v1.12.7 against a v1.13.0 cluster.
5. Only attempt a live restore on a scratch cluster or during a declared window
   with a full Longhorn backup completed first.
6. Add a row to the table above with the real result — including "blocked at
   step N", which is a legitimate and useful outcome.

---

## 8. Follow-ups (not done in this change)

### Velero — recommendation: EXCLUDE (b). Decision drafted 2026-08-07, **not yet ratified**

Velero was **not** re-enabled in the WP2 change, deliberately: one backup change
at a time. Longhorn volume backups had never once worked, and mixing a second,
untested backup system into the same change would make it impossible to tell
which one produced any given result.

**The recommendation is branch (b) — formally exclude Velero and delete
`minio-velero`.** The evidence, measured 2026-08-07 and worth keeping because it
is not what the design documents imply:

| Measurement | Command | Result |
|---|---|---|
| Is `minio-velero` GitOps-managed? | `kubectl get applications -n argocd` (63 apps) | **No Application owns it** |
| …tracking annotation on its objects? | `kubectl get deploy/svc/pvc/job -n velero -o jsonpath='{…argocd.argoproj.io/tracking-id}'` | **empty on all four** — it was applied by hand 54 days ago and nothing reconciles it |
| …anything tracked in that namespace? | same, on `ns/velero` | only the Namespace, by `core-psa-manifests`, and only for its PSA labels |
| What does it store, and where? | `kubectl get pvc -n velero` | `minio-velero-data` 20Gi `longhorn-retain`, Longhorn volume `pvc-0aac11c4…`, **579,006,464 B actual**, `attached` — one of only two attached Longhorn volumes |
| Does it serve any backup? | bucket contents / 54 days of history | **zero** — Velero itself has never been deployed |

**Why re-enabling (branch a) would not buy coverage as designed.** The design
stores Velero's data in MinIO **on a Longhorn volume inside the same cluster**.
Cluster-loss recovery would mean first restoring the MinIO volume from the NAS
via Longhorn, then Velero from MinIO — a two-hop chain whose first hop already
requires the thing Velero exists to protect, and which has never been tested. As
built, that is a second untested backup system, not additional coverage.

**What Velero would uniquely cover, and what replaces it.** WordPress (15
Deployments) and the game-hub workloads carry **no ArgoCD tracking-id** — they
are console-provisioned API objects that exist only in etcd. Git does not hold
them. The compensating controls named in the SoA are therefore:

1. Git as the source of truth for the 63 ArgoCD Applications.
2. **etcd snapshots** for the console-provisioned objects — see §5 and §8 items
   5–7. **This is the hard gate: it does not exist yet.**
3. The WordPress fleet datastore (separately verified 2026-07-30) for site content.
4. Longhorn NAS backups for volume data (§1).
5. The console's provisioning path, which can re-create site objects.

> ⛔ **The SoA exclusion sentence is written but marked PENDING and must stay
> pending.** Compensating control (2) is the load-bearing one and *no etcd
> snapshot has ever been taken* (§1 callout). Ratify the exclusion — and only
> then drop the "PENDING" marker in
> `docs/compliance/statement-of-applicability.md` A.8.13 / A.5.30 — on the date
> the first etcd snapshot is verified end-to-end (§8 item 6's ROUNDTRIP_OK).
> Excluding Velero while citing a control that has never run would reproduce
> exactly the failure this runbook was written to stop.

#### OPERATOR STEP — tear down `minio-velero` (live `kubectl`, not GitOps)

**Not executed. Nothing in git deploys or removes these objects** — they were
hand-applied, so deleting them is a live action an operator takes deliberately.
Sequence it **after** the first unattended Longhorn run has been verified (§8
item 2a): do not shrink the volume set on the same night that run is being
judged.

```bash
export KUBECONFIG=~/.kube/config-platform-productie

# 0. 30 seconds of diligence: is anything actually using the S3 endpoint?
kubectl -n velero logs deploy/minio-velero --since=24h | tail -50
# WANT: only startup/health lines. Any real S3 API traffic ⇒ STOP and find the
# caller before deleting; nothing documented uses it.

# 1. Re-confirm the namespace holds only MinIO, and note the ExternalSecret.
kubectl get all,pvc,secrets,externalsecrets -n velero

# 2. Delete the hand-applied workload (the manifest at
#    kubernetes/platform/minio-velero/manifests/minio.yaml is the exact list).
kubectl delete -n velero deployment minio-velero
kubectl delete -n velero service minio-velero
kubectl delete -n velero job minio-create-bucket
kubectl delete -n velero rolebinding minio-velero-pvc-reader-system-nodes
kubectl delete -n velero role minio-velero-pvc-reader
kubectl delete -n traefik ingressroute minio-velero-console
kubectl delete -n velero externalsecret minio-velero-credentials
kubectl delete -n velero pvc minio-velero-data

# 3. longhorn-retain ⇒ the PV goes Released, NOT deleted. Delete it explicitly.
kubectl get pv pvc-0aac11c4-9ef9-4e5d-9c8e-f1c215ddadec        # STATUS Released
kubectl delete pv pvc-0aac11c4-9ef9-4e5d-9c8e-f1c215ddadec

# 4. THIS is the actual reclamation — the 20Gi Longhorn volume (~552 MiB used).
kubectl -n longhorn-system delete volumes.longhorn.io pvc-0aac11c4-9ef9-4e5d-9c8e-f1c215ddadec

# 5. Namespace last (nothing else lives in it).
kubectl delete ns velero

# 6. NAS hygiene. Any night between the first working Longhorn run and this
#    teardown will have created backups of this volume; its BackupVolume is now
#    an orphan of exactly the kind §8 item 2b was about. Delete the CR and let
#    the controller clean the store — never strip finalizers.
kubectl -n longhorn-system get backupvolumes.longhorn.io | grep pvc-0aac11c4 || echo "none — nothing to clean"
kubectl -n longhorn-system delete backupvolumes.longhorn.io pvc-0aac11c4-9ef9-4e5d-9c8e-f1c215ddadec
```

**Verification that proves the teardown worked** (not that the commands ran):

```bash
kubectl get ns velero                                              # WANT: NotFound
kubectl -n longhorn-system get volumes.longhorn.io | wc -l         # WANT: one fewer than before
kubectl get externalsecrets -A --no-headers | wc -l                # WANT: 27  (see below)
sleep 900 && kubectl -n longhorn-system get backupvolumes.longhorn.io | grep pvc-0aac11c4
# WANT: nothing after 3 poll cycles ⇒ the NAS directory is really gone, not just the CR
```

**Expected baseline changes — record these so the next handoff does not raise a
false alarm:**

- **ExternalSecret count 28 → 27.** Measured 2026-08-07: `minio-velero-credentials`
  *is* ESO-managed (`ClusterSecretStore/openbao`, `SecretSynced`/`Ready=True`),
  even though nothing else about MinIO is GitOps-managed. Note that the manifest
  file also declares a second ExternalSecret, `velero-s3-credentials`, which
  **is not live** — it was never applied. Only one disappears.
- Longhorn volume count drops by one.
- `secret/platform/minio-velero` in OpenBao becomes unreferenced. Leave it; it is
  the credential branch (a) would need. Delete it only if branch (a) is
  permanently ruled out.

**Rollback.** `kubectl apply -f kubernetes/platform/minio-velero/manifests/minio.yaml`
recreates namespace, PVC, Deployment, Service, ExternalSecrets and the bucket
Job. It comes back with a **new empty bucket** — which costs nothing, because
MinIO never held any Velero data. If branch (a) is chosen later, the two
`.disabled` Application files still exist and it should be enabled *under ArgoCD
management*, not hand-applied again.

**Deliberately left in git as the audit trail:** `bootstrap/app-velero.yaml.disabled`,
`bootstrap/app-minio-velero.yaml.disabled`, and
`kubernetes/platform/minio-velero/manifests/`. They deploy nothing while
disabled. The `velero:` entry in `kubernetes/core/psa/namespace-labels.yaml`
must be removed **only after** step 5 above, in its own commit — it describes a
namespace that still exists until then. (`core-psa-manifests` runs
`prune: false`, so removing it early would not delete the namespace; it would
just leave the file lying about what it covers.)

### Other open items

| # | Item | Why it matters |
|---|---|---|
| ~~1~~ | ~~**Run the first restore drill** (§7)~~ — **DONE 2026-08-07**, PASS, but on a scratch volume | Superseded by item 1a. §4b/§4c/§5 remain unproven |
| 1a | **Run the PRODUCTION restore drill** — procedure written 2026-08-07, candidate chosen and verified, **not run** | Blocked until a production volume actually has a backup, i.e. until item 2a is green. Candidate: `game-hub/gt-new-horizons-container` → `pvc-c611f337…` (60Gi spec / 2.66 GB actual, detached, unmounted). **Must be completed in one daylight sitting** — `longhorn-orphan-cleaner` (01:00, `GRACE_HOURS=2`, unsuspended) deletes a restored volume that is left without a PV/PVC. Full steps and record-row template in §7 |
| ~~2~~ | ~~Verify `available=true` and ≥1 `backups.longhorn.io`~~ — **DONE 2026-08-07** | `available=true` reached only after the `airgap-baseline` egress fix (`71371b3`); a backup was created, restored, verified and cleaned up |
| 2a | **Confirm the 01:00 recurring run actually produces backups** | All 21 volumes carry a `recurring-job` group label and the jobs include group `default`, so the enrolment gap is closed *on paper*. The first unattended nightly run is the proof. Check the morning after `71371b3` landed. |
| 2b | **7 orphaned backups (~1.4 GB) sit on the NAS from a previous cluster** | Once the target became readable, 7 `backups.longhorn.io` from 2026-05-08…05-18 appeared, for volumes (`pvc-ebc6736d…`, `pvc-3b784d59…`, `pvc-55cdbec9…`) that no longer exist. No retention job will ever prune them — recurring-job retention only prunes volumes it manages. Decide: delete, or keep and count them in the capacity plan (item 8). |
| 3 | `TRUENAS_HOST=10.1.0.5` in the CMP substitutions is wrong (no NFS/SMB there; the NAS is `10.1.0.135`) | **Scoped 2026-08-07, still open.** Nothing is broken today — every consumer was individually worked around with a resolved literal (Longhorn here; console via its prod overlay, confirmed in the live pod env; OpenBao `nas/providers` already `.135`). The only CMP-rendered `${TRUENAS_HOST}` is the substitutions ConfigMap **itself**, a self-perpetuating loop. Correction is ordered and operator-gated: `SECURITY-REMEDIATION-RUNBOOK.md` §P2.4. The LDAP outpost consumer is gone (deleted 2026-08-07). **The operator's offline `.env` must be fixed too, or a DR rebuild re-poisons everything.** |
| ~~4~~ | ~~Authentik Postgres/Redis on `local-path` have **no backup**~~ — **ADDRESSED IN GIT 2026-08-07**, not yet proven live | `platform/authentik/manifests/pg-backup.yaml` adds a 00:15 `pg_dump` onto a Longhorn PVC that the 01:00 job ships to the NAS. **Not closed until** (a) the CronJob object exists after sync, (b) one dump has been restored per §4d, and (c) a Backup CR for the dump PVC's Longhorn volume exists. Redis: accepted loss, decided 2026-08-07 |
| 4a | **Availability of the SSO database is still not addressed** | The dump fixes durability, not uptime: cp2's disk dying still means redeploy-and-restore (hours). Optional upgrade = migrate `data-authentik-postgresql-0` to `longhorn-retain` in a declared maintenance window with the STS recreated (`--cascade=orphan` or `existingClaim`) and a fresh dump taken first. **Operator-scheduled; do not bundle it with a backup change.** Removing the inert `recurring-job-group` annotations rides along in that same window |
| 5 | **No alert on etcd-snapshot freshness** — still open, and **owned by the alerting workstream, not this one** (`prometheus-rules.yaml` is edited there; deliberately untouched here to avoid a merge conflict) | The `etcd.health` rule group holds only `EtcdHighCommitDuration` and `EtcdMemberDown`. There is no counterpart to `LonghornBackupVerifierMissedSuccess`. Note the same `absent()` caveat: a never-succeeded CronJob may emit no `kube_cronjob_status_last_successful_time` series at all, in which case a bare `time() - metric > N` expression **cannot fire**. Any new rule needs `... or absent(...)`. The intended shape is an in-cluster verifier reading a `configmap/etcd-snapshot-status` heartbeat that the ops-host cron pushes on success — the in-cluster half deliberately holds no Talos credentials |
| 6 | **Install the etcd snapshot cron and prove one snapshot end to end** — the whole of §1's etcd row depends on this | Newly unblocked in git: `ansible/inventory.ini` in `InfraWeaver-base` now defines the `etcd_snapshot_hosts` group the playbook targets (it was defined nowhere). **Remaining blockers, measured 2026-08-07:** (a) `ansible-playbook` is not installed on the ops host; (b) item 7's TrueNAS directory and credential do not exist; (c) `/` is 95% full with 2.9 GB free, against the script's own `MIN_FREE_MB=2048` floor. Passwordless `sudo` **does** work, so this is not blocked on an operator password. Success criterion is the round-trip, not exit 0: take the snapshot, then `smbclient … get` it back off the NAS and compare `sha256sum` — `ROUNDTRIP_OK` or it did not happen |
| ~~6a~~ | ~~Talos machine configs last refreshed 2026-06-10~~ — **REFRESHED 2026-08-07**, and the refresh found a real defect | The June set diverged from live in five fields, including `cluster.secretboxEncryptionSecret` — a restore with it would have left every Kubernetes Secret undecryptable. See the §5b step 2 table. Fresh captures are `params/mc-talos-prod-cp{1,2,3}-2026-08-07.yaml`, `talosctl validate` OK |
| 6b | **Off-box the machine configs — STILL OPEN and now known to be worse than recorded** | §1 used to claim they were backed up "Yes — Git". They are not: `params/` is gitignored (`.gitignore:55`) with no history. The only copy of the artifact required to rebuild the control plane sits on this VM's disk, and this VM is a guest on the same Proxmox cluster as the nodes. They carry the Talos CA key, so the fix is an encrypted off-box copy (SOPS/age, or the TrueNAS share alongside the etcd snapshots) — **not** a git commit. Operator decision on custody |
| 7 | **OPERATOR: provision the TrueNAS `etcd-snapshots` SMB directory + dedicated credential** — see the checklist below | Hard prerequisite for item 6; the playbook's `transport: smb` cannot be configured without it |
| ~~8~~ | ~~Capacity: NAS free space vs 19 volumes × (7 daily + 4 weekly)~~ — **MEASURED 2026-08-07, ample** | See the capacity table below. 3.44 TiB free against a ~100 GB planning envelope — 35× headroom, no action needed. The measurement also independently confirmed the orphan deletion: the store is **empty**, so the 1.45 GB really left the NAS rather than just losing its CRs |

### Capacity — measured, not estimated

The backup target's free space is readable **read-only** from inside the ACL
without deploying anything: `longhorn-manager` already holds the NFS mount.

```bash
export KUBECONFIG=~/.kube/config-platform-productie
P=$(kubectl -n longhorn-system get pods -l app=longhorn-manager -o name | head -1)
kubectl -n longhorn-system exec "$P" -c longhorn-manager -- df -P -h -t nfs4
```

(The export is ACL'd to `10.0.0.0/24`. The ops host has a `10.0.0.108`
address, but its route to `10.1.0.135` sources from `10.1.0.108`, so it is
outside the ACL — hence measuring from a pod on a cluster node.)

Result, 2026-08-07:

| | Value |
|---|---|
| `10.1.0.135:/mnt/pool/k8s-longhorn-backups` size | 3,695,139,840 KiB ≈ **3.44 TiB** |
| Used | **0** |
| Available | **3.44 TiB** |
| `…/backupstore/` contents | **empty** — the P1.3 orphan deletion did reclaim the bytes |

| Component | Basis | Estimate |
|---|---|---|
| Longhorn first full backup | Σ `status.actualSize` over the 19 live volumes, measured: 51,462,991,872 B | **51.5 GB** |
| — largest contributors | `game-hub/ark-smoke-server` 24.0 GB, `game-hub/palworld-container` 9.6 GB, `infraweaver-console/infraweaver-backup-datastore` 4.6 GB | |
| Longhorn steady state | full + nightly churn × 7 retained; churn concentrated in the WP datastore, most volumes detached and static, per-volume dedup | ~60–90 GB envelope |
| Weekly retain 4 | shares blocks with the dailies in the same store | small increment |
| Authentik pg dumps | 20th volume, 5 Gi provisioned, single-digit MB of real data | negligible |
| etcd snapshots | ~314 MB DB → `gzip -6`, × 30 remote retained | ≤ ~3 GB |
| **Planning envelope** | | **~100 GB** |
| **Headroom** | 3.44 TiB ÷ ~100 GB | **≈ 35×** |

Note the provisioned-vs-actual gap: `Σ spec.size` over the same 19 volumes is
**397 GB**. Longhorn backs up allocated blocks, not provisioned capacity, so 51.5
GB is the number that crosses the wire — but a *restore* of everything would need
the provisioned figure available on node disks, which is a different (and
tighter) constraint than NAS space.

### OPERATOR CHECKLIST — TrueNAS `etcd-snapshots` share (§8 item 7)

Ten minutes in the TrueNAS UI at `10.1.0.135`. **Not attempted from here** — it
needs NAS administrative access and creates a credential whose custody is an
operator decision. Nothing downstream (item 6, and therefore the SoA's Velero
exclusion) can start until this is done, so schedule it first.

- [ ] Create directory `etcd-snapshots` inside the existing `infraweaver` SMB
      share. Confirm the exact share name first — the script builds
      `//10.1.0.135/infraweaver` + `SMB_PATH`, and a wrong share name fails at
      `smbclient put`, i.e. *after* the snapshot has been taken.
- [ ] Create a dedicated user `svc-etcd-snapshot`. **Not** an existing account
      and **not** the Longhorn NFS identity.
- [ ] Grant it write access to `etcd-snapshots` **only** — not the rest of the
      `infraweaver` share, not `/mnt/pool/k8s-longhorn-backups`, not the media
      datasets. This credential ends up in a 0600 file on the ops host; scope it
      as if that host is compromised.
- [ ] Decide retention/quota on the NAS side. The script keeps
      `REMOTE_RETAIN=30`; at ≤100 MB per gzipped snapshot that is ≤3 GB, which
      is noise against 3.44 TiB — a quota is optional, but decide deliberately
      rather than by default.
- [ ] Hand the credential over out of band. It is passed to the playbook as
      `-e etcd_snapshot_smb_password=…` and written only to
      `/etc/infraweaver/etcd-snapshot-smb.auth` (0600, `no_log: true`). **Never
      in git, never in a commit message, never in a runbook.**
- [ ] Verify from the ops host before running the playbook:
      `smbclient //10.1.0.135/infraweaver -U svc-etcd-snapshot -c 'cd etcd-snapshots; ls'`
- [ ] Alternative to consider and reject or accept explicitly: the TrueNAS API
      key already at OpenBao `secret/platform/nas/providers` could provision this
      programmatically. That key is far broader than `svc-etcd-snapshot` needs to
      be, so the default assumption is the UI path above.

### Where each remaining piece of this workstream lives

| Piece | State | Owner |
|---|---|---|
| Authentik `pg_dump` CronJob | in git, unmerged | merge → ArgoCD `apps-authentik-manifests`; then §4d must be run once |
| Authentik Postgres → Longhorn migration | documented, **not done** | operator, declared maintenance window (SSO outage) |
| `minio-velero` teardown | commands written, **not executed** | operator, live `kubectl`, after the first verified Longhorn run |
| Velero exclusion in the SoA | drafted, **PENDING** | unblocks on item 6's `ROUNDTRIP_OK` |
| `ansible/inventory.ini` | written in `InfraWeaver-base`, **uncommitted there** | operator commits it in that repo (this workstream's branch is in `InfraWeaver-infra`) |
| Fresh machine configs | captured, validated, on disk at `params/` | off-boxing them is item 6b |
| etcd cron install + first snapshot | blocked on item 7 | operator, then agent |
| Production restore drill | procedure written (§7), **not run** | blocked until a production volume has a backup |
| etcd snapshot alert | **pre-wired**, awaiting the CronJob | `etcd-snapshot-verifier` is already reserved in the backup-chain selectors of `kubernetes/monitoring/alerts/cronjob-health.yaml`, so creating a CronJob by exactly that name arms three critical alerts with no rule change. Full verifier design is in `kubernetes/core/etcd-maintenance/snapshot-README.md`. Ship the one `absent()` line in the same commit as the CronJob |
