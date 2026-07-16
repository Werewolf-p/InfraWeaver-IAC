# Zero-Trust Completion Plan

Finishes the flannel→Cilium + airgap rollout. Work top-down: P0 unblocks
everything else. Each task has context, steps, verification, and rollback. Do not
skip verification. Stop and report if a P0/P1 step fails.

## Context (already done — do not redo)

- Dataplane is **Cilium 1.17.4 + Hubble**, live on all 3 Talos control-plane nodes
  (`talos-prod-cp1/2/3` = 10.0.0.90/.91/.92). `policyEnforcementMode: default`.
- **Talos access** works: `~/.talos/config` (also in OpenBao `secret/platform/talosconfig`).
  Always `export TALOSCONFIG=/home/runner/.talos/config` before `talosctl`.
- **Platform-owner kubeconfig**: `~/.kube/config-claude-platform-owner` (also OpenBao
  `secret/platform/claude-platform-owner`). Default kubeconfig also works.
- **App tier is airgapped** (CNP `airgap-baseline` in: tradesphere, private-test, build,
  infraweaver, infraweaver-system, n8n-prod, game-hub, game-servers). Allowlists live
  for console→argocd, cert-manager, external-dns, tradesphere→Binance.
- **GitOps** committed+pushed to `main`: `kubernetes/core/network-policies/`,
  `kubernetes/core/cilium/`, `kubernetes/bootstrap/core-network-policies.yaml`.
  ArgoCD source = `github.com/Werewolf-p/InfraWeaver-infra`, auto-sync.
- **Rollback (CNI)**: `talosctl -e <ip> -n <ip> patch mc --patch '{"cluster":{"network":{"cni":{"name":"flannel"}}}}'`
  then `reboot`, then reinstall flannel. Per-policy rollback: `kubectl delete cnp <name> -n <ns>`.

## Guardrails (always)

- **Never commit secrets.** Talos config + SA token stay in OpenBao only.
- **One control-plane node at a time** for any reboot (etcd quorum is 2/3).
- **Watch Hubble** before/after each lockdown: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --last 50`.
- Apply infra/WordPress policy from `pending/` only while watching that subsystem.

---

## P0 — Unstick the GitOps pipeline (blocks all GitOps changes)

**Problem:** `bootstrap` ArgoCD app is stuck mid-sync "waiting for healthy state of
Application/platform-n8n". n8n was broken before the migration (`CreateContainerConfigError`),
so the sync wave never completes; `core-network-policies` is never created and
`core-cert-manager-manifests`, `core-external-secrets-manifests`, `core-openbao-manifests`,
`external-routes` show OutOfSync. Security is unaffected (policies are live, applied
directly) — but no GitOps change will flow until this clears.

**Fix (do both):**
1. Root-cause n8n so the wave recovers:
   - `kubectl -n n8n-prod describe pod -l app.kubernetes.io/name=n8n | grep -A5 -iE "Events|Error"`
   - `CreateContainerConfigError` is almost always a missing/!ready Secret or ConfigMap
     (likely the ExternalSecret from OpenBao not synced). Check:
     `kubectl -n n8n-prod get externalsecret,secret,cm` and the ESO status.
   - Fix the missing ref (re-sync ExternalSecret / restore the secret), confirm n8n pods Run.
2. If n8n cannot be fixed quickly, stop it blocking the wave: either scale it out
   (`kubectl -n n8n-prod scale deploy --all --replicas=0`) so it reports healthy, or
   remove it from the bootstrap sync wave, then re-sync bootstrap.

**Then adopt the network policies:**
- `kubectl -n argocd annotate application bootstrap argocd.argoproj.io/refresh=hard --overwrite`
- Or `argocd app sync bootstrap`. Confirm `core-network-policies` appears Synced/Healthy.

**Verify:**
- `kubectl -n argocd get application core-network-policies` → Synced, Healthy.
- `kubectl -n tradesphere get cnp airgap-baseline -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}'` → non-empty (Argo owns it).
- `bootstrap`, `core-*-manifests`, `external-routes` → Synced.

