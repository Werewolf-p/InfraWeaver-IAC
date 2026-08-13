# InfraWeaver GitOps / IaC Operating Model

How infrastructure changes are authored, validated, shipped, and reconciled — the
"platform runbook." Goal: **fully declarative (ArgoCD reconciles git → cluster)**,
**no secrets or local values in git**, yet **easy for a developer to update**.
Modeled on how larger orgs run GitOps (separation of config from code, PR-gated
changes, secrets in a vault, env params in overlays, automated image promotion).

---

## 0. Forking & placeholders (open-source model)

InfraWeaver is a **forkable template**: committed config uses `${PLACEHOLDER}`
variables, never real deployment values. A forker fills `.env` (gitignored) — or
runs `scripts/setup.sh` — then `scripts/generate-from-env.sh` substitutes the
placeholders into `kubernetes/`, `envs/` and `users.yaml` before bootstrap. This
keeps every deployment-specific value (domain, repo URLs, image registry, node
topology, admin email) out of upstream and lets forks pull updates without
conflicts. The **only** hardcoded value is the user-feedback URL (see README,
"The one fixed value"). Full guide: README → "Forking InfraWeaver".

> **Target evolution:** move placeholder resolution from the provision-time
> `generate-from-env.sh` step to **sync-time inside ArgoCD** via a Config
> Management Plugin, so ArgoCD watches this repo with `${}` intact. Design:
> [`gitops-cmp-substitution.md`](./gitops-cmp-substitution.md).

---

## 1. Principles

1. **Git is the source of truth.** The cluster is a projection of `main`. Never
   `kubectl edit` live objects that ArgoCD owns — `selfHeal` will revert you.
2. **Config is separated from code.** App source builds an image; *what is
   deployed* lives in this infra repo.
3. **Secrets never live in git.** Git holds *references*; real values live in
   OpenBao and are projected by External Secrets Operator (ESO).
4. **Changes are gated, not trusted.** A PR must pass CI (`validate-iac`) before
   it can reach `main`. The client-side `pre-push` hook is a fast local pre-check,
   not the real gate.
5. **One way to validate.** The same `scripts/validate-iac.sh` runs locally and
   in CI, so "passes on my laptop" == "passes the pipeline."

---

## 2. Repository topology

| Repo | Owns | Consumed by |
|------|------|-------------|
| `InfraWeaver-platform` | application source code | image build → registry |
| `InfraWeaver-infra` (this) | all declarative infra/config | ArgoCD |

> The local `platform/kubernetes → infra/kubernetes` symlink is a *viewing*
> convenience only; nothing is committed through it. Mental model:
> **platform = code, infra = config.**

**Current split to rationalize:** some ArgoCD Applications source from GitHub
(`catalog-infraweaver-*`, authentik) and some ApplicationSets source from OneDev
(`platform/`, `core/`, `monitoring/`). Target: pick **one** authoritative remote
for ArgoCD (recommended: GitHub `main`, mirror to OneDev) so there is a single
reconcile source. Tracked as migration item M4.

---

## 3. Config layering (the param model)

Kustomize `base/` + `overlays/`. Reference implementation:
`kubernetes/catalog/infraweaver-console/` (see its README).

```
<app>/
  base/                # environment-agnostic manifests — change rarely
  overlays/
    prod/              # COMMITTED params for the live cluster (image tag, scaling)
    local/             # GITIGNORED — a dev's personal override, never cluster truth
```

- **Shared/prod params** (image tag, replicas bounds, hostnames) → `overlays/prod/`,
  committed. This is the only place a normal change touches.
- **Local dev params** → `overlays/local/` (gitignored) or `*.local.yaml`. A dev
  iterates with `kubectl apply -k overlays/local` or a throwaway ArgoCD app, and
  nothing leaks into cluster truth. **This is the answer to "local values stay
  local but it's still IaC."**
