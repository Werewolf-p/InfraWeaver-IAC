# Resource governance

Owner: platform / SRE. Last measured against the live cluster: **2026-08-02**.

This directory is the apiserver-native floor for resource allocation. It is
synced by the `core-limitranges` ArgoCD Application
(`kubernetes/bootstrap/core-limitranges.yaml`).

---

## What was actually wrong

Measured, not assumed:

| Node | CPU req / alloc | Mem req / alloc | Mem **limits** / alloc | Allocatable mem |
|---|---|---|---|---|
| talos-prod-cp1 | 90.3% | **96.4%** | 239% | 20.2 GiB |
| talos-prod-cp2 | 59.1% | 34.2% | 102% | 20.2 GiB |
| talos-prod-cp3 | 49.4% | 80.4% | 268% | **6.4 GiB** |

Cluster-wide: CPU requests 11705m of 15900m allocatable (74%), actual CPU usage
~2300m (14%). Memory requests 34.1 GiB of 46.7 GiB.

Four findings drove the design:

1. **The alarming "494% CPU" number was the least important one.** That is a
   *limits* figure, and CPU is compressible — an over-committed CPU limit
   causes CFS throttling, never a node failure. The scheduler only ever reads
   *requests*.

2. **cp1 at 96.4% of allocatable memory requests is the real cliff.** ~735 MiB
   of schedulable memory left. Nothing meaningful can be placed there and
   anything evicted from it may not fit back.

3. **The cluster has no N+1 headroom.** Total memory requests are **118.5%** of
   the allocatable memory that would remain after losing the largest node. A
   single node failure strands pods in Pending. This is now alerted on
   (`ClusterCannotSurviveNodeLoss`).

4. **Memory limits at 239–268% of allocatable is the genuine outage mode**,
   because memory is incompressible and the kernel OOM killer — not
   Kubernetes — picks the victim.

`kubectl top nodes` showing cp3 at **103%** is percent of *allocatable*, not of
physical RAM. cp3 is at ~70% of physical. Talos reserves a flat 3.28 GiB on
every node, which is 14% of cp1/cp2 but **34% of cp3**. cp3 was not about to
fall over; it is structurally undersized. See "Needs a human" below.

---

## Why the existing controls did not catch any of it

| Control | Why it was silent |
|---|---|
| `LimitRange workload-defaults` (this dir) | Declared only `default`/`defaultRequest`. Defaults fill in blanks; **they never reject**. Every container in that namespace already set explicit resources, so the object was a total no-op. |
| `require-resource-limits` (Kyverno) | `Audit` mode, and its namespaceSelector matched **2 namespaces**. It also only checks that limits *exist* — 1Gi request against a 12Gi limit passes. |
| `set-default-memory-limits` (Kyverno) | **match ∩ exclude = ∅.** Matched exactly zero namespaces. Fully inert. |
| kube-prometheus-stack `KubeMemoryOvercommit` | Cluster-wide only. Cannot see a single saturated node. |
| `memory-pressure.yaml`, `oom-kills.yaml` | Fire on **usage**. cp1 uses 78% while committing 96% — invisible to both. |
| Console `placement-rebalance` | Preference-driven (`infraweaver.io/preferred-node`), not pressure-driven. Its headroom math is `max(0, alloc − req)`, so anything over 100% renders identically to exactly 100%. |

The through-line: **everything measured utilisation; nothing measured
allocation.**

---

## The mechanism

Four layers, weakest failure mode first.

**1. `baseline-namespaces.yaml` — `defaultRequest` only, 15 namespaces.**
Contains no `default`, no `max`, no ratio, so it has no code path that can
reject a pod. Purpose is to eliminate BestEffort QoS (23 pods today, including
`openbao` at 232 MiB — the platform secret store, currently first in line for
the OOM killer).

**2. `governed-namespaces.yaml` — full LimitRange + ResourceQuota, 6 namespaces.**
`maxLimitRequestRatio` is the control that was missing everywhere; it is what
makes a 12Gi-limit-on-1Gi-request structurally impossible to reintroduce.
Chosen over Kyverno alone because **LimitRange and ResourceQuota live inside
kube-apiserver and cannot fail open**, whereas an admission webhook has a
`failurePolicy` and is skipped when its controller is down.

**3. `../kyverno/manifests/resource-governance-policies.yaml` — the cluster-wide net.**
Rule 1 is the self-applying part: every *future* namespace automatically
receives a baseline LimitRange, `synchronize: true` so it is repaired if
deleted. That is the "never again" property — layers 1 and 2 only cover
namespaces someone enumerated.

