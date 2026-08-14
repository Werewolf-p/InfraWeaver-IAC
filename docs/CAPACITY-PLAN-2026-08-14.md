# Capacity plan — consolidate cp1/cp2, add the 100 GB node

**Cut:** 2026-08-14. Every number below carries the command that produced it.
**Status of the ask:** the shape works. The *ordering* in the question does not,
and the reason is etcd, not capacity.

> This document is a design note, not the deliverable. The requirement is that
> this whole flow is **doable from the console web**, as a default capability.
> See `~/.claude/agents/infra-fabric-studio.md` — the plan below is what the
> console's guided-consolidation run has to implement.

---

## 1. What is actually true right now

### Kubernetes (`kubectl describe node`, `kubectl top nodes`)

| node | host | allocatable | requests | requests % | actual use |
|---|---|---|---|---|---|
| talos-prod-cp1 | proxmox | 21146588Ki (20.2 GiB) | 18210Mi | 88% | 14756Mi |
| talos-prod-cp2 | proxmox | 21146584Ki (20.2 GiB) | 10768Mi | 52% | 11381Mi |
| talos-prod-cp3 | microserver | 6720488Ki (6.4 GiB) | 5180Mi | 78% | **6268Mi (95%)** |

Totals: **46.8 GiB allocatable, 33.4 GiB requested.**

N+1, losing the largest node:

```
surviving = 46.8 - 20.2 = 26.6 GiB
ratio     = 33.4 / 26.6 = 1.26      # >1.0 = cannot absorb the loss
shortfall = 6.8 GiB
```

`ClusterCannotSurviveNodeLoss` is firing, and it is correct.

> This ratio got slightly *worse* today on purpose. Prometheus requested 512Mi
> while using 1739Mi; the request is now 2Gi. The old number was not safer, it
> was false.

### Proxmox (`pvesh get /nodes/<n>/status`, `/nodes/<n>/qemu`)

| host | RAM | used | cpus |
|---|---|---|---|
| `proxmox` (10.1.0.3) | 62.7 GB | **60.6 GB (97%)** | 12 |
| `microserver` | 15.5 GB | 12.4 GB | 8 |

Running VMs on `proxmox`: cp1 `9300` (24 GB cfg / 20.3 used), cp2 `9301`
(24 / 19.9), TrueNAS `103` (8 / 5.2), github-runner `107` (8 / 5.9 — **this is
the box Claude runs on**), Traefik+AdGuard `100` (6 / 1.9), Backup `111`
(4 / 3.3), init `9004` (2 / 0.9). cp1 and cp2 run `balloon: 0`, so 48 of the
62.7 GB is hard-pinned.

`microserver` runs only cp3 `9302` (10 GB cfg / 9.9 used).

### The two real problems, named

1. **`proxmox` is full at 97%.** Not "getting full". There is no room to grow
   anything on that host, and 48 GB of it cannot balloon.
2. **cp3 is the starved node, and consolidating cp1/cp2 does nothing for it.**
   It is on a different host with 15.5 GB total. It sits at 95% of allocatable
   and has a history of `MemoryPressure=True` with rolling exitCode 137 on
   kube-scheduler, kube-controller-manager, metrics-server and Longhorn CSI.

---

## 2. The ordering problem — read this before touching anything

The question was "remove cp1 or cp2, merge them together in 1 node, and I add a
new node with 100 GB RAM".

Consolidating first means running a **2-member etcd cluster**:

| members | failures tolerated |
|---|---|
| 2 | **0** |
| 3 | 1 |
| 4 | 1 |

**Two members tolerates zero failures — strictly worse than three, no better
than one.** A single host reboot during that window is a dead cluster, and this
platform has already had one self-inflicted outage of that class.

`3 -> 4 -> 3` never drops below "tolerates 1". `3 -> 2 -> 3` does.

So the answer to "which one first" is: **the new 100 GB node goes in first, and
it is not negotiable.** That also happens to be the easier order, because the
100 GB node gives you somewhere to drain to.

One constraint to design around: `envs/productie/cluster.yaml` requires the
control-plane-capable count to be **ODD**. That governs the committed topology,
not the transient one. Either express add+remove as one reviewed terraform
change, or move etcd membership with `talosctl` and reconcile terraform after.
Pick one deliberately and record which.

---

## 3. The recommended end state

Assuming the 100 GB machine is a **new physical host** — it must be, because
`proxmox` has ~2 GB free and cannot hold a 100 GB VM:

| node | host | RAM | ~allocatable |
|---|---|---|---|
| talos-prod-cp4 *(new)* | new box | 100 GB | ~94 GiB |
| talos-prod-cp1 *(merged, resized)* | proxmox | 36 GB | ~33 GiB |
| talos-prod-cp3 | microserver | 10 GB | 6.4 GiB |