- Helm-based apps (`platform/`, `core/`) already follow the equivalent pattern via
  `$values/.../values.yaml`.

---

## 4. Secrets model (no secrets in git)

**Mechanism (already in place):** OpenBao (vault) + External Secrets Operator.
Git contains an `ExternalSecret` that *references* a key; ESO pulls the value and
creates the real `Secret` in-cluster. 37 ExternalSecrets are in use.

**Rule enforced by `validate-iac.sh` (§3 secret-leak gate):** a PR that adds a
raw `kind: Secret` with a real value fails. Existing offenders are *baselined*
(ratchet) so the gate is enforceable today while we migrate them.

**Known offenders to migrate (remove from baseline as fixed):**

| File | Secret | Action |
|------|--------|--------|
| `catalog/onedev/manifests/resources.yaml` | `onedev-db-secret` (real DB password) | → ExternalSecret from OpenBao (or generated Secret) — **P1** |
| `catalog/calibre-web/manifests/secrets.yaml` | `oauthlib-relax-token-scope-secret` | non-sensitive flag → **ConfigMap** (not a Secret) |
| `catalog/{vaultwarden,bookstack}/manifests/secrets.yaml` | placeholder `change-me` | → ExternalSecret; never commit the real value |

---

## 5. The change flow (target)

```
 dev edits overlays/prod (or base)         ┐
   └─ scripts/validate-iac.sh (local)      │  fast local pre-check
 git push feature branch → open PR         │
   └─ CI: validate-iac (render+schema+secret gate)   ← REQUIRED check
 PR review + green CI → merge to main (protected)    ← the real gate
   └─ ArgoCD detects main, syncs cluster   ┘  reconcile
```

**To adopt (M1):** enable GitHub **branch protection** on `main` — require the
`validate-iac` check + 1 review, disallow direct pushes. This replaces "push to
main + client-side hook" (a band-aid) with the standard server-side gate. The
`pre-push` hook stays as a courtesy local check.

**Image bumps** are the exception that may fast-path to `main` (small, frequent):
they only change `image:`/`newTag:` lines, which the `pre-push` guard and CI both
recognize. Performed by the feedback dispatch (`/approve`) and reversible
(`/rollback`).

---

## 6. Image automation

- App built externally → pushed to `registry.int.${BASE_DOMAIN}` / ghcr.io.
- The pin (`overlays/prod/kustomization.yaml` `newTag:`) is bumped by
  `infraweaver-dispatch` on `/approve` and reverted on `/rollback`.
- **Optional hardening (M3):** re-enable ArgoCD Image Updater (currently
  `*.disabled`) with **git write-back** so tag bumps are committed automatically
  with an audit trail, removing the bespoke `sed` path.

---

## 7. Drift & selfHeal

- ArgoCD `selfHeal: true` reverts out-of-band cluster edits — intended.
- **Do not declare a field two owners want.** Classic trap: `spec.replicas` in a
  Deployment that also has an HPA → selfHeal ↔ HPA war. Fix: omit `replicas` from
  the manifest (HPA owns it). Applied to the console; apply to every HPA'd app.
- For imperatively-managed workloads (e.g. game servers), keep them out of git
  ownership entirely rather than fighting selfHeal.

---

## 7.1 Server-Side Apply hazards

**Read this before adding `ServerSideApply=true`, `RespectIgnoreDifferences=true`,
or any `ignoreDifferences` entry to an Application.**

Four SSA traps have bitten this platform. Three of them fail *loudly*. The
fourth reports **success**, and it is the reason this section exists.

### The four variants

| # | Hazard | How it shows |
|---|--------|--------------|
| 1 | `--force` cannot be combined with `--server-side` | **Loud.** Sync fails outright once `ServerSideApply=true` + `RespectIgnoreDifferences` + a real diff coincide |
| 2 | Namespace tracking-id "SSA ownership ping-pong" | **Loud-ish.** Perpetual OutOfSync / churn on Namespaces |
| 3 | **In-list `ignoreDifferences` silently drops the list from the SSA payload** | **SILENT. Reports `serverside-applied` and `Synced`.** |
| 4 | Stale `last-applied-configuration` left by a client-side apply | Churn, and the object drifts out of ArgoCD's ownership |

