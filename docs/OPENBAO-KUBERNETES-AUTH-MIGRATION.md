# Move the console to OpenBao Kubernetes auth

Status: proposed
Scope: `infraweaver-console` only — every other OpenBao consumer is already on Kubernetes auth.

## Why this is its own change

The console's OpenBao token expired silently on 2026-07-28 and took WordPress
site-config reads and Jellyfin account sync with it, surfacing to the operator
as `Checked 0/7 sites — 7 did not answer`. That was the **second** expiry.

The incident fix (`32400df`) added a daily `openbao-token-renew` CronJob and
three alerts. That is the right fix for the incident: it stops the bleeding
today and it pages before the next one. It is not the fix for the problem. It
keeps a credential alive that should not exist, and it does so by adding a
second mechanism that can itself fail — which is why that commit also had to add
an alert for *the renewal failing*, and one for *the exporter that watches the
renewal failing*.

Kubernetes auth removes the credential. With it gone, the CronJob, the three
alert rules, the exporter gauge and the console's expiry banner all go too. That
is a strictly larger blast radius than an incident fix should carry, so it is
written down here rather than smuggled in beside one.

## The end state

The console authenticates to OpenBao with its own in-pod ServiceAccount JWT,
against the existing `kubernetes` auth mount, using a role bound to its
ServiceAccount. No static token exists anywhere: not in OpenBao, not in
`infraweaver-console-secret`, not in the pod's environment.

## Why this is cheap

Almost all of it is already built, and the pattern is already proven **in this
cluster, against this OpenBao**:

| Prerequisite | Status |
|---|---|
| `kubernetes` auth mount | Exists (accessor `auth_kubernetes_3848c3a5`) |
| A policy granting what the console needs | Exists — `platform-k8s` |
| Templated per-namespace policy, if finer scoping is wanted later | Exists — `app-self-secrets` |
| A working example of a workload using it | Exists — ESO, `kubernetes/core/external-secrets/manifests/cluster-secret-store.yaml` |
| The console pod mounting its SA token | Already true (`automountServiceAccountToken: true`, with a Kyverno PolicyException) |
| Network path from console to OpenBao | Already open (`allow-console-to-openbao` selects every pod in the namespace) |
| `openbao-tokenreview` ClusterRoleBinding for the TokenReview API | Exists |

ESO made exactly this migration for exactly this reason. Its ClusterSecretStore
comment records it verbatim: *"This replaces the previous static tokenSecretRef
(secret openbao-token): that token had a fixed, non-renewable ~30d TTL that
nothing rotated, so it expired and broke every ExternalSecret + PushSecret
cluster-wide."* The console is the last consumer still holding that shape of
credential.

## What actually has to change

### 1. OpenBao — one role (out-of-band, root token; the auth mount is not GitOps-tracked)

```
bao write auth/kubernetes/role/infraweaver-console \
  bound_service_account_names=infraweaver-console \
  bound_service_account_namespaces=infraweaver-console \
  token_policies=platform-k8s \
  token_ttl=1h
```

Mirrors the `external-secrets` role exactly, including the 1h TTL. A short TTL
is the point: the SA JWT the console presents is rotated by the kubelet, so a
1h OpenBao token is re-minted continuously and there is nothing to renew.

Whether the console should keep the full `platform-k8s` policy is a **separate
question, deliberately not bundled here**. It currently reads
`secret/platform/*`, `secret/private/*`, `secret/catalog/*` and `secret/iwsl/*`
and writes `secret/infraweaver/*`; narrowing that is a scoping change that
should be made on its own evidence, not as a side effect of changing how it
authenticates. Migrate at parity first.

### 2. Console — login instead of read

Three call sites read a token straight from the environment:

- `src/lib/openbao/kv.ts:46`
- `src/lib/udm/store.ts:31`
- `src/lib/nas/store.ts:115`

All three resolve `process.env.OPENBAO_TOKEN || process.env.VAULT_TOKEN`. They
should share one accessor that:

1. reads the SA JWT from `/var/run/secrets/kubernetes.io/serviceaccount/token`
   **on every login**, not once at boot — the kubelet rotates that file, and a
   cached JWT is the same expiry bug one layer down;
2. POSTs it to `auth/kubernetes/login` with role `infraweaver-console`;
3. caches the returned client token in memory until shortly before its TTL, and
   re-logs in rather than renewing — a fresh login is cheaper to reason about
   than a renewal chain, and cannot accumulate a lease that outlives the pod;
4. re-logs in once on a 403, then fails. Otherwise a revoked role turns into a
   tight retry loop against OpenBao.

The three call sites keeping their own copies of this is how the current bug
survives: there is no single place that knows whether the credential is healthy.
One accessor, three callers.

### 3. Deletions, once the console is verified on the new path

- `openbao-token` from `kubernetes/catalog/infraweaver-console/base/externalsecret.yaml`
- `OPENBAO_TOKEN` from `deployment.yaml`
- `kubernetes/catalog/infraweaver-console/base/openbao-token-renew-cronjob.yaml` and its kustomization entry
- `kubernetes/monitoring/alerts/openbao-token.yaml` — all of it: TTL warn/critical, the cron-liveness rule, the `absent()` blindness rule, the suspend rule, the non-renewable rule. Every one watches a credential that no longer exists.
- The TTL gauge in `src/lib/secrets/token-metrics.ts` and its wiring in `/api/platform/metrics`
- The console's expiry banner and the thresholds in `lifecycle-types.ts`
- The `openbao-token` entry in `catalog.yaml`
- Finally, `bao kv delete` the key itself. Leaving a live token in OpenBao that
  nothing uses and nothing watches is strictly worse than the state this change
  set out to fix.

**Order matters.** `infraweaver-console-secret` is `creationPolicy: Owner` with
`deletionPolicy: Retain`: an ExternalSecret with one unresolvable property does
not skip that key, it fails the **whole** secret, and every other value in it
stops refreshing. So: remove the `openbao-token` ES entry and the env var in one
commit, confirm `SecretSynced True` and the console healthy, and only then
delete the key from OpenBao. Never the other way round.

## Verification

1. `bao write auth/kubernetes/role/infraweaver-console ...`, then confirm a login
   works from inside the console pod with its own SA token before changing any
   code.
2. Deploy the console with the accessor and **both** paths available — env token
   still present, login preferred. Confirm from logs and a WordPress
   site-config read that the login path is the one being used.
3. Only then remove the env var and the ES entry.

Step 2 is what makes this safe to do at all: the failure mode of getting it
wrong is the exact outage this is meant to prevent, so the new path must be
proven while the old one is still there to fall back on.

## What this does not fix

Kubernetes auth binds the credential to the pod's identity and removes the
expiry class of failure. It does not narrow what the console can read, and it
does not make an OpenBao outage survivable — a console that cannot reach OpenBao
still cannot read site config. Both are real, both are separate.

## Cross-references

- `32400df` — the incident fix this defers to: the renew CronJob and alerts
- `kubernetes/core/external-secrets/manifests/cluster-secret-store.yaml` — the working example
- `kubernetes/core/openbao/manifests/rbac.yaml` — the `openbao-tokenreview` binding the auth mount depends on