Three control-plane members. Odd. Three failure domains.

```
total allocatable = 94 + 33 + 6.4 = 133 GiB
requests          = 33.4 GiB (today)
N+1 (lose cp4)    = 39.4 surviving, ratio 0.85   PASS
N+1 (lose cp1)    = 100 surviving,  ratio 0.33   PASS
```

Why cp1 at 36 GB and not 40: `proxmox` must still hold TrueNAS (8), the runner
(8), Traefik (6), backup (4) and init (2) = 28 GB of other VMs. 36 + 28 = 64
against 62.7 physical, which the balloon can absorb *because those five do
balloon* — cp1 would be the only `balloon: 0` guest left. At 40 GB it cannot.

**Freed by the merge: 12 GB of hard-pinned RAM on `proxmox`** (48 GB pinned
across two guests becomes 36 GB in one). That is what fixes the 97%.

### Do not skip this: cp3 stays the weak link

Nothing above helps cp3. It is 6.4 GiB on a 15.5 GB host and runs at 95%. Once
cp4 exists, the honest options are (a) evacuate cp3's workloads to cp4 and let
it be a quorum-only member, or (b) retire `microserver` entirely and move the
third member elsewhere. Decide this explicitly rather than leaving it firing.

---

## 4. Sequence

Each step names what proves it. A step without a read-back is not done.

**Phase 0 — before anything moves**
- [ ] etcd snapshot taken **and restored somewhere** to prove it. No restore
      drill has ever been run; a snapshot nobody has restored is a hypothesis.
- [ ] Record `kubectl get pods -A -o wide` and the etcd member list as the
      before-state.

**Phase 1 — add cp4 (the 100 GB box)**
- [ ] Provision the host, add it to the Proxmox cluster.
- [ ] Create the Talos VM, join as a **control plane**.
- [ ] Prove: `talosctl etcd members` shows **4 healthy members**; node Ready;
      `kubectl get nodes` shows 4.
- [ ] Only now is the cluster able to lose a node safely.

**Phase 2 — evacuate cp2**
- [ ] Cordon cp2, then drain.
- [ ] Prove: cp2 has **zero non-daemonset pods** — count them, do not trust the
      drain's exit code.
- [ ] Name anything that would not move (Longhorn/local-volume StatefulSets,
      PDB blocks) *before* starting, not when it stalls.

**Phase 3 — remove cp2 from etcd, then destroy the VM**
- [ ] `talosctl etcd remove-member` **first**, prove 3 healthy members.
- [ ] Then destroy VM 9301. In that order — the known decommission bug destroys
      the VM before the Kubernetes half completes, which leaves no rollback.

**Phase 4 — resize cp1 to 36 GB**
- [ ] cp1 is `balloon: 0`, so this needs a shutdown. Do it with cp4 carrying the
      load and 3 members intact (cp1 down = 2 healthy of 3, which tolerates the
      planned outage and nothing else — keep the window short).
- [ ] Prove: node allocatable reflects the new size; `MemoryPressure` clear.

**Phase 5 — reconcile and re-measure**
- [ ] terraform / `cluster.yaml` matches the live 3-node topology; committed.
- [ ] Recompute N+1 from live numbers. Expect ratio ~0.85.
- [ ] `ClusterCannotSurviveNodeLoss`, `KubeMemoryOvercommit`,
      `NodeMemoryRequestsNearAllocatable`, `WorkloadMemoryGrosslyOverRequested`
      should all clear. Any that do not, investigate — do not silence.

**Phase 6 — unblocked by the above**
- [ ] etcd `listen-metrics-urls`. The patch restarts etcd on all converged
      control planes, which is why it was deferred; with headroom and 3 healthy
      members it is finally safe. Fixes `AlertInputMissingEtcd` and makes
      `EtcdMemberDown` able to fire at all.

---

## 5. What this has to become in the console

The sequence above is exactly the shape of a guided run. It should not live here.

- `/infrastructure` already has `add-node-view`, `[node]`, `lifecycle-runs-view`,
  and API routes for `nodes`, `hosts`, `drift`, `lifecycle`,
  `nodes/[name]/{plan,resize,power,decommission}`, plus
  `api/cluster/{drain,pdbs,node-pods,top-consumers}`. The backbone exists.
- Missing: a **capacity simulator** (answer "what if I remove cp2" against live
  requests), a **guided consolidation run** with the phases above as resumable
  steps, and a **Proxmox panel** showing configured vs resident vs balloon floor
  per VM — the overcommit that starves cp3 is invisible from Kubernetes alone.
- Every destructive verb needs `?dryRun=true` returning the same plan object the
  UI renders, so preview and execute never diverge.

Owner: `Infra Fabric Studio` agent.