**(1) `--force` + `--server-side`.** When an Application sets
`ServerSideApply=true` *and* `RespectIgnoreDifferences=true` *and* there is a
real diff, ArgoCD's apply can reach for `--force`, which the API server refuses
alongside `--server-side`. First hit on `catalog-game-hub-servers` (2026-07-05).
Fix used: opt the specific resource out with the per-resource annotation
`argocd.argoproj.io/sync-options: ServerSideApply=false`. Note this trap is
*dormant until a real diff exists* — it detonates on an unrelated later sync.

**(2) Namespace tracking-id ping-pong.** See the note at
`kubernetes/core/argocd/values.yaml` (~line 271) and the fieldset-ownership
comment in `kubernetes/core/psa/namespace-labels.yaml` (~line 60).

### (3) The silent one — an SSA apply that reports success and writes nothing

**Incident, 2026-08-07, `core-kyverno-policies` /
`ClusterPolicy/mutate-default-sa-automount`:**

- 17:33:31 commit `2ac5e87` adds a second rule to `spec.rules`.
- 17:35:29–33 the automated sync of that revision runs. `phase: Succeeded`.
  syncResult message: `serverside-applied`. App: `Synced`.
- The live object did not have the new rule. An operator landed it by hand at
  17:37:12 with a plain `kubectl apply`.

**The diagnostic that proved it — use this one, it generalizes.** Compare the
object's `managedFields` entry for `argocd-controller` against the sync's
`operationState.finishedAt`:

```bash
kubectl get <kind> <name> -o json --show-managed-fields \
  | jq '[.metadata.managedFields[] | {manager, operation, time, spec: (.fieldsV1["f:spec"] | keys)}]'
kubectl -n argocd get application <app> -o jsonpath='{.status.operationState.finishedAt}'
```

On the incident object, `argocd-controller`'s fieldset was last changed at
**14:56:55Z** — 2h38m *before* the 17:35 sync that claimed to apply it — and
contained **no `f:rules`**. An apply that "succeeded" without moving the fieldset
of the fields it was supposed to change **did not send them**. (Had the payload
carried `spec.rules` at all, even unchanged, ArgoCD would have gained `f:rules`.
Had it conflicted with another owner, the sync would have failed loudly.)

**CAUSE — H1 CONFIRMED 2026-08-13. Fixed; do not re-add the in-list ignore.**
The app's `ignoreDifferences` included `.spec.rules[].skipBackgroundRequests` —
a path reaching *inside* an atomic list. `ClusterPolicy.spec.rules` has no
`x-kubernetes-list-type: map` (measured: the CRD's `spec.rules` schema declares
only `description`, `items`, `type`), so it is atomic and cannot be surgically
edited. Under `RespectIgnoreDifferences` + `ServerSideApply`, ArgoCD normalises
the whole list out of the desired object and sends the **live** rules back, so
the apply writes nothing. This trap existed since the repo's first commit; it
only detonates when a *real* rules change is pending — the worst possible
failure shape, because it engages exactly when it matters.

**How it was settled without running the repro.** The 2026-08-12 admission-coverage
commit reproduced it in production on a *second, independent* shape, which is
stronger evidence than the synthetic harness would have produced:

- **H2 (mutate-policy-specific) is dead.** All five stuck policies —
  `require-non-root`, `disallow-host-namespaces`, `disallow-hostpath-volumes`,
  `disallow-privilege-escalation`, `disallow-privileged-containers` — are
  **validate-only**. No `mutate.targets`, no `mutateExistingOnPolicyUpdate`,
  no Kyverno policy-mutating-webhook involvement.
