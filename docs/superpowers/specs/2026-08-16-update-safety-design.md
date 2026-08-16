# Update Safety System — design

**Status:** approved 2026-08-16. Supersedes nothing; this is the first design for
this surface.

**Problem owner's requirement, verbatim:** "implement a permanent fix that is user
proof so he can update everything at a time without things failing."

---

## The incident this exists to make impossible

On 2026-08-16 an operator pressed "Update all" in `/admin/updates`. It committed
ten Helm chart bumps at once and ArgoCD auto-synced them:

| Component | From | To | Why it was wrong |
|---|---|---|---|
| longhorn | 1.7.3 | 1.12.1 | Five minors in one step. Upstream supports sequential minors only. |
| kyverno | 3.2.8 | 3.9.0-rc.3 | A **release candidate** admission controller. |
| cilium | 1.17.4 | 1.21.0-pre.0 | A **pre-release** CNI. |
| argocd, traefik, openbao, kube-prometheus-stack, external-secrets | | | Committed simultaneously with all of the above. |

Eight were then reverted with `git revert`. **The revert caused more damage than
the upgrade.**

- **Longhorn cannot be downgraded.** 1.12 had already migrated its settings and
  CRD content. The 1.7.3 manager died with `fatal error: fault` — a segfault, not
  a recoverable panic — crashlooping `longhorn-manager`, `longhorn-csi-plugin`
  and `csi-snapshotter`, which left Prometheus and Alertmanager stuck in `Init`
  waiting on volumes. Recovery was to roll *forward* to 1.12.1. No data was lost:
  all 33 volumes stayed attached and healthy, because existing engine processes
  keep serving while the manager is down.
- **Kyverno is still broken.** The rc.3 chart moved the
  `globalcontextentries.kyverno.io` CRD storage version to `v2beta1`. Applying
  3.2.8 back is rejected by the apiserver:
  `status.storedVersions[0]: Invalid value: "v2beta1": missing from spec.versions`.
  `core-kyverno` has been in `SyncError` since.
- **Orphans nobody prunes.** `prune: false` on the core apps means version churn
  leaves resources behind forever: `Role`/`RoleBinding` `cilium-operator-ztunnel`
  in `kube-system` still labelled `helm.sh/chart: cilium-1.21.0-pre.0`, and
  `Service/longhorn-conversion-webhook` labelled `longhorn-1.7.3` with zero
  backing endpoints while every `longhorn.io` CRD still declares
  `spec.conversion.strategy: Webhook` pointing at it.

The lesson, written into the recovery commit:

> A revert is not a safe undo for a stateful component that migrates on upgrade.
> The update surface must refuse to move longhorn across minors in one step, and
> must refuse to offer a one-click revert for anything that migrates.

## Decisions taken before design

1. **Guard mode: auto-stage into safe hops.** The button never simply refuses a
   legal-but-large upgrade. It computes the legal chain and runs it one gated hop
   at a time. Unsafe single jumps become impossible; the operator still presses
   one button.
2. **Kyverno recovery direction: forward to 3.8.2 stable**, not back to 3.2.8 —
   the same shape as the Longhorn recovery, and the first real user of the staged
   hop machinery.

---

## 0. Design in one page

**Model.** A static, code-reviewed policy registry in the API
(`src/config/update-policies.ts`, sibling of `version-sources.ts`): per-component
`tier`, `hop` rule and `reversibility`. Unclassified components get a safe default
(single step within one major, reversibility *unknown*, never in a critical wave).
A CI test forces every `core/` app to be explicitly classified.

**Enforcement point.** The Hono route `apps/infraweaver-api/src/routes/updates.ts`
— the only code path that writes `targetRevision` to git. `POST /updates/:appName`
itself gains the guards (illegal hop, pre-release, downgrade-of-forward-only,
wildcard), so *every* caller is protected: bulk or single, UI or curl. New sibling
routes compute plans and execute gated, durable, server-side runs. The console
adds comprehension, never enforcement.