---

## P1 — Fix Kyverno admission (security gap)

**Problem:** `kyverno-admission-controller` is CrashLoopBackOff (200+ restarts, predates
migration). While down, Kyverno admission policies are NOT enforced.

**Fix:**
- `kubectl -n kyverno logs deploy/kyverno-admission-controller --previous | tail -40` —
  find the crash cause (common: OOM → raise memory limit; or webhook cert/CA issue → delete
  the webhook configs + restart so they regenerate; or API/etcd reachability).
- Apply the minimal fix (resource bump or cert regen), confirm 1/1 Running and stable.

**Verify:** pod Running with stable restart count; `kubectl get validatingwebhookconfiguration | grep kyverno` present; a test of an existing policy admits/denies as expected.

---

## P2 — Airgap the infra tier (watched, one namespace at a time)

**Problem:** `longhorn-system`, `dns-system`, `registry`, `velero` have no policies — not
yet airgapped. These are cluster-critical; a wrong rule is cluster-wide.

**Fix (per namespace, in this order: velero → registry → dns-system → longhorn-system):**
1. Apply its baseline from `kubernetes/core/network-policies/pending/infra-airgap.yaml`
   (longhorn's is there; for the others copy `_TEMPLATE.yaml` and add the infra entities
   `host, remote-node, cluster` like longhorn's).
2. Immediately watch that subsystem: longhorn volumes attach, DNS resolves, image pulls work.
   `hubble observe --verdict DROPPED --namespace <ns> --last 100` and add each legitimate
   flow to `manifests/allowlists.yaml`.
3. Only move to the next namespace once the current one is healthy.

**Verify:** stateful pods keep volumes; new pods pull images; DNS resolves cluster-wide.
**Rollback:** `kubectl delete cnp airgap-baseline -n <ns>` instantly restores open networking.

---

## P2 — WordPress updates/plugins-only lockdown

**Problem:** `pending/wordpress-lockdown.yaml` is the brief's headline but not applied
(needs real pod labels + Authentik SSO egress).

**Fix:**
1. `kubectl -n wordpress get pods --show-labels` — confirm the selector (sites: my-site,
   testsite1, ssoe2e; may be per-site, not `app: wordpress`).
2. If SSO is enabled, add an egress block to Authentik before applying, or login breaks.
3. Apply, then load each site + log in via SSO + check wp-admin updates page. Watch Hubble.

**Verify:** sites serve via Traefik; updates/plugins reachable; SSO login works; all other
egress denied. **Rollback:** `kubectl delete cnp wordpress-zero-trust -n wordpress`.

---

## P3 — Deploy the console firewall feature

Code committed on `feat/firewall-blocked-flows` (platform repo); 11 tests green. Deploy via
the console image pipeline (host `npm run build` → `Dockerfile.prebuilt` → push to
`registry.int.example.com/infraweaver-console:<tag>` → roll the deployment; keep the
current tag for rollback). Note: next build is memory-heavy on this 3.9 GB runner. After
deploy, open `/network/firewall` — it reads Hubble drops and offers per-pod "Allow next time".

## P3 — Bring Cilium under ArgoCD + cleanup

- Cilium is a manual helm release; `kubernetes/core/cilium/application.yaml.disabled` holds
  the Argo definition. To hand it to Argo, rename to `application.yaml` and let appset-core
  adopt it — do this watched (CNI churn risk); values already match live.
- Pre-existing broken pods unrelated to this work: authentik-ldap-outpost, onedev,
  minio/velero. Triage separately (mostly missing secrets/config).

---

## Definition of done

All ArgoCD apps Synced/Healthy; Kyverno enforcing; every workload + infra namespace
airgapped with only-needed allows in `allowlists.yaml`; WordPress locked down; console
firewall feature live; Cilium ArgoCD-managed; no unexpected Hubble drops.