- **H1's conditionality is confirmed by the same sync.** In that one operation the
  three newly-created `-wide` policies and `generate-default-deny-cnp` landed
  perfectly (no live object → no normalisation), and the 21 policies with no real
  rules change stayed Synced. Only the 5 with a genuine rules diff were dropped.
  That is exactly H1's predicted trigger, and it also explains why
  `audit-default-sa-automount` looked like a counter-example on 2026-08-07: it had
  no real rules change pending, so the strip never engaged.
- **Everything else was ruled out by measurement**, not by argument: the CMP
  renders correctly (40/40 docs, selector present, doc set identical to the app's
  tracked resources); the API server *accepts* the exact payload from the
  `argocd-controller` field manager (`kubectl apply --server-side
  --field-manager=argocd-controller --dry-run=server` returns the new selector),
  so no webhook, RBAC denial or ownership conflict is involved; and no second
  Application claims these objects (`core` at `kubernetes/core` is non-recursive
  and manages zero resources). ArgoCD's *diff* path sees the change and reports
  OutOfSync — only the *apply* path loses it, and the sole transform unique to the
  apply path is the `RespectIgnoreDifferences` normalisation.

The repro harness in `SSA-IGNOREDIFFERENCES-REPRO-RUNBOOK.md` was therefore never
run. It is kept for the next in-list-ignore suspicion, not for this one.

**`argocd app diff` IS NOT A DETECTOR FOR THIS. Do not let anyone verify a fix
with it.** With or without `--server-side-generate`, it applies the app's
`ignoreDifferences` normalization to both sides before comparing — the same
normalization that built the bad payload. It reads clean exactly when the app
reads Synced, and both are wrong for the same reason. `selfHeal` is blind for
the same reason: git and live look equal to the thing that made them unequal.

**What detects it:** ask the API server who owns the field. Shipped as the
hourly CronJob `kyverno-ssa-ownership-detector` in
`kubernetes/core/kyverno/manifests/ssa-ownership-detector.yaml`; the same check
by hand is in that file's header.

**Escape hatch after any rules change to a policy:** verify the rule names
landed, and if they did not, re-apply *keeping ArgoCD's ownership*:

```bash
kubectl get cpol <name> -o json | jq '[.spec.rules[].name]'   # vs git
kubectl apply --server-side --field-manager=argocd-controller -f <file>
```

Use that field manager, not a plain `kubectl apply` — a plain apply is what
created variant (4) on this object.

**(4) Stale client-side residue.** A plain `kubectl apply` writes
`kubectl.kubernetes.io/last-applied-configuration` and takes the field with a
`kubectl-client-side-apply`/`Update` entry. Once ArgoCD owns the field again,
strip the residue:

```bash
kubectl annotate <kind> <name> kubectl.kubernetes.io/last-applied-configuration-
```

Do **not** delete-and-recreate a live mutating policy to clean this up — that
opens an admission-mutation gap, however brief.

### The same hazardous combo is on 25 of 63 Applications

Measured 2026-08-07 — Applications pairing `RespectIgnoreDifferences=true` with
an `ignoreDifferences` jqPathExpression that indexes *into a list*:

```bash
kubectl -n argocd get applications -o json | jq -r '
  .items[]
  | select((.spec.syncPolicy.syncOptions//[]) | index("RespectIgnoreDifferences=true"))
  | . as $a
  | [$a.spec.ignoreDifferences[]?.jqPathExpressions[]? | select(contains("[]"))] as $j
  | select(($j|length) > 0)
  | .metadata.name + "  ::  " + ($j|join(" "))'
```

- **1 app** — `core-kyverno-policies`, on `.spec.rules[].skipBackgroundRequests`.
  This is the one that detonated.
