# Logging and Retention Policy

| | |
|---|---|
| **Document ID** | ISMS-POL-003 |
| **Version** | 1.0 |
| **Status** | Active — target periods in §3 are **not yet implemented**; see §2 for current reality |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | On WP8 completion, then 2027-02-07 |
| **Controls** | ISO/IEC 27001:2022 A.5.28, A.5.33, A.5.34, A.8.10, A.8.15, A.8.16, A.8.17 · SOC 2 CC7.2, CC7.3, P4 |

---

## 1. Purpose

Define what is logged, for how long it is kept, and what is deleted when. This
document supplies the *policy* text for GAP-H5; **WP8 supplies the
implementation**. Where the two disagree today, §2 states the truth.

## 2. Current state versus policy — the gap, stated plainly

| Signal | Policy target (§3) | **Actual, 2026-08-07** | Evidence |
|---|---|---|---|
| Prometheus metrics | 15 days | **3 days / 8 GB cap** | `kubernetes/monitoring/kube-prometheus-stack/values.yaml:99-100` |
| Loki application logs | 90 days | **Undefined in practice** — `table_manager.retention_period: 168h` with `retention_deletes_enabled: false`, and a second `retention_period: 0s` elsewhere. Deletes are disabled, so nothing is actively removed, but nothing guarantees availability either | `kubernetes/monitoring/loki/values.yaml:19` |
| Kubernetes API audit log | 90 days, shipped off-node | **30 days, on-node only.** `--audit-log-path=/var/log/audit/kube/kube-apiserver.log`, maxage=30, maxbackup=10, maxsize=100, policy = Metadata for everything. **Not shipped to Loki** | `talosctl -n 10.0.0.90 read /system/config/kubernetes/kube-apiserver/auditpolicy.yaml` |
| OpenBao secret-access audit | 1 year | **Does not exist.** No audit device is configured | `kubernetes/core/openbao/manifests/` contains only `networkpolicy.yaml` and `rbac.yaml` |
| Runtime/host security events | 90 days | **Do not exist.** Falco is disabled | `kubectl get pods -n falco` → no resources |
| Git history | Indefinite | **Met** | `git log` |
| Access grant provenance | Indefinite | **Met** — `grantedBy`/`grantedAt` on every assignment | `users.yaml` |

**The consequence, stated so nobody has to infer it:** a SOC 2 Type II
observation window is typically 3–12 months. With 3 days of metrics, undefined
log retention, and audit logs that die with their node, **this platform cannot
currently evidence the continuous operation of its monitoring controls over an
audit period.** This is RISK-12. It is not a documentation problem; the document
is what you are reading.

## 3. Retention schedule (target)

| Category | Contents | Retention | Rationale |
|---|---|---|---|
| **Security audit logs** | Kubernetes API server audit, OpenBao audit device, authentication events | **1 year** | Investigation of a compromise discovered late needs a long horizon. This is the one category where short retention is genuinely dangerous |
| **Application and platform logs** | Loki-collected container logs | **90 days** | Covers a quarterly review cycle and most incident investigations |
| **Metrics** | Prometheus TSDB | **15 days** raw, subject to the disk budget | Enough for capacity and trend analysis; longer needs downsampling this platform does not have |
| **Alert history** | Alertmanager notification log | 90 days | Matches the log window |
| **Access records** | `users.yaml` grants, Authentik user and group state | **Indefinite** (in git) | Provenance must outlive the grant |
| **Access review records** | `access-review-*.md` | **Indefinite** | Audit evidence |
| **Incident records** | `docs/compliance/incidents/INC-*.md`, post-mortems | **Indefinite** | A.5.27, A.5.28 |
| **Change records** | Git history, PR discussions, ArgoCD sync history | **Indefinite** (git); ArgoCD keeps a bounded revision history | Change evidence for A.8.32 / CC8.1 |
| **Backups** | Longhorn volume backups | **30 days** rolling, once functional | Balances recovery depth against TrueNAS capacity |
| **etcd snapshots** | Cluster state | **30 days** | Same |
| **Personal data** | See §6 | Per §6 | GDPR data minimisation |

**Budget constraint, acknowledged.** Raising Prometheus from 3 to 15 days is
roughly a 5× TSDB growth on a Longhorn PVC, and Loki's 90-day target must be
sized against available disk. WP8 must measure free space *before* merging and
record the numbers in the PR. A retention target that fills the disk converts a
logging gap into an availability incident.

## 4. What is logged