**Operator-visible behavior.** "Update all" becomes *plan → preview → run*. The
preview shows waves, per-app hop chains (longhorn: five gated hops, not one jump)
and a "one-way — cannot be reverted" marker on migrating components *before* the
hold-to-confirm. The run executes server-side: standard apps in parallel, critical
apps one per wave with health gates that require the deployed chart version to
actually equal the target (`.status.sync.revisions[1]`), not merely "Healthy". Any
failure halts promotion; remaining items become `skipped` with the reason; nothing
is ever auto-reverted; a page refresh or closed laptop loses nothing.

The incident becomes impossible at three independent layers: the rc/pre-release
cannot be *selected* (shipped), cannot be *committed* (POST guard), and the
five-minor longhorn jump and the kyverno revert are refused at that same guard.

---

## 1. Policy model

New file `apps/infraweaver-api/src/config/update-policies.ts`:

```ts
export interface UpdatePolicy {
  tier: 'critical' | 'standard';
  /** How far one commit may move the chart version. */
  hop:
    | { kind: 'sequential-minor'; maxStep: number }   // longhorn: 1
    | { kind: 'within-major' }                        // default: minors ok, no major crossing
    | { kind: 'free' };                               // traefik-style chart-major churn
  reversibility: 'reversible' | 'forward-only' | 'unknown';
  /** Critical-wave ordering; lower runs earlier. Standard apps have none. */
  wave?: number;
  /** Human sentence shown in the plan. */
  note?: string;
  docUrl?: string;
}
```

Longhorn is `sequential-minor maxStep 1`, `forward-only`, wave 50. Kyverno is
`within-major`, `forward-only`, wave 30 ("owns CRD storage versions"). ArgoCD is
`within-major`, `reversible`, wave 90. Cilium is excluded from bulk entirely
(see §3). The default for anything unclassified is
`{ tier: 'standard', hop: { kind: 'within-major' }, reversibility: 'unknown' }`.

**Why a static registry, not the alternatives.**

- *Annotations on `application.yaml`*: policy would live in a different repo,
  spread across 69 files, unreviewable as a set and — decisive — untestable from
  this codebase. The registry gets table-driven unit tests; annotations get vibes.
- *Derived/inferred*: nothing in any API says "longhorn migrates on upgrade".
  Inference produces confident wrongness, the worst possible property for a
  safety system.

**Maintainability.** Adding a component adds one line, in the same PR pattern as
`VERSION_SOURCES`. The "nobody classified the new storage engine" hole is closed
twice: by the safe default, and by a new test that fails if any `core/` section
app lacks an explicit entry — the repo's existing ratchet idiom.

**Default rationale (a deliberate trade).** Strict sequential-minor as the default
is safest but absurd for chart-major-churning repos: an unclassified traefik-alike
would demand seven hops. `within-major` is where vendors put breaking changes by
convention, and the known minor-sequential exceptions are classified explicitly.
Rejected: a `free` default — that is exactly the pre-incident behavior.

## 2. Upgrade-path computation

New pure module `apps/infraweaver-api/src/lib/update-plan.ts`:

```ts
planHops(current: string, target: string, available: string[], policy: UpdatePolicy):
  | { ok: true; hops: string[] }            // ['1.8.2','1.9.4','1.10.3','1.11.2','1.12.1']
  | { ok: false; code: 'MISSING_HOP' | 'NOT_SEMVER' | 'PRERELEASE_TARGET' | 'DOWNGRADE'; detail: string }
```

Intermediate versions come from the already-fetched Helm index: group stable
versions by `(major, minor)` and take the highest patch of each minor between
current and target. `sequential-minor` walks every minor; `within-major` emits one
hop per major boundary; `free` emits `[target]`.

Skip-level rules are **data, not vendor code**. `maxStep` expresses "Longhorn
supports only sequential minors"; a vendor blessing N-minor jumps gets
`maxStep: N`. There is no per-vendor logic anywhere.

Non-semver revisions (git branches on raw apps) return `NOT_SEMVER` and are
excluded from bulk; single-apply remains available with explicit confirmation.

### Two latent bugs that must be fixed first

- **`extractHelmChartVersions` returns `.slice(0, 15)` newest-first**
  (`updates.ts:280`). Longhorn's 1.8–1.11 hops fall outside the top 15, so the
  planner would refuse legal paths. The planner must consume the **unsliced**
  list; keep the slice only in the `GET /versions` display response.