**4. `../../monitoring/alerts/resource-allocation.yaml` — alerts on allocation.**
Fires on requests-vs-allocatable, before saturation. All 7 rules validated with
`promtool check rules` and each expression executed against live Prometheus.

### Every threshold is derived, not picked

Each `max` and `maxLimitRequestRatio` is set **above the worst value measured
in that namespace**, rounded up so no float-equality edge case rejects a pod
that is admissible today. Applying this directory rejects nothing currently
running.

### Two rules that are deliberate and will look wrong

- **No CPU limits are set or required, anywhere.** CPU is compressible; a CPU
  limit only throttles its owner and protects nothing. The node is protected by
  CPU *requests*. Adding CPU limits would inflict throttling on the 14
  `wordpress` pods that burst freely today and would fix nothing.
- **`limits.cpu` is absent from every ResourceQuota**, because including it
  would force every pod in the namespace to declare a CPU limit — the same
  regression by the back door.

### Quota safety interlock

A ResourceQuota constraining `requests.cpu` / `requests.memory` /
`limits.memory` makes those fields **mandatory** on every pod in the namespace.
Every quota here is therefore paired with a LimitRange supplying a default for
exactly those three fields. LimitRanger mutates before ResourceQuota validates,
so the default is always present when the quota is checked.

**Never add a quota to this directory without the matching LimitRange defaults.**

---

## Rejected, with reasons

**VPA (Vertical Pod Autoscaler) — rejected.** It would duplicate something the
console already has. `src/lib/finops/rightsizing.ts` and
`/api/cluster/rightsizing` already compare per-container requests against real
usage and emit a recommended request (usage × 1.25), surfaced at
`/resource-optimizer`. Installing the VPA recommender adds CRDs, a controller
and its own memory footprint to a cluster that is memory-constrained, to
compute what is already computed. The gap is not the recommendation — it is
that nothing *acts* on it. Better next step: wire the existing rightsizing
output into the alert path, not a second recommender.

VPA in `Auto`/`Initial` mode is separately unsafe here: it evicts pods to
resize them, and it conflicts with the two existing HPAs
(`infraweaver-console`, `infraweaver-api`) which scale on memory.

**Descheduler — rejected.** This cluster already has **two** eviction actors:
`placement-rebalance` (\*/15, console `/api/placement/rebalance`) and
`node-memory-rebalancer` (\*/10, `kubernetes/core/argocd/manifests/node-automation.yaml`).
Adding a third independent evictor invites eviction storms and controllers
fighting each other. It would also not fix the actual imbalance: cp1 is full
because of one 12 GiB game-server pod that cannot move without downtime, and
`LowNodeUtilization` evicting small pods off cp1 frees almost nothing.

**PriorityClasses — already done, not duplicated.** Eight classes exist and are
well designed (`platform-default` is `globalDefault`; `game-server` is lowest
at 10000 with `preemptionPolicy: Never`, so the game server yields first and
never preempts). No change needed.

---

## Rollout order — this order matters

1. **`kubernetes/core/buildkit/buildkit.yaml`** (memory limit 12Gi → 3Gi).
   **Restarts the buildkitd pod.** Idle at 6 MiB, so low risk, but in-flight
   builds would die.
2. **`resource-allocation.yaml`** (alerts). No workload impact.
   `NodeMemoryRequestsExhausted` and `ClusterCannotSurviveNodeLoss` will fire
   immediately — that is correct, they are describing today.
3. **`baseline-namespaces.yaml`**. No restarts. But once a DaemonSet in these
   namespaces next rolls, its pods acquire a request they did not have.
   **cp1 is at 96.4%, so do step 1 and confirm cp1 headroom before this**, or a
   DaemonSet pod on cp1 can go Pending.
4. **`governed-namespaces.yaml`**. No restarts. From this point a rollout that
   violates `max` or `maxLimitRequestRatio` **fails to create pods**, surfacing
   as a stuck rollout rather than an obvious error.
5. **Kyverno policies**, Audit only. Verify with
   `kubectl get clusterpolicyreport -o wide` and confirm
   `kubectl get limitrange -A | grep auto-baseline` shows generated objects
   (proves the aggregated RBAC took effect).
6. **Flip to Enforce** only after the Audit soak is clean.

### Changing a limit later

Raising a container's memory limit now requires raising the corresponding cap
in `governed-namespaces.yaml` **in the same commit**. That coupling is the
point — it is what stops silent drift.
