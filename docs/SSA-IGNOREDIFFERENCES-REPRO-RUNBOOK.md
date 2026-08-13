# Runbook: reproduce the silent SSA payload strip (2026-08-07)

> **SUPERSEDED 2026-08-13 — DO NOT RUN THIS FOR THE 2026-08-07 INCIDENT.**
> **H1 was confirmed in production**, and H2 ruled out, by the 2026-08-12
> admission-coverage commit: five **validate-only** policies (no mutate shape at
> all) showed the full signature in one sync, while newly-created policies and
> policies without a real rules change synced correctly in that same sync — H1's
> exact predicted trigger. The fix from §4 is applied: `skipBackgroundRequests`
> is pinned on every rule, and `.spec.rules[].skipBackgroundRequests` is gone from
> `kubernetes/bootstrap/core-kyverno-policies.yaml`. Evidence and the full
> rule-out list are in [`gitops-operating-model.md` §7.1](./gitops-operating-model.md).
> Keep this document for the *next* in-list-ignore suspicion — the §3 phase
> structure and the §1 safety envelope are the reusable parts.

**Status: WRITTEN, NOT RUN.** This creates live ArgoCD Applications and live
ClusterPolicies. It is deliberately not bundled with any production sync.
Execute it as its own attended session, then tear it down in the same session.

**Purpose:** discriminate *why* the 2026-08-07 sync of `core-kyverno-policies`
reported `serverside-applied` for `ClusterPolicy/mutate-default-sa-automount`
while omitting `spec.rules` from the payload. Background, evidence, and the
managedFields diagnostic: [`gitops-operating-model.md` §7.1](./gitops-operating-model.md).

**Do this BEFORE changing `ignoreDifferences` on `core-kyverno-policies`.** The
two candidate causes need different fixes, and the "obvious" fix — removing
`.spec.rules[].skipBackgroundRequests` from the ignore list — has a real
activation hazard of its own (§4 below). Guessing here costs more than measuring.

---

## 0. The two hypotheses

| | Hypothesis | Fix if confirmed |
|---|---|---|
| **H1** | In-atomic-list `ignoreDifferences` under `RespectIgnoreDifferences=true` + SSA. `.spec.rules[].skipBackgroundRequests` reaches inside an atomic list; stripping an ignored path from an atomic list drops the whole list from the payload. Conditional — engages only when live and desired rules differ beyond the ignored subfield, i.e. exactly when a real rules change is pending. | Config we own. Remove the in-list ignore, pin `skipBackgroundRequests` explicitly in git. |
| **H2** | Something specific to the *mutate* policy shape — rules carrying `mutate.targets` + `mutateExistingOnPolicyUpdate`, interacting with Kyverno's policy-mutating webhook. | Not ours. Find/file the upstream ArgoCD issue (v3.4.4), keep `ignoreDifferences`, rely on the detector + the documented escape hatch. |

Why H1 is not already proven: the sibling `audit-default-sa-automount`, in the
**same Application** and under the **identical** ignore config, had its full spec
including `f:rules` applied at 14:39:28Z the same afternoon.

---

## 1. Safety envelope

Everything below is inert by construction:

- Test policies are `validationFailureAction: Audit` — they cannot block admission.
- They match **only** ConfigMaps whose name starts `repro-p27-canary-`. Nothing
  on this cluster creates such an object, so the policies never evaluate anything.
- The scratch Application is created **directly with `kubectl apply`**, NOT added
  under `kubernetes/bootstrap/`. The app-of-apps therefore neither adopts nor
  prunes it, and cannot reconcile its `syncPolicy` back. (Adding it to bootstrap
  is the documented way to lose control of it — a bootstrap-tracked app's paused
  selfHeal does not stick.)
- The `platform` AppProject already whitelists cluster-scoped resources
  (`clusterResourceWhitelist: [{group: "*", kind: "*"}]`) and this repo, so no
  project change is needed. **Do not edit the AppProject for this.**
- No production workload, no OpenBao, no restarts.

**Blocked without separate human approval:** setting `controller.log.level=debug`
in `argocd-cmd-params-cm`. It restarts the ArgoCD application controller, during
which selfHeal is paused cluster-wide. Only if Phase B/C is ambiguous, never
during a sync wave, and revert immediately after.

---

## 2. Create

### 2.1 Branch and manifests

Branch `repro/p27-ssa-ignorediff` off `main`. Never merged; deleted in teardown.
One new directory `kubernetes/repro-p27/`, two files.