- **`getCurrentVersion` never reads `.status.sync.revisions[1]`**
  (`updates.ts:153`), so two-source Helm apps report the values-repo git SHA
  instead of the deployed chart version — poisoning "already up to date" and every
  gate built on it. Port the `revisions` handling that `update-manager.ts` already
  models.

## 3. Ordering and batching

A run is a sequence of **waves**; a wave must fully pass its gates before the next
commits anything.

- **Wave 0 — all standard apps**, committed and gated in parallel (concurrency 3,
  matching `runItems`). Lowest blast radius first also proves the pipeline before
  anything dangerous moves.
- **Then one wave per critical app**, ascending `wave`: external-secrets/openbao →
  kyverno → longhorn → **argocd last**. If the GitOps engine breaks, it breaks
  after everything else has already rolled, and the halt is natural.
- **A multi-hop chain is one wave per hop**, each fully gated. Longhorn
  1.7.3 → 1.12.1 is five gated waves.
- **Never in the same run: the CNI.** Cilium is hard-excluded from bulk and is
  single-apply only with its own confirmation, because a bad CNI can partition the
  cluster out from under the very health checks this system depends on. Rejected:
  putting cilium in a final wave — a gate that cannot reach the apiserver cannot
  gate.

At most one critical component is ever in flight, by construction.

## 4. Health gating

New pure module `src/lib/update-gate.ts` for evaluation, plus a poller in the
runner. After each commit, poll the single app with a fresh
`GET /api/v1/applications/:name` — **not** the 60s `argoAppsCache` — every 15s.
The gate passes only when all of the following hold on **two consecutive polls**
(`selfHeal: true` makes single-sample reads flap):

1. `deployedChartVersion(app) === hopTarget`, where deployed is
   `status.sync.revisions[1]` for two-source apps and `status.sync.revision`
   otherwise. **This is the primary fact**; the rest is corroboration.
2. `status.sync.status === 'Synced'`
3. `status.health.status === 'Healthy'`
4. `status.operationState.phase === 'Succeeded'` — **this is what catches the
   false green.** `core-kyverno` is `OutOfSync` + `Healthy` right now while
   `operationState` carries the SyncError. `getSyncStatus()` in `updates.ts`
   conflates these, so the gate must not reuse it.
5. No `status.conditions[]` of type `SyncError` / `ComparisonError`.
6. Longhorn waves additionally require every Longhorn volume to be neither
   `degraded` nor `faulted`.

Timeouts: 5 minutes standard, 15 minutes per critical hop. Timeout or hard failure
marks the item `failed` with the gate's last evaluation as its message. Any
`failed` halts wave promotion: in-flight wave-0 siblings finish, everything not
yet attempted becomes `skipped("halted: longhorn failed health gate")` — the
existing outcome vocabulary expresses this exactly.

**What a halted run leaves behind.** Commits already made stand — git is truth and
auto-revert *is* the incident. The persisted ledger records precisely which apps
moved and which were never attempted, and the page shows a halt banner naming the
failed gate. Resuming means re-planning and starting a new run.

## 5. Preflight

Evaluated server-side at plan time and re-evaluated at run start. Hard blockers,
each machine-readable as `{code, message, apps[]}`:

- `RUN_IN_FLIGHT` — the shared-state claim is held.
- `FLEET_NOT_CLEAN` — any critical app, or any app in the plan, has op-phase
  `Error`/`Failed` or a SyncError condition. A benign-OutOfSync allowlist lives in
  the policy file. **Today this fires on `core-kyverno`, correctly**: you do not
  bulk-update a fleet whose admission controller is mid-wreck.
- `STORAGE_DEGRADED` — any Longhorn volume degraded or faulted.
- `VERSION_UNKNOWN` — an app in the plan whose upstream list could not be fetched.
  Unknown is not eligible; this is S8 at plan scale.
- `PLAN_DRIFT` — the `planHash` submitted at run start no longer matches a
  recomputation.