- **24 apps** — every ExternalSecret-managing app, on
  `.spec.data[].remoteRef.{conversionStrategy,decodingStrategy,metadataPolicy}`
  (`catalog-infraweaver-console-manifests` additionally on
  `.spec.data[].match.remoteRef.*`). Sources: the four ApplicationSets in
  `kubernetes/bootstrap/appset-*.yaml` + `applicationset-root.yaml`, and the
  per-app files `catalog-gatus-manifests`, `catalog-infraweaver-{api,console,foyer}-manifests`,
  `catalog-jellyfin`, `catalog-nas-shares`, `catalog-nextcloud`.

`ExternalSecret.spec.data` is **also an atomic list** — measured, its CRD schema
declares only `description`, `items`, `type`, with no `x-kubernetes-list-type`.
**So a future change to `spec.data` on an ExternalSecret may silently not
apply, while the Application reports Synced.** The consequence is a Secret that
keeps serving its old value: exactly the failure mode that is hardest to
attribute, because nothing anywhere reports an error.

The detector's ownership logic extends to these directly — same query, with
`f:data` on `externalsecrets` instead of `f:rules` on `clusterpolicies`. Whether
that gets its own backlog entry is an operator decision.

### Rule of thumb

> An `ignoreDifferences` path that contains `[]` is reaching into a list. If
> that list is atomic (no `x-kubernetes-list-type: map` in the CRD), assume the
> whole list can vanish from an SSA payload without any error being reported.
> Prefer pinning the defaulted field explicitly in git over ignoring it.

Check before adding one:

```bash
kubectl get crd <crd> -o json \
  | jq '.spec.versions[] | select(.name=="<ver>") | .schema.openAPIV3Schema.properties.spec.properties.<list> | keys'
# no "x-kubernetes-list-type" -> atomic -> hazardous
```

---

## 8. Migration plan (status)

| # | Item | Status |
|---|------|--------|
| M0 | Console → base/overlays + param seam + dispatch/guard/sync wiring | **done (uncommitted)** |
| M1 | Branch protection on `main` (require `validate-iac` check + 1 review; `enforce_admins=false` so the dispatch admin token still direct-pushes image bumps) | **APPLIED on GitHub.** Required check turns green once the workflow lands on `main`. |
| M2 | api + node → base/overlays (api drops `replicas`→HPA; node keeps `replicas`, no HPA) | **done (uncommitted)** |
| M3 | Image automation | **Decision: KEEP dispatch `/approve` git-write-back** (it commits+pushes the pin = GitOps-correct, and is *approve-gated*). ArgoCD Image Updater **intentionally not adopted** — it does continuous *ungated* auto-deploy, conflicting with the approve-gated model. |
| M4 | Single authoritative ArgoCD remote (GitHub vs OneDev) | **Staged — not a safe quick repoint.** GitHub infra has only 2 `platform/*/application.yaml` vs many served from OneDev, so repointing now would drop live apps. Steps: (1) copy missing `platform/`+`monitoring/` `application.yaml`+`values.yaml` from the OneDev platform repo into this repo, (2) `validate-iac`, (3) repoint the 4 appsets' `repoURL` OneDev→GitHub, (4) confirm generated app count unchanged, (5) keep OneDev as a read mirror. |
| M5 | Raw Secrets → ESO / inline | **done:** `onedev-db-secret` → ExternalSecret (OpenBao `secret/platform/onedev` seeded with the exact existing creds, so postgres is unaffected on restart); calibre `OAUTHLIB_RELAX_TOKEN_SCOPE` inlined as a literal; secret-leak baseline now empty. |

---

## 9. Quick reference

```sh
# Validate everything the way CI does:
scripts/validate-iac.sh             # render + schema + secret-leak gate
scripts/validate-netpol-ports.sh    # NetworkPolicy ports must be POD ports, not Service ports

# Render what ArgoCD will apply for an app:
kubectl kustomize kubernetes/catalog/<app>/overlays/prod

# Iterate locally without touching cluster truth:
mkdir -p kubernetes/catalog/<app>/overlays/local   # gitignored
kubectl apply -k kubernetes/catalog/<app>/overlays/local
```