`kubernetes/repro-p27/repro-p27-validate.yaml` — **v1 (one rule):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: repro-p27-validate
spec:
  validationFailureAction: Audit
  admission: true
  background: true
  rules:
    - name: canary-rule-one
      match:
        any:
          - resources:
              kinds: [ConfigMap]
              names: ["repro-p27-canary-*"]
      validate:
        message: "inert canary rule one"
        pattern:
          metadata:
            labels:
              repro-p27/one: "?*"
```

`kubernetes/repro-p27/repro-p27-mutate.yaml` — **v1 (one rule)**, mirroring the
failing shape (`mutateExistingOnPolicyUpdate: false`, a rule with
`mutate.targets`):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: repro-p27-mutate
spec:
  admission: true
  background: true
  mutateExistingOnPolicyUpdate: false
  rules:
    - name: canary-mutate-one
      match:
        any:
          - resources:
              kinds: [ConfigMap]
              names: ["repro-p27-canary-src-*"]
      mutate:
        targets:
          - apiVersion: v1
            kind: ConfigMap
            name: repro-p27-canary-tgt
            namespace: kyverno
        patchStrategicMerge:
          metadata:
            labels:
              repro-p27/one: "yes"
```

> The mutate policy needs the background controller to hold write access on its
> target kind, or Kyverno refuses the policy at admission. ConfigMap write is
> already in the chart's `:core` background-controller role — verify before
> pushing, and if it is not, **stop**: do not add RBAC for a throwaway.
> ```bash
> kubectl auth can-i update configmaps --as=system:serviceaccount:kyverno:kyverno-background-controller
> ```

### 2.2 Scratch Application

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: repro-p27-ssa
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]   # deletion cascades to the test cpols
spec:
  project: platform
  source:
    repoURL: https://github.com/example-owner/InfraWeaver-infra
    targetRevision: repro/p27-ssa-ignorediff
    path: kubernetes/repro-p27
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated: {selfHeal: true}          # no prune needed
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: kyverno.io
      kind: ClusterPolicy
      jqPathExpressions:
        - '.status'
        - '.spec.admission'
        - '.spec.rules[].skipBackgroundRequests'
EOF
```

`repoURL` is the literal live value (measured on `core-kyverno-policies`). Do
**not** write `${DEPLOY_REPO_URL}` — the CMP envsubst plugin only runs on the
bootstrap path, and this app is applied directly.

---

## 3. Measure

Record `kubectl get cpol <p> -o json --show-managed-fields` for both policies at
every phase. Archive the dumps; they are the evidence.

**The single question at each phase:**

```bash
for p in repro-p27-validate repro-p27-mutate; do
  echo "== $p"
  kubectl get cpol "$p" -o json --show-managed-fields \
    | jq '{rules: [.spec.rules[].name],
           owners: [.metadata.managedFields[]
                    | {manager, operation, time, spec: (.fieldsV1["f:spec"] | keys)}]}'
done
kubectl -n argocd get application repro-p27-ssa -o json \
  | jq '{sync: .status.sync.status, phase: .status.operationState.phase,
         finishedAt: .status.operationState.finishedAt,
         msgs: [.status.operationState.syncResult.resources[]?.message]}'
```

**Phase A — creation.** Push v1, let it sync. Expect `argocd-controller` owns
`f:rules` on both. (Creation always worked in production; this is the control
that the harness itself is sound. If Phase A already fails, the repro is
mis-built — fix it before reading anything into Phase B.)

**Phase B — the incident shape.** Push **v2**: add a second rule to each policy
(`canary-rule-two` / `canary-mutate-two`, same shape as rule one with a `two`
label). Let auto-sync run. Then ask:

1. Does the live policy have rule 2?
2. Does the app report `Synced` + `serverside-applied`?
3. Did `argocd-controller`'s fieldset keep/gain `f:rules`, and did its `time`
   move past the sync's `finishedAt`?

> **REPRO SUCCEEDS** if either policy shows the 2026-08-07 signature:
> **Synced + serverside-applied + missing rule 2 + no `f:rules` under
> `argocd-controller`, whose timestamp did not move.**
> Note *which* policy — validate-only, mutate-shaped, or both. If only the
> mutate one reproduces, that is evidence for H2 even before Phase C.

**Phase C — the control.** Edit the scratch app to drop
`.spec.rules[].skipBackgroundRequests` from `ignoreDifferences` (keep `.status`
and `.spec.admission` — scalar ignores demonstrably do not trigger the strip;
`argocd-controller` still owns `f:admission` on both production automount
policies). Force a hard refresh, re-sync, re-measure:

```bash
kubectl -n argocd annotate application repro-p27-ssa argocd.argoproj.io/refresh=hard --overwrite
```

- **Rule 2 now lands → H1 CONFIRMED.**
- **Rule 2 still does not land → H1 ruled out.** Move to controller logs /
  upstream ArgoCD (v3.4.4); ship detector-only.

---

## 4. If H1 is confirmed — the fix, and its mandatory gate

Two commits, in this order, so each reverts alone:

**Commit 1 — pin the defaulted field.** In every ClusterPolicy under
`kubernetes/core/kyverno/manifests/`, add explicit `skipBackgroundRequests:
<live value>` to every rule. Dump the live values verbatim; **do not assume they
are all `true`** (only 4 rules were measured):

```bash
kubectl get cpol -o json | jq -r '.items[] | .metadata.name + ": "
  + ([.spec.rules[] | .name + "=" + (.skipBackgroundRequests|tostring)] | join(", "))'