Soft warnings, shown but not blocking: no recent Longhorn backup for attached
volumes; any node NotReady. Backup recency is deliberately **not** a hard gate — a
stale-backup false positive that blocks all updates forever is how guards get
disabled.

## 6. Reversibility, and what replaces "revert"

- The POST guard refuses any version decrease for `forward-only` and `unknown`
  components: `422 { code: 'FORWARD_ONLY', message: 'longhorn migrates data on
  upgrade; recovery is forward-only. Reverting the GitOps commit will crashloop
  the manager.' }`. Kyverno `3.9.0-rc.3 → 3.2.8` is this exact case.
- For `reversible` components, "go back" is just an update through the same guard
  and gates. No special revert path exists at all.
- **Escape hatch:** `{ override: { reason: string } }` on single-app POST only,
  never bulk, same `platform:update` permission, logged. A safety system with no
  override gets bypassed via raw git, which is strictly worse than an audited
  override.
- **Communicated before, not after:** the update card and the plan preview render
  a "one-way" badge and the policy note on every forward-only app, adjacent to the
  hold-to-confirm target text.
- **Known gap, stated honestly:** an operator running `git revert` in the infra
  repo bypasses all of this. A later CI check in that repo refusing
  `targetRevision` decreases on forward-only paths would close it; out of scope
  here. The halt banner and docs say "do not git revert — come back to this page".

## 7. Where enforcement lives

All guards live in the API, inside `POST /updates/:appName`, before
`updateManifestVersion`. Reasons: the console is one of several callers (its proxy,
curl with a token, future automations); the console-side rate limit already
demonstrates that console-only controls do not bind the API; and the per-row
single-app button uses this same route, so bulk-only enforcement would leave the
incident reproducible one click at a time.

The guard needs no network. Hop legality, pre-release, downgrade and wildcard
(`1.7.*` is now refused — pins are exact) are all computable from
`(current, requested, policy)`.

The UI adds plan preview, one-way markers, refusal rendering and the ledger. It
never adds permission.

## 8. Run state and durability

The API already has the right primitive: `src/lib/shared-state.ts`, a ConfigMap
CAS store in `infraweaver-system`, built because the service runs 1–5 replicas.
New module `src/lib/update-run.ts`:

- One document `update-run-current`:
  `{ id, planHash, phase, waves, items[], currentWave, startedAt, heartbeatAt, owner }`.
  Creating it via CAS **is** the run mutex.
- The executor is a plain async loop in the API process, heartbeating into the doc
  every poll. Every step is idempotent: "commit hop" re-checks the manifest first
  (the existing 409 "Version already set" becomes `already`), and "gate" is a pure
  read. Crash recovery is therefore trivial: any replica serving
  `GET /updates/run/current` that finds `heartbeatAt` staler than 2 minutes adopts
  the run via CAS and resumes from `currentWave`. No queue, no CronJob, no workflow
  engine — this is 69 apps and one operator.

Routes, all `platform:update`:

- `POST /updates/plan` → `{ planHash, waves[], refusals[], blockers[], warnings[] }`
  (read-only).
- `POST /updates/run { planHash }` → `202 { runId }`, or `409` with blockers.
- `GET /updates/run/current` → the full document; the client polls this.
- `POST /updates/run/current/abort` → finish the in-flight item, skip the rest.

Console proxies live at `src/app/api/updates/plan/route.ts` and `run/…` via
`withRoute(perm, handler, { rootScope: true })` — **no ratchet movement, no new
dashboard route, no new nav row.** Everything renders inside `/admin/updates`.

Client: `handleUpdateAll` becomes plan-sheet → `POST run` → poll `run/current`,
feeding the existing `RunLedger` (wave and gate progress via `ItemRun.step`, e.g.
`"gate: waiting for Healthy · 3m"`) and `notifyRunVerdict` at the end. On mount the
page rehydrates any active run, so refresh, pod restart and closed laptop are all
safe. NDJSON streaming is deliberately **not** used here: polling a persisted
document is simpler and the document is the source of truth anyway. `ndjson.ts`
stays for the WordPress sweeps, which are genuinely request-scoped.

## 9. Testing strategy

