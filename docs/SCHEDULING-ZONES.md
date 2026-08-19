# Scheduling zones — how this cluster decides what may cross the WAN

**Status:** policy adopted 2026-08-16, after the 2026-08-15 slowdown.
**Enforced by:** `scripts/validate-scheduling.py` (CI: `.github/workflows/validate-iac.yml`).
**Fleet data:** `scripts/fleet-topology.yaml`.

---

## The incident this exists to prevent

`talos-prod-cp2` was deleted on 2026-08-15. Nothing in `kubernetes/` changed.
The platform got dramatically slower: Traefik p95 for authentik went
**0.270 s → 3.765 s**, and authentik forward-auth backs 41 of 45 routes, so
nearly every surface paid it.

The scheduler did nothing wrong. The intent — *keep latency-critical singletons
off the far node* — was written down in eight places and **bound in none of
them**:

| What was written | What it did |
|---|---|
| `preferred… hostname In [talos-prod-cp1, talos-prod-cp2]` | half of it addressed a node that no longer existed; the rest was a hint the scheduler discarded once cp1 filled up |
| `required… hostname In [talos-prod-cp2, talos-prod-cp3]` (OpenBao) | silently narrowed to a **hard pin on cp3 alone** — one replica, tightest node, no fallback |
| `nodeSelectors: [hostname In [cp1, cp3]]` (MetalLB dns-l2) | correct only by luck; the next renamed node would have emptied the selector |

Two independent bugs, one shape: **a rule that reads as protection and binds to
nothing.** A `nodeAffinity` term matching zero nodes is not an error. It renders,
it passes `kubeconform`, it survives review, and it stops working in silence.

---

## The topology

`topology.kubernetes.io/zone` is set from Talos machine config
(`machine.nodeLabels`, written by `scripts/talos-node-add.sh --zone`), so Talos
reasserts it on every boot and a rebuilt node inherits it.

| Zone | Node | Site | RTT to the other local zone |
|---|---|---|---|
| `proxmox` | talos-prod-cp1 | local | 0.19–0.63 ms |
| `microserver` | talos-prod-cp3 | local | 0.19–0.63 ms |
| `hypatia` | talos-prod-cp4 | **remote** (Hetzner, stretched VLAN) | 14.9–16.3 ms |

An Authentik request makes ~7.7 DB round trips. Server and database on opposite
sides of that link costs ≥125 ms *per request* before any work happens.

---

## The policy

Exactly two classes. Nothing else.

**latency-bound** — anything on the synchronous request path of a user-facing
surface, or half of a chatty pair. Carries, verbatim:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: NotIn
              values: [hypatia]      # = remote_zones in scripts/fleet-topology.yaml