| Source | Content | Destination |
|---|---|---|
| Kubernetes API server | All requests at **Metadata** level (who, what, when — not payloads) | On-node file; **must** be shipped to Loki (WP8) |
| Container stdout/stderr | Application and platform logs, all namespaces | Loki |
| Traefik | HTTP access logs including source IP and path | Loki |
| Authentik | Authentication events, group changes, flow execution | Its own database and stdout → Loki |
| ArgoCD | Sync and deployment events | Loki + ArgoCD's own history |
| Kyverno | PolicyReports (admission decisions) | Kubernetes API objects, not Loki |
| Prometheus | Metrics from every namespace | Prometheus TSDB |
| Cilium Hubble | Network flows | Hubble (in-memory, not retained) |
| **OpenBao** | Secret access — **not logged today** | Must become a file/stdout audit device (WP10) |
| **Host / runtime** | **Not logged** — Falco disabled | Would be Loki (WP8) |

**Audit policy detail.** The API server audit policy is a single Metadata rule
covering everything, with no `omitStages` and no elevated detail for RBAC or
Secret writes. That is a deliberate accepted position (GAP-L1 / RISK-16) — it
captures who did what to which object, which is the question that actually gets
asked, without the volume and secret-leakage risk of RequestResponse logging.

## 5. Prohibited log content

Logs must not contain: secret values, tokens, passwords, private keys, session
cookies, or full request bodies from authenticated sessions.

The API server audit policy's Metadata level enforces the last of these
structurally. For application logs the control is code review
(`secure-development-policy.md`) — there is no automated log-content scanner.

**Known live violation of the spirit of this rule:** `game-hub/gt-new-horizons`
carries `RCON_PASSWORD` as a literal pod environment value, so it appears in
`kubectl get pod -o yaml` output and in anything that captures pod specs
(RISK-13, WP10).

## 6. Personal data retention (GDPR)

| Data | Where | Retention | Deletion trigger |
|---|---|---|---|
| Account identity — username, email, group membership | Authentik, `users.yaml` | Life of the account + provenance record | Account closure. Authentik accounts are **deactivated, not deleted**, so identity persists in the audit trail; the register entry is removed |
| Access grants | `users.yaml` (git) | **Indefinite** — git history is not rewritten | Never. Justification: integrity of the change record outweighs erasure of an administrative record. A data-subject erasure request would be met by removing the current entry and deactivating the account, not by rewriting history |
| User content — WordPress, Nextcloud, Jellyfin, NAS shares | Self-hosted PVCs and NAS | Until the user or the operator deletes it | User request or account closure |
| Authentication events | Loki / Authentik | Per §3 (90 days / 1 year target) | Automatic expiry |
| Email addresses in transactional mail | SMTP provider | Provider's own retention — **not controlled by this platform** | See `vendor-register.md` §3 |

**Data subject rights.** Five users, all known personally to the operator. A
request is handled by direct action: export or delete the user's PVC content,
deactivate the Authentik account, remove the `users.yaml` entry. There is no
automated DSAR pipeline and none is warranted at this scale — but the git-history
exception above is a real, stated limitation, not an oversight.

**Deletion evidence.** WordPress site deletion has previously caused
**collateral damage twice**: it once removed the domain's MX and SPF records
(type-blind delete against an apex host), and it once orphaned that site's
backups permanently because the retention sweep prunes by the *current* site
list. Any deletion touching a WordPress site must therefore: protect the intended
survivor's backups *before* deleting siblings, and verify DNS records of types
other than the one being removed. These are recorded here because deletion is a
retention operation and these are the platform's actual failure modes.

## 7. Log integrity and access

- Logs in Loki are readable by anyone with Grafana access (behind Authentik
  forward-auth). There is no separate log-access role.
- Nothing is write-once or tamper-evident. An attacker with cluster-admin can
  alter or delete logs — which is precisely why the standing cluster-admin
  credential (RISK-09) is scored Critical.
- **The on-node audit log shares a failure domain with the node it records.**
  Shipping it off-node (WP8) is as much an integrity control as a retention one.
- Time synchronisation (A.8.17) is handled by Talos NTP on all nodes; without it
  cross-source correlation is worthless. Verify with
  `talosctl -n 10.0.0.90 time`.

## 8. Monitoring the monitoring