Pure modules first — they carry the safety property and reach the 80% threshold
easily. Tests are colocated per repo pattern (`src/lib/update-plan.test.ts`,
`src/routes/updates-guard.test.ts`); console jest runs at `--maxWorkers=1`.

Table-driven cases derived from the real incident:

| # | Case | Expect |
|---|---|---|
| 1 | longhorn `1.7.3 → 1.12.1`, full index | hops `[1.8.x, 1.9.x, 1.10.x, 1.11.x, 1.12.1]`, highest patch per minor |
| 2 | same, index missing all 1.9.x | `MISSING_HOP`, names the gap |
| 3 | POST longhorn `1.12.1` from `1.7.3` | 422 `ILLEGAL_HOP` with `requiredPath` in the body |
| 4 | kyverno versions topped by `3.9.0-rc.3` | rc never selected; POST of it → 422 `PRERELEASE` (the server re-checks; the GET filter is not the enforcement) |
| 5 | kyverno `3.9.0-rc.3 → 3.2.8` | 422 `FORWARD_ONLY` — the revert that is still broken today |
| 6 | same with `override.reason` | 200, audited |
| 7 | gate fixture: `OutOfSync` + `Healthy` + opState `Error` (real `core-kyverno` status) | gate **fails** — the false-green case |
| 8 | gate fixture: Synced + Healthy + Succeeded but `revisions[1] !== target` | gate fails (rolled the wrong thing) |
| 9 | two-source vs single-source deployed-version extraction | `revisions[1]` / `revision` respectively |
| 10 | unclassified app `2.3.1→2.9.0` / `2.9.0→3.1.0` | allowed single-hop / `MAJOR_CROSSING` in bulk |
| 11 | POST `1.7.*` | 422, wildcard refused |
| 12 | preflight matrix including `RUN_IN_FLIGHT` and a benign ignored OutOfSync | correct blockers |
| 13 | executor document mid-wave-2 with a stale heartbeat | adoption resumes, no re-commit (`already`) |

On predicting the kyverno CRD storage-version conflict: we deliberately **do not**
build CRD diffing between chart versions — heavy, vendor-specific, YAGNI. Both
actual causes are covered structurally: the rc could never be selected or committed
(#4), and the harmful revert is refused (#5). "Survived, by construction" is the
honest claim, and the suite encodes it.

## 10. Rollout

- **Phase 0 (ship first, no UI change):** guards inside `POST /updates/:appName`,
  the `revisions[1]` fix, and the unsliced internal version list. The existing page
  keeps working, and per-row and bulk presses are now individually safe. **The
  incident is already impossible after this phase.**
- **Phase 1:** `POST /updates/plan` plus the plan-preview sheet. "Update all" runs
  wave-0 apps through the existing client `runItems`; critical apps are listed but
  deferred with "needs the guided runner" — visible, not silently dropped.
- **Phase 2:** the server-side runner, gates and durable document; critical apps
  become one-click through waves. Client `runItems` orchestration for updates
  retires.
- **Phase 3:** a read-only **orphan report** on the page — resources whose
  `helm.sh/chart` label version differs from the app's deployed version. This is
  exactly how the cilium and longhorn leftovers were found. Report only;
  `prune: false` is deliberate and auto-deleting is out of scope.

## 11. Traps and open uncertainties

1. **The 15-version slice** silently amputates hop candidates. Must be fixed or the
   planner refuses legal longhorn paths.
2. **`getSyncStatus` / `getCurrentVersion` are unsafe for gating.** Both conflate
   the exact states the incident produced; the gate uses its own evaluator.
3. **`selfHeal: true` flapping** — hence two-consecutive-poll stability plus
   deadlines. A single green sample lies.
4. **Chart versus app versioning.** Hop rules act on the *chart* series; for
   kube-prometheus-stack-style charts a chart-major bump is routine. That is why
   `within-major` blocks bulk but permits a confirmed single-apply rather than
   refusing outright. Confidence in this default is roughly 80%; the registry makes
   it a one-line change per component.
5. **Raw git bypasses everything.** The console can only make the safe path the
   easy path.
6. **Multi-replica adoption** is the least-exercised code path. Test #13 exists
   precisely because it would otherwise only ever run during a real outage.
