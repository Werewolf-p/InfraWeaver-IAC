# OpenBao operations

Operating the platform's secret layer: how to populate keys, what breaks when
OpenBao is unavailable, and how to get it back.

**Scope of authority.** OpenBao is a single-replica Raft node in namespace
`openbao`. Every `ExternalSecret` in the cluster (28 as of 2026-08-07) resolves
through `ClusterSecretStore/openbao`. There is no second source. If OpenBao is
sealed, down, or has lost its data, *nothing* in this cluster refreshes a
credential.

**Values never enter git.** This document contains paths, property names and
command shapes only. If you find yourself about to paste a value into a file in
this repository, stop — the correct destination is stdin on a `bao kv patch`.

Facts below were verified read-only against `admin@infraweaver-prod` on
2026-08-07 unless stated otherwise. Commands that mutate are marked **MUTATES**
and were not executed while writing this.

---

## 0. The one thing to read first: there is no auto-unseal

`sys/seal-status`, live:

```json
{ "type": "shamir", "initialized": true, "sealed": false, "t": 1, "n": 1,
  "storage_type": "raft", "version": "2.5.3" }
```

`type: shamir`, `t=1`, `n=1`, and **no `seal` stanza in `openbao-config`** —
confirmed against the live ConfigMap. There is no transit auto-unseal, no cloud
KMS, no HSM. OpenBao starts **sealed** every single time the process restarts,
and a sealed OpenBao serves nothing.

What actually gets it open again is **not** a server feature. It is a shell loop
in a sidecar container:

```
openbao-0
  ├── container "openbao"     quay.io/openbao/openbao:2.5.3
  └── container "autounseal"  quay.io/openbao/openbao:2.5.3
        while true; do
          bao status ... ; if exit code == 2 (sealed); then
            UNSEAL_KEY=$(cat /etc/openbao-unseal/unseal_key)
            bao operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
          fi; sleep 30
        done
```

`/etc/openbao-unseal` is Secret `openbao/openbao-unseal` (keys: `unseal_key`,
`root_token`) mounted read-only, mode 0444.

So the honest statement of this platform's secret-layer availability is:

> **Every credential in the cluster depends on a 30-second `sleep` loop in an
> unmonitored sidecar, replaying a single Shamir share out of a Kubernetes Secret
> that lives in the very cluster it protects.**

In normal operation it works — the openbao container has restarted once
(`restartCount: 1`, pod start 2026-07-28, leader `active_time` 2026-08-02T11:44:58Z)
and recovered on its own. The problem is what happens when it does not.

### 0.1 The alert for this cannot fire

`kubernetes/monitoring/alerts/manifests/prometheus-rules.yaml:212` defines:

```yaml
- alert: OpenBaoSealed
  expr: vault_core_unsealed == 0
  summary: "OpenBao is SEALED — secrets unavailable"
```

That alert is **permanently silent**. Two independent reasons, both verified:

1. **The metric is never scraped.** There is no `ServiceMonitor` or `PodMonitor`
   for OpenBao anywhere in the cluster, and `kubernetes/core/openbao/values.yaml`
   configures no `serverTelemetry`. Querying Prometheus for `vault_core_unsealed`
   returns an **empty vector**. A PromQL comparison over a series that does not
   exist produces no samples, so `== 0` never matches — the rule cannot fire even
   in principle.
2. **The endpoint would 403 anyway.** The `listener "tcp"` block has no
   `telemetry { unauthenticated_metrics_access = true }`, so
   `GET /v1/sys/metrics?format=prometheus` returns `403 Forbidden` without a
   token. Adding a ServiceMonitor alone would not fix (1).

Consequence: if the autounseal sidecar ever fails — wrong key, Secret deleted,
sidecar not scheduled, `bao operator unseal` erroring (it is invoked with
`>/dev/null 2>&1`, so the reason is discarded) — OpenBao stays sealed and the
*only* symptom is ExternalSecrets quietly ceasing to refresh, surfacing hours
later as unrelated-looking application failures.

**Detection you can rely on today** is therefore manual:

```bash
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json | jq '.sealed'
kubectl logs -n openbao openbao-0 -c autounseal --tail=20
```