Retention is only useful if collection is running. CronJob-miss conditions are
covered cluster-wide by `kubernetes/monitoring/alerts/cronjob-health.yaml`
(`CronJobMissedSuccess`, `CronJobNeverSucceeded`, `CronJobLastRunFailed`,
`CronJobSuspended`, `StandaloneJobFailed`, and the critical-severity
`BackupCronJobMissedSuccess` for the backup chain), plus
`ConsoleAutomationCronJobMissedSuccess` in the `platform-alerts` PrometheusRule
for the `infraweaver-console` namespace, which keeps its own tighter cadence
thresholds and is excluded from the generic rules so nothing pages twice.
The allowlist-based `ClusterAutomationCronJobMissedSuccess` and the
never-firing `LonghornBackupVerifierMissedSuccess` were removed on 2026-08-07.

**Three known weaknesses in the delivery path**, all WP8. Verified against the
live Alertmanager configuration on 2026-08-07:

```bash
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

1. **Every alert reaches exactly one vendor.** The routing tree sends
   `severity=critical` to receiver `all` and `severity=warning` to receiver
   `discord`; both are webhook receivers pointing at the same Discord forwarder.
   One vendor outage means silent monitoring.
2. **The Watchdog is routed to `/dev/null`.** The first route in the tree is
   `alertname = "Watchdog" → receiver: "null"` with `continue: false`. The
   dead-man's-switch alert that Prometheus emits continuously *by design* to
   prove the pipeline is alive is discarded, so **an outage of the monitoring
   stack is invisible by construction.** Three further `null` routes suppress
   `InfoInhibitor`, the `Kube*Down` family, and `TargetDown` for
   kube-proxy/controller-manager/scheduler — expected on Talos, where those
   components are managed differently, but they should be documented
   suppressions rather than silent ones.
3. **The email fallback is defined but unroutable and misconfigured.** An
   `email-admin` receiver exists with `to: admin@${BASE_DOMAIN}` — but no route
   references it, *and* the `${BASE_DOMAIN}` placeholder is **unsubstituted in
   the live configuration**, along with `smtp_from: alertmanager@${BASE_DOMAIN}`.
   Even if a route were added today, mail would be addressed to a literal
   `${BASE_DOMAIN}` and fail. WP8 must fix the substitution, not just the
   routing.

### Update 2026-08-07 — measured, and partially remediated

Weaknesses 1 and 2 were addressed by the earlier GAP-M4 routing work: Watchdog
now routes to a real `deadmansswitch` receiver, and `severity=critical` fans out
over a `continue: true` chain to two receivers. Weakness 3 is **confirmed still
open, and worse than written**:

- `alertmanager_notifications_total{integration="email"}` = 182,
  `alertmanager_notifications_failed_total{integration="email"}` = 180. The
  email transport has effectively never delivered.
- `AlertmanagerFailedToSendAlerts{integration="email"}` is **firing**, and it
  routes to Discord — the channel email was meant to back up.
- Consequence: "critical fans out over two transports" is Discord-only in
  practice, and both the critical route and the dead-man's switch terminate
  inside the cluster they are supposed to be watching.

Remediation is staged in two operator steps, deliberately not auto-applied
because doing them out of order parks Alertmanager in `ContainerCreating`:

1. Seed `secret/platform/monitoring/alerting` in OpenBao with `ntfy-url` and
   `healthchecks-url`; the ExternalSecret is already deployed
   (`kubernetes/monitoring/kube-prometheus-stack/manifests/externalsecret.yaml`,
   which carries the exact command).
2. Enable the staged receiver/route block in
   `kubernetes/monitoring/kube-prometheus-stack/values.yaml`.

Both endpoints are consumed via Alertmanager's `webhook_configs.url_file`, so no
real URL is ever written into this repository (it is mirrored publicly) and no
`${...}` substitution is required (this values file bypasses the CMP). The
healthchecks.io leg on `deadmansswitch` is the first alerting termination
*outside* this cluster: when the cluster, Prometheus, Alertmanager or the
Discord bridge dies, the pings stop and healthchecks.io alarms.

Until both steps are done, `AlertEscalationSecretMissing` and
`AlertEscalationReceiverNotWired`
(`kubernetes/monitoring/alerts/alert-pipeline-selfcheck.yaml`) fire
continuously. The gap is a page, not a paragraph.

The `email` recipient itself stays broken: Alertmanager has no `to_file`
equivalent for `smtp_*`'s `to:` field, so it remains a literal `${ADMIN_EMAIL}`
until the values pipeline substitutes. Once ntfy is live, email is no longer
load-bearing as the second transport.