```

Current membership: authentik server/worker/postgresql, wordpress-cache
(valkey), infraweaver-console, infraweaver-api, kyverno ×4, **openbao**,
**n8n + postgresql-n8n**, and the MetalLB `prod-l2` / `dns-l2` advertisements
(a VIP announced from the far side of the WAN hairpins every request through it).

**Membership is also conferred by storage, automatically.** Anything that mounts
a `longhorn-lowlat` volume is latency-bound by definition and does not need — and
must not rely on — a hand-written copy of the block above. See
[the storage-derived rule](#the-rule-you-do-not-write-longhorn-lowlat) below.

**latency-tolerant** — the default. **No zone rule at all.** Batch work,
backups, image builds, DNS/DHCP-style controllers, anything reconciling on a
timer. These are free to use cp4, and most already do.

That second class is the load-bearing half. cp4 holds ~2.70 spare cores and
~15 GiB — by far the most in the fleet — and today runs velero, external-dns,
buildkitd, the ArgoCD repo/appset/notifications controllers and most CronJobs.
**The goal is "nothing latency-critical crosses the WAN", not "cp4 is empty."**
Nothing here pushes work onto cp4 and nothing taxes it for being used.

---

## The rule you do not write: `longhorn-lowlat`

A Longhorn volume has two halves and they are placed by two different systems.

* **Replicas** hold the data. `longhorn-lowlat` fences them with
  `diskSelector: lowlat` — cp1 and cp3 carry that disk tag, cp4's disk carries
  `offsite`, so a replica can never land across the WAN.
* **The engine** does the I/O. It runs wherever the volume is *attached*, which
  is wherever the **pod** was scheduled, and it writes to every replica
  synchronously, acknowledging only once all of them have acked.

Fencing only the first half is worse than fencing neither. Measured 2026-08-19:
`lol-db`, `yonavaarwater-nl-db` and `zonnevaarwater-nl-db` each ran on cp4 with
both replicas correctly on cp1+cp3, so **every write left the node, crossed the
15 ms link twice, and blocked until it came back.** Nothing was misconfigured;
they had been moved off cp3 the previous night when it hit 99% memory requests,
and the scheduler had no reason to prefer cp1 over cp4.

So the rule is attached to the **volume**, not to the workload:
`kubernetes/core/kyverno/manifests/lowlat-pv-node-affinity.yaml` stamps exactly
the latency-bound block above onto `spec.nodeAffinity` of every
`longhorn-lowlat` PersistentVolume at admission, and the scheduler's built-in
VolumeBinding plugin enforces it against every pod that binds that PV — the same
mechanism that makes a `local-path` PVC pin its pod to one node.

Three consequences worth knowing:

1. **You do not add an affinity block for a lowlat workload.** It is already
   fenced, including workloads generated outside this repo (the WordPress site
   Deployments are written at runtime by the console addon and have no affinity
   field at all).
2. **PV `nodeAffinity` is immutable once set.** Editing the policy changes what
   NEW volumes get; re-stamping an existing one means deleting and recreating
   its PV — safe on this `Retain` class, but a deliberate maintenance action.
3. **A lowlat pod is unschedulable if both cp1 and cp3 are down.** Intended.
   Running these databases over the WAN is what produced
   `FATAL: could not open file "global/pg_filenode.map": I/O error` on
   2026-08-14.

`dataLocality` is not the mechanism and cannot be. The class has always set
`best-effort`; what that produced on those three volumes was a third replica
with `hardNodeAffinity: talos-prod-cp4` stuck permanently in state `stopped`,
because it wants a replica next to the engine and the diskSelector forbids one
there. The two settings contradict each other the moment the pod is on the wrong
node, and the diskSelector is the one that must win.

---

## Why not tainting cp4 `PreferNoSchedule`

Rejected, for three reasons in increasing order of seriousness.

1. **It is more work, not less.** One taint, then a toleration on velero,
   external-dns, buildkitd and ~15 CronJobs to restore behaviour that already
   works correctly today. That is more files than the zone rules, *plus* a
   machine-config change.
2. **`PreferNoSchedule` is a preference.** It is the exact instrument that just
   failed. A blanket weak hint that the scheduler discards under resource
   pressure is not prevention; it is the same bug applied fleet-wide.
3. **It moves the intent out of git.** A Talos taint lives in machine config: no
   PR, no diff, no `git log`, no CI, and it needs an apply window per node. The
   class being closed here is *"intent that is written down but does not bind."*
   Relocating the intent somewhere git cannot see it makes that class strictly
   worse — and it is the one thing `scripts/validate-scheduling.py` could never
   check.

---

## Why not zone `topologySpreadConstraints`

Rejected, and it would have been actively harmful.

1. **Wrong question.** Spread constraints answer *"distribute evenly"*; the
   requirement is *"never cross the WAN."* With one node per zone, zone-spread is
   identical to the hostname-spread already in use — no new information.
2. **They push toward cp4.** A `maxSkew: 1` constraint across three zones works
   to *reduce* skew, i.e. it encourages placing pods in the under-filled zone.
   For authentik-server, openbao and valkey that is a constraint arguing for the
   thing that broke.
3. **They are a no-op for singletons.** A spread constraint over one replica
   constrains nothing, and every workload in the incident ran one replica.

Spread constraints stay where they belong — `kubernetes.io/hostname`, for
genuine anti-affinity (Traefik's 3 replicas, authentik's HA pairs).

---

## Schedulability — what was checked before making anything required

Measured 2026-08-16, `kubectl describe nodes`:

| Node | Zone | CPU requested | Memory requested |
|---|---|---|---|
| talos-prod-cp1 | proxmox | 9087m (80%) | 27194Mi (58%) |
| talos-prod-cp3 | microserver | 3657m (69%) | 6218Mi (72%) |
| talos-prod-cp4 | hypatia | 2726m (51%) | 5360Mi (25%) |

* **OpenBao** requests 64Mi/25m and is already running on cp3. The change
  *widens* its options (cp3-only → cp1 + cp3); it cannot make it unschedulable.
* **n8n + postgresql-n8n** are already on cp1 and pinned harder than any affinity
  by `local-path` PVs (`n8n-data`, `postgresql-n8n-data`, both bound to
  talos-prod-cp1). The rule changes no placement today; it keeps the intent true
  when those volumes move to a class that can follow the pod.
* **MetalLB** advertisements are selectors, not pods — nothing to schedule. Both
  VIPs are already announced from cp1.
* **Traefik was deliberately left alone.** It runs 3 replicas under
  `topologySpreadConstraints … whenUnsatisfiable: DoNotSchedule` on
  `kubernetes.io/hostname`. Adding a zone rule would leave 3 replicas competing
  for 2 eligible nodes and one **permanently Pending**. The WAN hairpin it was
  exposed to is fixed at the MetalLB layer instead, where it costs nothing.

Nothing new is scheduled onto cp3, the tightest node. No workload lost its last
eligible node.

---

## Adding or retiring a node

1. `scripts/talos-node-add.sh --name <n> --zone <z>` / `scripts/talos-node-retire.sh --name <n>`
2. **Edit `scripts/fleet-topology.yaml` in the same PR.**
3. CI (`validate-scheduling.py`) then fails on every rule still naming the
   departed node — in the pull request, instead of in a latency graph three weeks
   later.

A new *remote* site is a one-line change: add it to `remote_zones`, and gate G4
turns every latency-bound workload red until it excludes the new zone too.