**Recommended fix (not applied here — `kubernetes/core/openbao/**` is owned
elsewhere and OpenBao cannot be restarted without a manual unseal):** add
`telemetry { unauthenticated_metrics_access = true }` inside the `listener "tcp"`
block, add a ServiceMonitor scraping `/v1/sys/metrics?format=prometheus`, and add
an `absent(vault_core_unsealed)` companion alert so a blind exporter pages
instead of going quiet. Both config changes require a pod restart, which
means a planned unseal window: have §1 open, confirm the `autounseal` sidecar is
healthy first, and expect to unseal by hand if it is not.

### 0.2 Where the unseal key lives, and why that is a DR problem

| | |
|---|---|
| Kubernetes Secret | `openbao/openbao-unseal` |
| Keys | `unseal_key`, `root_token` |
| Created | 2026-06-13T20:21:27Z, via `kubectl apply` (carries a `last-applied-configuration` annotation) |
| Mounted by | the `autounseal` sidecar, read-only at `/etc/openbao-unseal` |

This is a **circular dependency**. The key that unseals the cluster's secret
store is stored *in the cluster*, as an ordinary Secret, in etcd. It survives a
pod restart and a node reboot. It does **not** survive losing etcd, and it is not
in git (correctly — it must never be).

**Action required, and it is not optional:** the `unseal_key` and `root_token`
must exist in at least one place outside this cluster — a password manager entry,
a sealed envelope, or an encrypted offline copy — or a cluster rebuild is
unrecoverable: the Raft data would be restorable and permanently unopenable.
Record *where* it is held (not the value) in the risk register. Treat rotation of
either as a change requiring a maintenance window.

---

## 1. Recovery procedure: OpenBao is sealed

Symptoms: `ExternalSecret`s stop refreshing (they do not immediately go
`False` — a synced Secret persists, so the first sign is usually a *stale*
credential, an expired token, or a pod that cannot start); OpenBao API calls
return `503 Vault is sealed`.

```bash
# 1. Confirm. `sealed: true` is the whole diagnosis.
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json | jq '{sealed,initialized,t,n}'

# 2. Ask the sidecar why it did not do this itself. It logs one line per
#    attempt; "Unseal failed" means the key was present and rejected,
#    "Sealed but no unseal key yet" means the Secret is missing or empty.
kubectl logs -n openbao openbao-0 -c autounseal --tail=50

# 3. Confirm the sidecar can still see its key. Prints the SIZE, not the value.
kubectl exec -n openbao openbao-0 -c autounseal -- \
  sh -c 'wc -c < /etc/openbao-unseal/unseal_key'

# 4. Manual unseal — MUTATES. Only if the sidecar is dead or its key is wrong.
#    `bao operator unseal` with NO key argument reads the key from stdin (the
#    hidden prompt), so piping it means the value never becomes an argv entry
#    and never lands in shell history. Do NOT pass it as an argument — the
#    CLI's own help calls that out as the thing not to do.
kubectl get secret openbao-unseal -n openbao -o jsonpath='{.data.unseal_key}' | base64 -d \
  | kubectl exec -i -n openbao openbao-0 -c openbao -- \
      env VAULT_ADDR=http://127.0.0.1:8200 bao operator unseal

# 5. Verify, then force the backlog through instead of waiting out each
#    refreshInterval (up to 24h for registry-pull-secret).
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json | jq '.sealed'
kubectl get externalsecret -A --no-headers | grep -v True     # expect: empty
```

If step 4 fails with "unseal key does not match", the Secret and the Raft data
have diverged — stop and use the offline copy from §0.2. There is no other way
in; `t=1, n=1` means there is exactly one share and no quorum to reconstruct.

**Never restart the OpenBao pod as a troubleshooting step.** It comes back
sealed, and the only thing that reopens it is the mechanism you are already
debugging.

---

## 2. Populating a key (the runbook for a failing ExternalSecret)

An `ExternalSecret` in `SecretSyncedError` is one of exactly three things.
Diagnose before acting — the fixes are unrelated and two of them are not this
section.