```

Let this sync **under the old `ignoreDifferences`**. It is a semantic no-op —
live already has those values.

**Commit 2 — remove the in-list ignore.** Drop only the
`.spec.rules[].skipBackgroundRequests` line from
`kubernetes/bootstrap/core-kyverno-policies.yaml`. Keep `.status` and
`.spec.admission`.

> ### The pre-sync gate for commit 2 is NOT OPTIONAL
>
> Removing the ignore makes ArgoCD re-send `spec.rules` for all 23 policies,
> which **activates every silently-dropped rules change that ever happened** —
> the P2.7 failure inverted, all at once. Before letting it sync, for every
> manifest file:
>
> ```bash
> kubectl diff --server-side --field-manager=argocd-controller -f <file>   # dry-run, read-only
> ```
>
> (envsubst the files using `${...}` vars first.) Server-side dry-run passes
> through Kyverno's defaulting webhook, so defaulted fields do not appear as
> noise. Review **every hunk as a change about to go live**. Anything beyond the
> intended `skipBackgroundRequests` pins → stop and account for it. This output
> is the authorization artifact for the commit.

**Then clean the incident artifact.** Once commit 2 has synced, confirm
`argocd-controller` re-owns `f:rules` on `mutate-default-sa-automount` (values
are equal, so SSA takes co-ownership without conflict), then strip the residue:

```bash
kubectl annotate clusterpolicy mutate-default-sa-automount \
  kubectl.kubernetes.io/last-applied-configuration-
```

**Do NOT delete-and-recreate the policy to clean this up** — deleting a live
mutate policy opens an admission-mutation gap, however brief.

**Verification of success — the real one.** Not "the app says Synced":

```bash
# 23/23 owned by argocd-controller/Apply
kubectl get clusterpolicies -o json --show-managed-fields | jq -r '.items[]
  | {n:.metadata.name, o:[.metadata.managedFields[]
      | select((.fieldsV1["f:spec"]["f:rules"]?) != null) | .manager + "/" + .operation]}
  | select(.o != ["argocd-controller/Apply"]) | .n'     # expect: empty
kubectl get cpol mutate-default-sa-automount -o json | jq '[.spec.rules[].name]'  # both rules
```

Then **verify the control SUCCEEDED**: make one deliberate real rules edit to an
Audit policy in git (e.g. add an excluded namespace) and confirm it materializes
in the live object within one sync. That is the only proof that matters.

If a future Kyverno chart upgrade changes the `skipBackgroundRequests` default,
the explicit pins go visibly OutOfSync. **That is the designed loud failure.**
Update the pins; do not re-add the in-list ignore.

---

## 5. Teardown — same session, no exceptions

```bash
kubectl delete application repro-p27-ssa -n argocd     # finalizer cascades to the cpols
kubectl get cpol | grep repro-p27                       # expect: no output
kubectl get clusterpolicies -o name | wc -l             # expect: back to 23
git push github --delete repro/p27-ssa-ignorediff
git branch -D repro/p27-ssa-ignorediff
```

If `controller.log.level=debug` was set in §1, revert it now (this restarts the
application controller again — same approval, same care).

Nothing else was created. `kubernetes/repro-p27/` never reaches `main`.

---

## 6. Rollback

| Step | Rollback |
|---|---|
| Repro | Teardown above. Deleting the Application cascades to both inert policies. |
| Fix commit 1 (pins) | Revert. Live values are unchanged either way — they mirror webhook defaults, so there is no cluster impact. |
| Fix commit 2 (ignore removal) | Revert re-adds the ignore line; behaviour returns to today's, including the hazard. |
| Detector CronJob | Delete the manifest from `kubernetes/core/kyverno/manifests/`; the app prunes it. |
