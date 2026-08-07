# Falco — runtime threat detection (GAP-H8)

**Status: STAGED, NOT ENABLED. This is a deliberate decision, not unfinished work.**

`kubernetes/bootstrap/app-falco-manifests.yaml.disabled` and
`kubernetes/platform/falco/application.yaml.disabled` are both still `.disabled`.
Nothing in this directory deploys anything until an operator completes the canary
below.

## Why it is not enabled

GAP-H8 (SOC 2 CC7.1/7.2, ISO 27001:2022 A.8.16) wants runtime threat detection.
Three facts argue against turning it on from a manifest review:

1. **A previous attempt already failed on this exact kernel.** The values file
   recorded `unable to find a prebuilt driver` on `6.18.24-talos` and the DaemonSet
   was parked behind a nodeSelector no node carries.
2. **The fix is plausible but unproven.** That failure is the signature of the
   *classic* eBPF loader, which downloads a probe compiled per kernel version —
   an artifact that will never exist for a Talos kernel. `modern_ebpf` is a CO-RE
   probe built into the Falco binary and needs only BTF, which **is** present:

   ```
   talosctl -n 10.0.0.90 ls -l /sys/kernel/btf/vmlinux   → 8.7 MB
   talosctl -n 10.0.0.92 ls -l /sys/kernel/btf/vmlinux   → 8.7 MB
   ```

   `values.yaml` has been corrected to `driver.kind: modern_ebpf` with
   `driver.loader.enabled: false`. But "the prerequisite exists" is not "the probe
   attaches". Proving that requires starting a pod, which this work package does
   not do.
3. **A broken privileged DaemonSet would land on all three nodes at once.** This
   is a converged 3-node control plane with real memory pressure — see below.

## Resource cost per node (measured 2026-08-07)

| Node | allocatable mem | requested before | after Falco (+256Mi) | limits before → after |
|---|---|---|---|---|
| talos-prod-cp1 | 20651 Mi | 19030 Mi (**92.1%**) | 19286 Mi (**93.4%**) | 179% → 185% |
| talos-prod-cp2 | 20651 Mi | 8806 Mi (42%) | 9062 Mi (44%) | 127% → 132% |
| talos-prod-cp3 | 6563 Mi | 4440 Mi (67%) | 4696 Mi (71%) | **209% → 225%** |

Per node: `requests 256Mi/100m`, `limits 1024Mi/1000m`, plus ~24 MB of eBPF ring
buffers (`bufSizePreset: 4`, one buffer per 2 CPUs, 6 vCPU nodes). `falcosidekick`
stays at `replicaCount: 0` until the DaemonSet is healthy.

**cp3 is the constraint.** Its limits are already 209% overcommitted with 6.5 GiB
allocatable and a documented MemoryPressure history. cp3 must be the *last* node
labelled, never the canary.

## Required canary procedure

Do these in order. Do not skip to step 5.

1. **Merge this branch.** `values.yaml` changes nothing on its own — both
   Applications are still `.disabled`, so ArgoCD does not see them.
2. **Enable the Applications** by renaming both files (drop `.disabled`) in a
   *separate* PR:
   * `kubernetes/bootstrap/app-falco-manifests.yaml.disabled` → namespace + NetworkPolicies only, no pods.
   * `kubernetes/platform/falco/application.yaml.disabled` → the Helm release.

   After sync, `kubectl get pods -n falco` must show **zero** pods, because no
   node carries the `falco-enabled` label. Confirm that before continuing:

   ```
   kubectl get nodes -l falco-enabled=true      # expect: No resources found
   kubectl get pods -n falco                    # expect: No resources found
   ```
3. **Canary exactly one node — talos-prod-cp2.** cp2 has the most headroom (42%
   requested) and hosts no control-plane-critical singleton that cp1 does not:

   ```
   kubectl label node talos-prod-cp2 falco-enabled=true
   ```
4. **Verify the probe actually attached** — this is the whole point of the canary.
   A Running pod is not sufficient evidence; Falco can start and fail to
   instrument:

   ```
   kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=100
   #   expect: "Starting health webserver", "Loaded event sources: syscall"
   #   FAIL if: "unable to find a prebuilt driver", "scap_init", "libbpf: failed"
   kubectl -n falco get pods -o wide            # Running, 0 restarts, on cp2 only
   kubectl top pod -n falco                     # CPU steady-state must be <5% of a core
   ```

   Watch for 24h. Falco's cost is workload-dependent; the syscall rate on a node
   running WordPress and game servers is not the rate on an idle node.
5. **Only then widen**, one node at a time, cp1 next and **cp3 last**, re-checking
   node memory pressure after each:

   ```
   kubectl label node talos-prod-cp1 falco-enabled=true
   #   wait 24h, check: kubectl describe node talos-prod-cp1 | grep -A5 'Allocated resources'
   kubectl label node talos-prod-cp3 falco-enabled=true
   ```
6. **Fleet rollout** (removing the `nodeSelector` from `values.yaml`) is optional
   and only worth doing once all three nodes have been labelled and stable for a
   week. Keeping the label-based gate is a legitimate end state — it makes
   "which nodes are instrumented" explicit and revocable with one command.

**Rollback at any stage:** `kubectl label node <node> falco-enabled-`. The pod is
evicted within seconds and no state is lost. If the Application itself misbehaves,
rename both files back to `.disabled`.

**Hardening follow-up, after the canary passes:** the chart renders the falco
container with `securityContext.privileged: true`. Setting
`driver.modernEbpf.leastPrivileged: true` swaps that for the specific capabilities
modern_ebpf needs (`CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_RESOURCE`), which is a
materially smaller blast radius for a DaemonSet on every node. It is deliberately
not set now: it is a second unverified variable on a deployment whose first
variable — does the probe attach at all — is still open. Change one thing at a time.

## If the canary fails

If `modern_ebpf` does not attach on Talos 6.18.24, do **not** fall back to
`kind: ebpf` (that is the configuration that already failed) and do not try
`kind: kmod` (Talos has an immutable, module-less OS). The remaining options are:

* `driver.kind: auto` and read what Falco selects, to capture a better error;
* a newer chart (`4.22.0` → Falco 0.41.0, or the 8.x/9.x line → 0.43/0.44) which
  may carry probe fixes for 6.18-series kernels;
* formally record Hubble (network flows) plus the now-shipped Kubernetes API audit
  trail (`kubernetes/monitoring/audit-log-shipper/`) as the **compensating control**
  for GAP-H8 in the Statement of Applicability, and close the gap that way. This is
  a legitimate outcome, not a failure — but it must be written down, not assumed.