| Symptom | Cause | Fix |
|---|---|---|
| `permission denied` in the OpenBao audit log | policy `platform-k8s` lacks the path | policy union, §4 |
| path exists, property missing | the key was never seeded | this section |
| path does not exist | stale reference in the manifest | fix the manifest, not the vault |

Find out which:

```bash
# The ES tells you the path and property it wants.
kubectl get externalsecret -n <ns> <name> -o jsonpath='{.spec.data[*].remoteRef}' | jq

# List the property NAMES at that path — never the values.
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_TOKEN="$(kubectl get secret openbao-unseal -n openbao -o jsonpath='{.data.root_token}' | base64 -d)" \
      VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv get -format=json -mount=secret <path-without-the-secret/-prefix> \
  | jq '.data.data | keys'
```

### 2.1 `patch`, never `put`

The KV mount is **v2** (`ClusterSecretStore/openbao` → `path: secret`,
`version: v2`).

> `bao kv put` REPLACES THE ENTIRE OBJECT AT THE PATH.
> `bao kv patch` merges into it.

Several paths hold multiple unrelated credentials — `secret/private/tradesphere`
alone carries `binance_api_key`, `binance_api_secret` and `inspect_api_token`,
feeding two different ExternalSecrets. A `put` of one property destroys the other
two, and because KV v2 versions the write it looks like it worked.

**MUTATES** — the correct shapes:

Use the `-mount=` form, not the path-like one. The CLI calls
`bao kv patch secret/private/tradesphere …` deprecated and confusing precisely
because `secret/private/tradesphere` is not the real API path (that is
`secret/data/private/tradesphere`, which is what appears in policies and in the
audit log). An ExternalSecret's `remoteRef.key: secret/private/tradesphere` maps
to `-mount=secret private/tradesphere`.

```bash
ROOT_TOKEN=$(kubectl get secret openbao-unseal -n openbao -o jsonpath='{.data.root_token}' | base64 -d)

# ONE property, value read from stdin. `<name>=-` is the documented "read this
# property's value from stdin" form, so the value never appears in argv, in
# `ps`, or in shell history. This is the shape to reach for by default.
printf '%s' "$THE_VALUE" | kubectl exec -i -n openbao openbao-0 -c openbao -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv patch -mount=secret private/tradesphere anthropic_api_key=-

# SEVERAL properties: run the same command once per property. `patch` merges,
# so N invocations converge on the same object as one batched write would, and
# each one keeps its value on stdin. Do NOT reach for the `@file.json` form to
# save a round trip — it means writing every value to a disk first.
printf '%s' "$RCON" | kubectl exec -i -n openbao openbao-0 -c openbao -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv patch -mount=secret catalog/game-hub/<server> rcon-password=-

# Verify by NAME and version only. `.data.data|keys` never prints a value.
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv get -format=json -mount=secret private/tradesphere \
  | jq '{version: .data.metadata.version, keys: (.data.data|keys)}'
```

If the version number did not increase, the write did not happen — check for a
`permission denied` in the audit log rather than assuming success.

Then let it land, or nudge it — annotating an ExternalSecret is a normal
Kubernetes write, not an OpenBao one:

```bash
kubectl annotate externalsecret -n <ns> <name> force-sync="$(date +%s)" --overwrite
kubectl get externalsecret -n <ns> <name>
```

`unset "$ROOT_TOKEN"` when done, and remember the shell that ran the `patch` may
still hold the value in its history if you did not use stdin.

### 2.2 Known paths

| Path | Properties | Consumer |
|---|---|---|
| `secret/platform/*` | many | most ExternalSecrets (read-only for ESO) |
| `secret/platform/service-accounts/*` | per-token objects | console PAT minting (**read+write**) |
| `secret/infraweaver/*` | — | console API |
| `secret/iwsl/iw-keys` | `ed25519Pk/Sk`, `slhdsaPk/Sk`, `slhdsa192fPk/Sk`, `kid` | `infraweaver-console/infraweaver-iwsl-iw-keys` |
| `secret/catalog/game-hub/palworld` | `admin-password` | `game-hub/game-hub-server-credentials` |
| `secret/catalog/game-hub/cobalt-grove-45` | `rcon-password` | same |
| `secret/private/tradesphere` | `binance_api_key`, `binance_api_secret`, `inspect_api_token` | `tradesphere-binance`, `tradesphere-inspect` |

