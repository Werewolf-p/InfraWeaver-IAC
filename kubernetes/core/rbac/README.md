# `kubernetes/core/rbac/` — scoped automation identity (GAP-C3)

Closes **GAP-C3** from the compliance plan: a standing, non-expiring
`cluster-admin` credential that exists outside GitOps.

| | |
|---|---|
| Controls | CIS 5.1.1 / 5.1.5, SOC 2 CC6.1 / CC6.3, ISO 27001 A.5.15, A.8.2 |
| Replaces | SA `infraweaver-system/claude-platform-owner` + ClusterRoleBinding `claude-platform-owner` → `cluster-admin` |
| With | SA `infraweaver-system/automation-harness` + ClusterRole `automation-harness` (read-only + one enumerated write verb) |

---

## 1. What was wrong

Verified live on 2026-08-07:

* ServiceAccount `infraweaver-system/claude-platform-owner` is bound to
  `cluster-admin` by ClusterRoleBinding `claude-platform-owner`
  (created `2026-06-29T04:05:47Z`, labels `app.kubernetes.io/managed-by:
  claude-temp`, `infraweaver.io/removable: "true"`, **no `ownerReferences`, no
  ArgoCD tracking annotation** → not managed by anything).
* No YAML in this repository defines it. It was created with `kubectl apply` by
  hand: the object carries a `kubectl.kubernetes.io/last-applied-configuration`
  annotation but has no `argocd.argoproj.io/tracking-id`.
* Secret `infraweaver-system/claude-platform-owner-token`
  (`kubernetes.io/service-account-token`, created `2026-06-29T04:05:47Z`) is a
  **static token that never expires**. It was confirmed still valid: it
  authenticates as `system:serviceaccount:infraweaver-system:claude-platform-owner`,
  and it is byte-identical to the token embedded in
  `~/.kube/config-claude-platform-owner` on the operations host and mirrored into
  OpenBao at `secret/platform/claude-platform-owner`.
* No pod in the cluster uses this ServiceAccount.

A credential with all of those properties at once — cluster-admin, unmanaged,
non-expiring, copied to at least three places — is the single highest-value
target on the platform and cannot be evidenced under any of the three
frameworks.

## 2. What replaces it

`automation-harness-clusterrole.yaml` is **read-only across the resources the
compliance audit actually reads**, plus exactly one write verb (`delete` on
`pods`, justified inline in the manifest).

The manifest carries a `DELIBERATELY ABSENT` block listing every grant that was
considered and rejected. The four that matter most:

| Not granted | Why |
|---|---|
| `secrets` (any verb) | `get`/`list` returns plaintext. A role that can read all Secrets is cluster-admin with extra steps — it yields the ArgoCD admin token and every OpenBao-materialised credential. Secret posture is evidenced through `external-secrets.io` objects and PolicyReports instead. |
| `serviceaccounts/token` (`create`) | Cluster-scoped token minting mints tokens for *any* SA, including `argocd-application-controller` (`*` on `*/*`). It also lets the identity renew itself forever, defeating expiry. |
| `escalate`, `bind`, `impersonate` | Each is a direct route back to cluster-admin. |
| write on `apps/*` and `argoproj.io/applications` | Patching a Deployment image, or an Application's `repoURL`, is arbitrary code execution in the cluster. All changes go through pull requests; ArgoCD syncs them (`selfHeal: true`). |

API discovery and `kubectl auth can-i` are **not** restated in the role — every
authenticated principal already has them via the built-in `system:discovery` and
`system:basic-user` ClusterRoleBindings.

## 3. Minting a credential — the only supported procedure

**Short-lived tokens only. Never create a `kubernetes.io/service-account-token`
Secret.** Doing so re-opens GAP-C3 exactly as it was.

```sh
# Mint an 8-hour token (max duration is bounded by the API server's
# --service-account-max-token-expiration; the server may shorten the request).
kubectl create token automation-harness \
  -n infraweaver-system \
  --duration=8h
```

Write it into a throwaway kubeconfig rather than a long-lived file:

```sh
CFG="$(mktemp -t harness-kubeconfig.XXXXXX)"
kubectl config --kubeconfig="$CFG" set-cluster infraweaver-prod \
  --server=https://10.0.0.90:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true
kubectl config --kubeconfig="$CFG" set-credentials automation-harness \
  --token="$(kubectl create token automation-harness -n infraweaver-system --duration=8h)"
kubectl config --kubeconfig="$CFG" set-context harness \
  --cluster=infraweaver-prod --user=automation-harness
kubectl config --kubeconfig="$CFG" use-context harness

KUBECONFIG="$CFG" kubectl auth whoami     # expect system:serviceaccount:infraweaver-system:automation-harness
# ... work ...
shred -u "$CFG"                            # or simply let the token expire
```

