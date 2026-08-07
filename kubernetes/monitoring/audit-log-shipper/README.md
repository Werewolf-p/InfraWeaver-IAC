# audit-log-shipper

Ships the Kubernetes **API server audit log** from every control-plane node into
Loki. Closes **GAP-H5** (SOC 2 CC7.2, ISO 27001:2022 A.8.15) — the technical half.
The written retention policy is WP7's `docs/compliance/logging-and-retention-policy.md`.

## The problem it solves

`kube-apiserver` is started with `--audit-log-path=/var/log/audit/kube/kube-apiserver.log`
and nothing collected it. The flags read like 30 days of history:

```
--audit-log-maxage=30  --audit-log-maxbackup=10  --audit-log-maxsize=100
```

but `maxbackup=10 × maxsize=100MB` caps the on-node history at ~1.1 GB, and at the
**measured** write rate that is hours, not days:

| Node | measured audit write rate | on-node history at 11 × 100 MB |
|---|---|---|
| talos-prod-cp1 (10.0.0.90) | 0.69 GB/day (28.8 MB/h) | ~38 h |
| talos-prod-cp2 (10.0.0.91) | 3.08 GB/day (128 MB/h) | **~8 h** |
| talos-prod-cp3 (10.0.0.92) | 1.29 GB/day (53.8 MB/h) | ~20 h |

Measured 2026-08-07 from the rotation timestamps in `/var/log/audit/kube` on each
node. Before this shipper, "who deleted that?" was unanswerable after ~8 hours.

## Verified on-disk facts (talosctl, read-only, 2026-08-07)

```
/var/log/audit/kube            drwx------  65534:65534
/var/log/audit/kube/kube-apiserver.log             -rw------- 65534:65534   (active)
/var/log/audit/kube/kube-apiserver-<ts>.log        -rw------- 65534:65534   (10 rotated)
```

* Directory `0700`, files `0600`, owner uid 65534 → **the reader must be uid 0**.
* SELinux label `system_u:object_r:kube_log_t:s0`, but Talos v1.13.0 runs SELinux
  **permissive** (`/sys/fs/selinux/enforce == 0`), so the label does not block the
  read today. If SELinux is ever set to enforcing, re-verify this DaemonSet first.
* The `monitoring` namespace is `pod-security.kubernetes.io/enforce=privileged`,
  so the hostPath mount is admitted.
* Audit policy level is `Metadata` for everything — request/response bodies are
  never written, so no secret values transit this pipeline.

## What is shipped, and what is dropped

The pipeline drops ~91.6% of raw bytes before the push. Both filters were measured
against live data, and the second was verified by running the **rendered** config
through `promtail 3.5.1 -dry-run`:

| Stage | Dropped | Rationale |
|---|---|---|
| `stage != ResponseComplete` | 46.9% of bytes | `RequestReceived` / `ResponseStarted` duplicate the request with no outcome |
| `get\|list\|watch` by a `system:` identity, non-sensitive resource, non-denied | 43.5% of bytes | controller reconcile traffic; 52% of the total came from `argocd-notifications-controller` re-reading `appprojects` alone |

**Always retained:** every mutation; every read of `secrets`, `serviceaccounts`,
`roles`/`rolebindings`/`clusterroles`/`clusterrolebindings`,
`certificatesigningrequests`, `tokenreviews`, webhook configurations; every
`exec`/`attach`/`portforward`/`token`/`proxy` subresource; every `401`/`403`;
and everything done by a non-`system:` (human or external) identity.

The filter **fails open**: label matchers are anchored and an absent label is the
empty string, so any event the JSON stage cannot parse fails the `user=~"system:.*"`
matcher and is kept. It can over-collect; it cannot silently lose evidence.

Result: **~425 MB/day** shipped fleet-wide instead of ~5.06 GB/day.

## Querying it

```logql
{job="kube-audit"}                                   # everything
{job="kube-audit", verb="delete"}                    # every deletion, any node
{job="kube-audit"} | json | objectRef_resource="secrets"
{job="kube-audit"} | json | responseStatus_code=`403`
{job="kube-audit"} | json | user_username!~"system:.*"   # human activity
```

Stream labels are deliberately only `job`, `node`, `verb`, `filename`. `user` and
`resource` are extracted for filtering and then dropped — `user` alone would be
unbounded cardinality. The full JSON line is preserved, so every field stays
queryable with `| json`.

## Deliberate design choices

* **Only the active file is tailed** (`kube-apiserver.log`, not `kube-apiserver*.log`).
  Globbing the rotated files would backfill ~1 GB per node into one stream out of
  order, which Loki rejects beyond `max_chunk_age/2`, and there are only a few
  hours of on-node history to gain. Rotation is rename+create, which promtail follows.
* **Separate DaemonSet from `loki-promtail`.** Independent lifecycle, its own
  resource envelope, and its own absence alert; a crash in the pod-log shipper
  cannot take the audit trail with it.
* **Its own positions hostPath** (`/run/promtail-audit`). `loki-promtail` already
  owns `/run/promtail/positions.yaml`; two writers would corrupt each other.
* **No RBAC, no ServiceAccount token.** Targets are static files, so Kubernetes
  service discovery is not used.

## Known follow-ups

* The `grafana/promtail` chart is **deprecated** upstream (`helm template` warns);
  promtail itself is EOL. Migration to `grafana/alloy` is a follow-up — deliberately
  not bundled with the change that first makes the audit trail exist.
* `platform.yaml` `groups.core-monitoring.apps` is a human-facing registry and does
  not yet list `audit-log-shipper`. Discovery is by directory glob in
  `appset-core-monitoring.yaml`, so the app deploys regardless; the registry entry
  is cosmetic drift owned outside this work package.