`anthropic_api_key` is deliberately **absent** from `secret/private/tradesphere`
and its ExternalSecret was removed on 2026-08-07 rather than left failing — see
the comment block in `private-apps/tradesphere/k8s/externalsecrets.yaml` for the
re-enable procedure. Seeding the key is step 1 of that procedure; restoring the
resource is step 3.

---

## 3. The audit device — and the 3 GB file

**Correction to the compliance record (GAP-M6).** The audit finding stated
"OpenBao audit device not enabled/evidenced" on the grounds that nothing was
found in `kubernetes/core/openbao/manifests/`. That conclusion is **wrong**: the
device is configured in `kubernetes/core/openbao/values.yaml:49-56`, inside the
Helm chart's `server.standalone.config`, and it is live. Verified in the rendered
ConfigMap `openbao/openbao-config`:

```hcl
audit {
  type = "file"
  path = "/openbao/data/audit.log"
  options = {
    file_path     = "/openbao/data/audit.log"
    log_raw       = "false"
    hmac_accessor = "true"
  }
}
```

`log_raw = "false"` means secret values are HMAC'd, not written in the clear —
the log is safe to read and to ship. **Do not add a second audit device.** A
file audit device that cannot write blocks every OpenBao request, so a duplicate
pointed at the same path is an outage, not a redundancy.

Evidence it is working: the G1 policy investigation reconstructed the exact
instant of the 2026-08-06 policy clobber, and the per-caller denial counts on
either side of it, entirely from this log.

### 3.1 It is 3 GB and nothing rotates it

```
-rw------- 1 openbao openbao 3044679768 Aug  7 10:55 /openbao/data/audit.log
-rw------- 1 openbao openbao   16801792 Aug  7 10:55 /openbao/data/vault.db
```

**2.84 GiB of audit log against 16 MB of actual data.** The comment above the
stanza claims "Log is rotated at 100MB". **That claim is false.** The OpenBao
file audit device has no size-based rotation and no such option was set; the
file has grown monotonically since 2026-06-13. The comment should be corrected or
deleted by whoever owns `kubernetes/core/openbao/values.yaml`.

Why it matters more than the number suggests: the PVC is `local-path`, which does
not enforce its declared size. `df` inside the pod reports the **node's**
filesystem (295.8 G, 38% used), not a 5 Gi quota. So nothing will stop the file at
5 Gi, nothing will fail with "volume full", and the growth is charged to the node
— it can starve co-tenant workloads before OpenBao itself notices. It is also why
grepping the log times out and why any read of it must be tail-bounded:

```bash
kubectl exec -n openbao openbao-0 -c openbao -- \
  sh -c 'tail -c 20000000 /openbao/data/audit.log | grep -c "permission denied"'
```

**Rotation procedure.** The file device reopens its path on `SIGHUP`, which is
the whole rotation primitive — move the file, then signal. This is the standard
logrotate `copytruncate`-free pattern and it loses no entries.

**MUTATES** — manual rotation, safe to run while OpenBao serves traffic:

```bash
# 1. Rename the live file. The device keeps writing to the same inode.
kubectl exec -n openbao openbao-0 -c openbao -- \
  mv /openbao/data/audit.log /openbao/data/audit.log.$(date +%Y%m%d)

# 2. SIGHUP the OpenBao process so the device reopens the original path.
#
#    ⚠ PID 1 IS NOT THE SERVER. The container's process tree is
#      1 = /bin/sh (the config-templating wrapper), 12 = dumb-init, 13 = bao.
#    `kill -HUP 1` signals the wrapper shell, which runs under `sh -ec` and
#    would take the container down — leaving OpenBao SEALED, which is the one
#    state this document exists to keep you out of. The PID is not stable
#    either, so find it by name.
kubectl exec -n openbao openbao-0 -c openbao -- sh -c '
  for p in $(ls /proc | grep "^[0-9]"); do
    if [ "$(cat /proc/$p/comm 2>/dev/null)" = "bao" ]; then
      echo "signalling bao at PID $p"; kill -HUP "$p"; exit 0
    fi
  done
  echo "no bao process found — do NOT fall back to PID 1"; exit 1'

# 3. Confirm a NEW, small file exists and is being appended to.
kubectl exec -n openbao openbao-0 -c openbao -- ls -la /openbao/data/

# 4. Copy the rotated file off-node BEFORE deleting it — it is the only
#    secret-access audit trail this platform has (ISO A.8.15 evidence).
kubectl exec -n openbao openbao-0 -c openbao -- \
  gzip /openbao/data/audit.log.$(date +%Y%m%d)
kubectl cp openbao/openbao-0:/openbao/data/audit.log.$(date +%Y%m%d).gz \
  ./audit-$(date +%Y%m%d).log.gz -c openbao
```

**The durable fix is not a manual procedure.** Pick one:

- a CronJob in namespace `openbao` doing steps 1–4 weekly, with a retention sweep
  (recommended: it needs only `pods/exec` in one namespace and it produces the
  off-node copy that step 4 exists for); or
- ship the log to Loki via a promtail sidecar and truncate aggressively at the
  source — this also closes GAP-H5's "no secret-access trail in the log store"
  and makes retention a Loki setting rather than a disk race.

Until one of those exists, put the manual rotation on the maintenance calendar.
At the current rate the log has grown ~3 GB in 55 days.

---

## 4. Policies, tokens, and the two things that are wrong right now

### 4.1 `platform-k8s` is maintained imperatively and drifts

`bao policy write` is a **full replace with no compare-and-swap**. Two copies of
`bootstrap-openbao.sh` existed in two repositories, each holding a different half
of the `platform-k8s` policy, so running either one silently destroyed the
other's grants. That is exactly what happened at 2026-08-06T20:21:18Z: a
bootstrap run from the wrong checkout revoked `iwsl/*`, `catalog/*` and
`private/tradesphere` and broke four ExternalSecrets 25 seconds later.

Repaired 2026-08-07 by writing the **union** of both copies plus
`secret/data/private/tradesphere` — a strict superset, so nothing could regress.
27/28 ExternalSecrets synced; the 28th was `tradesphere-ai`, which was never a
policy problem and has since been removed from git.

Rules that follow, and they are not optional:

- **Never re-run a bootstrap script to make a policy edit.** It rewrites ~30 KV
  paths, tunes token auth and mints tokens as side effects. A targeted
  `bao policy write <name> -` from stdin touches exactly one object.
- **Always `bao policy read` first and keep the output** — it is your only
  rollback artifact, because the write is a replace.
- `platform-k8s` is misnamed: it is the ESO read policy *and* the console's write
  policy (`secret/data/platform/service-accounts/*`, load-bearing for PAT
  minting — 64 real denials preceded its addition). Splitting it into
  `platform-k8s` (ESO, read-only) and `console-runtime` (console writes) is the
  standing recommendation.
- `scripts/validate-openbao-policy-drift.sh` exists in this repo. Nothing runs it
  on a schedule. A CronJob exporting a drift gauge would have paged within
  minutes instead of surfacing 12 hours later as four Degraded ArgoCD apps.

### 4.2 `token-eso-clustersecretstore` is an orphan with a year of life