Rules:

1. **Who mints.** `kubectl create token` is itself a privileged call
   (`create` on `serviceaccounts/token`). It is performed with the break-glass
   admin credential — the Talos-issued x509 client certificate in
   `~/.kube/config-platform-productie` (user `admin`, group `system:masters`).
   The harness deliberately cannot mint its own token.
2. **Never persist a minted token** to `~/.kube/`, to git, or to OpenBao. If a
   credential needs to survive a reboot, that is a signal the work belongs in a
   CronJob with its own in-cluster ServiceAccount, not in a human's kubeconfig.
3. **Duration.** 8h for interactive work; the shortest workable duration
   otherwise. There is no renewal path by design.
4. **Revocation.** Deleting and recreating the ServiceAccount invalidates every
   token issued to it (tokens are bound to the SA UID):
   ```sh
   kubectl delete sa automation-harness -n infraweaver-system
   # ArgoCD (selfHeal) recreates it within ~3 minutes with a new UID.
   ```

## 4. Retirement ordering — **do not reorder**

The credential being retired may be the one an operator or automation session is
currently authenticated with. Removing it before a verified replacement exists
locks everyone out of the cluster.

> **Step 0 is not optional.** `kubernetes/core/rbac/` is inert until an ArgoCD
> Application points at it. See §6 — that Application does not exist yet.

| # | Action | Gate before proceeding |
|---|---|---|
| 0 | Merge this directory to `main` **and** add the `core-rbac-manifests` Application (§6) | `kubectl get clusterrole automation-harness` returns the object |
| 1 | Confirm ArgoCD synced the role, binding and ServiceAccount | `kubectl get sa,clusterrolebinding automation-harness -n infraweaver-system` |
| 2 | Mint a token (§3) and re-run the §5 verification suite with it | **every** check passes |
| 3 | Delete the static token Secret | `kubectl delete secret -n infraweaver-system claude-platform-owner-token` |
| 4 | Delete the old binding | `kubectl delete clusterrolebinding claude-platform-owner` |
| 5 | Delete the orphaned ServiceAccount | `kubectl delete sa -n infraweaver-system claude-platform-owner` |

Steps 3–5 are the **only** sanctioned direct cluster mutations for this work
package. Keep an authenticated `system:masters` session open in a second
terminal throughout.

### Rollback

Each step reverses cleanly, and the break-glass x509 admin certificate is
unaffected by all of them — it is a separate credential issued by Talos, not a
ServiceAccount token.

```sh
# Undo step 4 (restores cluster-admin to the old SA):
kubectl create clusterrolebinding claude-platform-owner \
  --clusterrole=cluster-admin \
  --serviceaccount=infraweaver-system:claude-platform-owner

# Undo step 5:
kubectl create sa claude-platform-owner -n infraweaver-system

# Step 3 is NOT reversed by recreating a static Secret. Mint a short-lived
# token instead — that is the whole point of this change:
kubectl create token claude-platform-owner -n infraweaver-system --duration=1h
```

To roll back the replacement itself, revert the pull request; ArgoCD prunes the
role and binding on the next sync.

## 5. Verification suite (run with a minted token before step 3)

Every command below is read-only and must succeed. This set is the compliance
audit's own evidence-gathering, which is the definition of "what the harness
needs".

```sh
export KUBECONFIG=/path/to/throwaway-kubeconfig

kubectl auth whoami
kubectl get ns --show-labels
kubectl get nodes -o wide
kubectl get pods -A
kubectl get deploy,statefulset,daemonset -A
kubectl get cronjobs,jobs -A
kubectl get svc,configmaps,pvc -A
kubectl get events -A --field-selector type=Warning
kubectl get clusterrolebindings -o json | jq '.items[] | select(.roleRef.name=="cluster-admin")'
kubectl get applications.argoproj.io,appprojects.argoproj.io -A
kubectl get cpol
kubectl get polr,cpolr -A
kubectl get externalsecrets -A
kubectl get certificates -A
kubectl get netpol,ciliumnetworkpolicies -A
kubectl get ingressroutes,middlewares -A
kubectl get backuptargets,backups.longhorn.io -n longhorn-system
kubectl get prometheusrules -A
kubectl top nodes
kubectl get --raw "/api/v1/nodes/talos-prod-cp1/proxy/configz" | head -c 200
kubectl logs -n longhorn-system job/<a-recent-job> --tail=5
```

These must **fail** — if any succeeds, the role is too broad and this change has
not achieved its purpose:

```sh
kubectl get secrets -A                                    # expect Forbidden
kubectl create token argocd-application-controller -n argocd   # expect Forbidden
kubectl -n argocd patch application bootstrap --type=merge -p '{}'  # expect Forbidden
kubectl -n kube-system exec ds/cilium -- true             # expect Forbidden
kubectl auth can-i '*' '*' --all-namespaces               # expect "no"
```

## 6. Required handoff — this directory is inert without it

`kubernetes/core/` has two wiring mechanisms, and this directory needs the
second:

* `kubernetes/bootstrap/appset-core.yaml` — an ApplicationSet whose git
  generator matches `kubernetes/core/*/application.yaml`. It only builds **Helm
  chart** sources. `core/rbac/` is plain YAML, so this generator does not and
  must not pick it up.
* A **per-directory ArgoCD Application** in `kubernetes/bootstrap/`, which is how
  every other plain-manifest core directory is wired
  (`core-psa-manifests.yaml` → `kubernetes/core/psa`,
  `core-limitranges.yaml` → `kubernetes/core/limitranges`,
  `core-network-policies.yaml` → `kubernetes/core/network-policies`).

`kubernetes/bootstrap/` is owned by the change-management work package (WP1), so
this package does not add the file. **WP1 (or a human) must add
`kubernetes/bootstrap/core-rbac-manifests.yaml`:**

```yaml
---
# ArgoCD Application for the scoped automation-harness RBAC (GAP-C3).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: core-rbac-manifests
  namespace: argocd
  labels:
    infraweaver.io/type: core
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${DEPLOY_REPO_URL}
    targetRevision: main
    path: kubernetes/core/rbac
  destination:
    server: https://kubernetes.default.svc
    namespace: infraweaver-system
  syncPolicy:
    automated:
      prune: true     # a removed grant must actually disappear from the cluster
      selfHeal: true  # and must not be editable out-of-band
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

`prune: true` and `selfHeal: true` are deliberate and are what makes this an
actual control: a grant deleted from git is removed from the cluster, and a
grant widened by hand is reverted within minutes.

The `bootstrap` ArgoCD Application syncs `kubernetes/bootstrap` from `main` with
`prune: true, selfHeal: true`, so merging that file is sufficient — no manual
apply is needed.

## 7. Known follow-ups (not closed by this package)

* **`longhorn-system/longhorn-support-bundle` remains bound to `cluster-admin`.**
  The binding has no `ownerReferences`, but it carries
  `argocd.argoproj.io/tracking-id: core-longhorn:...` and Helm chart labels
  (`longhorn-1.7.3`), and the `core-longhorn` Application runs with
  `selfHeal: true`. Deleting it would be reverted by ArgoCD within minutes.
  Removing it for real means overriding the upstream Longhorn chart, which
  breaks support-bundle generation. **Accepted risk.** Compensating factors: the
  SA is only consumed by an on-demand support-bundle job, has no static token
  Secret, and `longhorn-system` is covered by the airgap NetworkPolicy baseline.
  Record it in `docs/compliance/risk-register.md` (WP7) with a review trigger of
  "next Longhorn chart upgrade — recheck whether the chart offers a scoped role".
* **`~/.kube/config-claude-platform-owner` on the operations host** holds the
  static token and becomes non-functional at step 3. Delete the file at the same
  time, remove the OpenBao entry `secret/platform/claude-platform-owner`, and
  update the two documents that reference it as the working credential:
  `docs/ZERO-TRUST-COMPLETION-PLAN.md` (lines 13–14) and
  `infrastructure/docs/ADDING-A-NODE.md` (lines 307, 356 — which currently
  instructs operators to use it in preference to the x509 admin config).
* **`infraweaver-console/infraweaver-console-sa-token`** is the cluster's only
  other static ServiceAccount-token Secret. It belongs to a running workload, so
  it is out of scope here, but it should be assessed for projected-token
  migration.
* **`infraweaver-console-reader`** (`kubernetes/catalog/infraweaver-console/base/rbac.yaml`)
  grants `create/update/patch/delete` on `secrets` cluster-wide. That is a
  separate, larger finding than GAP-C3 and is not addressed by this package.
* **CI coverage gap:** `scripts/validate-iac.sh` step 2/5 runs `kubeconform` only
  against directories literally named `manifests`. Files placed directly in
  `kubernetes/core/rbac/` (matching the `core/psa` layout) are therefore **not**
  schema-validated by the `validate-iac` gate. They were validated locally with
  `kubectl apply --dry-run=client` and `--dry-run=server`. Widening that glob is
  a WP1 change-management improvement.