A static OpenBao token holding policy `platform-k8s`, with roughly **341 days of
TTL remaining**. It has had no consumer since commit `80d958f`
*"chore: retire ESO static OpenBao token, provision k8s-auth role at bootstrap
(#97)"* (2026-07-14), which replaced static-token auth with
Kubernetes auth.

Verified orphaned, live:

- `ClusterSecretStore/openbao` uses `auth.kubernetes.role: external-secrets` —
  there is no `tokenSecretRef` in any store in the cluster (count: 0);
- Secret `kube-system/openbao-eso-token` does not exist;
- namespace `external-secrets` holds only `external-secrets-webhook`;
- the audit log shows ESO authenticating as
  `kubernetes-external-secrets-external-secrets`, never as this token.

So it is an unused credential, with broad read access to the platform's secrets,
valid until roughly mid-2027. **Revoke it.**

**MUTATES** — revoke by accessor, never by looking up the token value:

```bash
ROOT_TOKEN=$(kubectl get secret openbao-unseal -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
EXEC=(kubectl exec -n openbao openbao-0 -c openbao --
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200)

# 1. Find the accessor. Confirm the display_name before revoking anything.
for A in $("${EXEC[@]}" bao list -format=json auth/token/accessors | jq -r '.[]'); do
  "${EXEC[@]}" bao token lookup -accessor -format=json "$A" \
    | jq '{display_name, policies, ttl}'
done

# 2. Revoke the one whose display_name is token-eso-clustersecretstore.
"${EXEC[@]}" bao token revoke -accessor <accessor>

# 3. Prove nothing broke. ESO re-auths through kubernetes auth, so this should
#    be a no-op for every ExternalSecret.
sleep 120; kubectl get externalsecret -A --no-headers | grep -v True   # expect: empty
```

Rollback: there is none — a revoked token cannot be restored. That is why step 1
prints `display_name` for every accessor before step 2 names one. The blast
radius if you revoke the wrong one is the console's own token
(`token-infraweaver-console`, policies `default, platform-k8s, wordpress`), which
would need re-minting via `bootstrap-openbao.sh`.

### 4.3 Known-open, documented here so it is not rediscovered

- **`secret/data/platform/audit/signing`** — 900+ denials, continuous since at
  least 2026-08-02, caller `token-infraweaver-console`. The consumer
  (`apps/infraweaver-console/src/lib/audit/signing.ts`) needs **write**;
  `platform/*` grants only `read,list` and no policy in either repo covers
  `audit/`. The console's audit-log signing is silently failing. Deliberately not
  fixed alongside the ESO repair: it is a new write grant on a security-sensitive
  path and deserves its own review.
- **The `wordpress` policy is stale too**, by the mechanism originally
  hypothesised for `platform-k8s`: six paths added by infra commit `d35d412`
  (2026-08-01) were never applied, because the script copy that actually ran does
  not write a `wordpress` policy at all. Breaks Fleet Command credentials, Game
  Hub network secrets, and the trust ledgers. Not an ExternalSecret problem, so it
  blocks no ArgoCD app.

---

## 5. Quick reference

```bash
# Health
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json | jq '{sealed,initialized,version}'
kubectl logs -n openbao openbao-0 -c autounseal --tail=20

# Everything that is not syncing
kubectl get externalsecret -A --no-headers | grep -v True

# Recent denials (tail-bounded — the log is gigabytes)
kubectl exec -n openbao openbao-0 -c openbao -- sh -c \
  'tail -c 20000000 /openbao/data/audit.log | grep "permission denied" | tail -20'

# Property names at a path (never values)
kubectl exec -n openbao openbao-0 -c openbao -- \
  env VAULT_TOKEN="$(kubectl get secret openbao-unseal -n openbao -o jsonpath='{.data.root_token}' | base64 -d)" \
      VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv get -format=json -mount=secret <path-without-the-secret/-prefix> \
  | jq '.data.data | keys'
```

| Never do this | Because |
|---|---|
| `kubectl rollout restart -n openbao` | it comes back **sealed**; only the sidecar reopens it |
| `bao kv put` on a shared path | replaces the whole object, destroying sibling properties |
| re-run `bootstrap-openbao.sh` for a policy edit | `policy write` is a full replace; it clobbers the other copy's grants |
| add a second file audit device | a blocked audit device blocks every request |
| paste a value into a manifest | that is what `bao kv patch … =-` and stdin are for |

## Related

- `docs/BACKUP-AND-RESTORE-RUNBOOK.md` — volume and etcd recovery
- `docs/OPENBAO-KUBERNETES-AUTH-MIGRATION.md` — how ESO stopped using a static token
- `docs/BREAK-GLASS.md` — human access when SSO is unavailable
- `scripts/validate-openbao-policy-drift.sh` — live-vs-git policy comparison
- `scripts/validate-eso-refs.sh` — catches `secretStoreRef` typos before they ship
