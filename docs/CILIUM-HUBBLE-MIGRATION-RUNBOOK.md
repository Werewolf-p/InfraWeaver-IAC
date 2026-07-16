# Cilium + Hubble Migration Runbook (flannel → Cilium)

Status: **READY — gated on valid Talos credentials for the live cluster.**

This runbook turns the cluster from "no network enforcement" (Talos-managed
flannel, which does not enforce NetworkPolicy) into a default-deny, zero-trust
dataplane with FQDN egress and Hubble flow visibility. It is written for the
*current* live cluster as discovered on 2026-06-28.

## Why this is needed

flannel is a pure overlay and enforces **nothing**. The cluster currently has
~90 NetworkPolicy objects (full default-deny sets in `argocd`, `authentik`,
`cert-manager`, `openbao`, …) that are **all inert** — they look like a firewall
but block no traffic. Standard NetworkPolicy also cannot express FQDN egress
("WordPress may reach only `*.wordpress.org`"), and there is no flow visibility
for a "recently blocked → allow" admin workflow. Cilium + Hubble solves all
three.

## Discovered environment (verify before executing)

| Fact | Value |
|------|-------|
| Talos version | v1.13.0 (talosctl client v1.12.7 on box) |
| Kubernetes | v1.35.4 |
| Nodes (control-plane, schedulable) | `talos-prod-cp1` 10.0.0.90, `cp2` 10.0.0.91, `cp3` 10.0.0.92 |
| Current CNI | `ghcr.io/siderolabs/flannel:v0.28.4` (Talos default) |
| kube-proxy | running (Talos-managed) |
| Pod CIDR | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` |
| GitOps | ArgoCD ← `github.com/example-owner/InfraWeaver-infra` @ `main`, auto-sync + selfHeal |

## BLOCKER — Talos credentials

Every `talosconfig` on the management box fails CA verification against the live
nodes (`x509: certificate signed by unknown authority`). The June-13 rebuild
generated fresh machine secrets that were never persisted here. The Talos API
(port 50000) is reachable, so only the credential is missing.

**To unblock:** place a working talosconfig for the current cluster at
`~/.talos/config` (or export `TALOSCONFIG`). It almost certainly lives on the
init/runner VM that ran the June-13 redeploy. Verify with:

```bash
talosctl -e 10.0.0.90 -n 10.0.0.90 get members   # must list talos-prod-cp1/2/3
```

Do not run `talosctl gen secrets` / re-bootstrap — that rotates the PKI and will
break the running cluster.

## Migration strategy

Small 3-node, control-plane-only cluster. Two viable approaches:

- **A. Maintenance-window swap (simplest, brief cluster-wide blip).** Patch all
  nodes to `cni: none`, install Cilium, reboot nodes. ~5–10 min of dataplane
  disruption while pods reconverge. Acceptable for a homelab.
- **B. Per-node rolling migration (no full outage, more steps).** Cordon/drain
  one node, patch + reboot it, let Cilium take it, uncordon; repeat. Workloads
  shuffle between nodes during the window.

This runbook uses **B** (rolling) as the default and notes the A shortcuts.

Cilium is installed **without kube-proxy replacement initially** (`kubeProxyReplacement=false`,
Talos kube-proxy stays) to minimise migration variables. KPR can be enabled
later as a separate, independent change.

## Pre-flight (no changes)

```bash
export TALOSCONFIG=~/.talos/config
talosctl -e 10.0.0.90 -n 10.0.0.90 get members        # creds work
kubectl get nodes -o wide                                 # baseline
velero backup create pre-cilium-$(date +%Y%m%d%H%M) --wait   # safety net (velero is installed)
kubectl get netpol -A | wc -l                             # record current (≈90)
```

## Step 1 — Land the Cilium GitOps bundle (safe, no dataplane change yet)

The Cilium HelmRelease/manifests live at `kubernetes/core/cilium/` and are added
to the core app-of-apps. Because Talos still owns the CNI (`cni: flannel`),
ArgoCD applying the Cilium objects does nothing to the running dataplane until
Step 2 flips the machine config — so this commit is safe to merge first.

Cilium values pinned for this cluster:

```yaml
# kubernetes/core/cilium/values.yaml (key fields)
ipam:
  mode: kubernetes                 # match existing controller-manager node-CIDR allocation
k8sServiceHost: 10.0.0.90         # any reachable control-plane (or localhost:7445 if KPR later)
k8sServicePort: 6443
kubeProxyReplacement: false        # keep Talos kube-proxy for first cut
cni:
  exclusive: false                 # tolerate flannel leftovers during transition
securityContext:                   # required on Talos
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
hubble:
  enabled: true
  relay:
    enabled: true
  metrics:
    enabled: [dns, drop, tcp, flow, port-distribution, icmp, "httpV2:exemplars=true;labelsContext=source_namespace,destination_namespace"]
  ui:
    enabled: false                 # console feature consumes Hubble Relay directly
ipv4NativeRoutingCIDR: 10.244.0.0/16
```

After merge: confirm ArgoCD shows `core-cilium` Synced and Cilium pods are
`Pending`/`CrashLoopBackOff` is expected until Step 2 (no CNI handoff yet).

## Step 2 — Flip Talos CNI to none (per node)

For each node (start with `cp3` 10.0.0.92, keep etcd quorum on the other two):

```bash
export TALOSCONFIG=~/.talos/config
N=10.0.0.92

kubectl cordon talos-prod-cp3
kubectl drain talos-prod-cp3 --ignore-daemonsets --delete-emptydir-data --timeout=300s

# Patch CNI to none for this node (machine config)
cat > /tmp/cni-none.yaml <<'EOF'
cluster:
  network:
    cni:
      name: none
EOF
talosctl -e $N -n $N patch mc --patch-file /tmp/cni-none.yaml

talosctl -e $N -n $N reboot --wait     # node returns NotReady (no CNI)
# Cilium DaemonSet schedules and provides CNI:
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl wait --for=condition=Ready node/talos-prod-cp3 --timeout=300s
kubectl uncordon talos-prod-cp3
```

Verify the node is healthy and pods on it have IPs, then repeat for `cp2`
(10.0.0.91) and finally `cp1` (10.0.0.90). Never have more than one
control-plane node down at a time (etcd quorum is 2/3).

Approach-A shortcut: skip cordon/drain, patch all three, reboot all three.

## Step 3 — Remove flannel remnants

```bash
kubectl -n kube-system delete ds kube-flannel
kubectl get pods -A -o wide | grep -v Running   # nothing stuck
cilium status --wait        # if cilium CLI installed; else check ds + hubble pods
```

## Step 4 — Hubble flow visibility

```bash
kubectl -n kube-system get pods -l k8s-app=hubble-relay   # Running
# Relay is reached in-cluster at hubble-relay.kube-system.svc:80 (gRPC).
# The console "blocked → allow" feature consumes this; no UI needed.
```

## Step 5 — Verify enforcement is now real

```bash
# Pick a namespace with a default-deny-ingress policy (e.g. authentik) and prove
# a cross-namespace probe that previously succeeded now fails:
kubectl run probe --rm -it --image=nicolaka/netshoot --restart=Never -- \
  curl -m5 http://authentik.authentik.svc   # expect timeout (deny enforced)
```

If this now blocks where it didn't before, enforcement is live.

## Rollback

Per node (or all at once for approach A):

```bash
export TALOSCONFIG=~/.talos/config
N=10.0.0.92
cat > /tmp/cni-flannel.yaml <<'EOF'
cluster:
  network:
    cni:
      name: flannel
EOF
talosctl -e $N -n $N patch mc --patch-file /tmp/cni-flannel.yaml
talosctl -e $N -n $N reboot --wait
```

Talos reinstalls its managed flannel on boot. Then in GitOps set `core-cilium`
to a disabled/absent state (or `kubectl -n kube-system delete ds cilium`) and
re-sync. The cluster returns to its pre-migration (unenforced) state.

## After migration

Proceed to the policy baseline (`kubernetes/core/network-policies/` —
default-deny + allow-DNS + allow-from-Traefik per workload namespace), the
WordPress FQDN egress CiliumNetworkPolicy, and enable the console
"recently blocked → allow next time" feature (it lights up once Hubble Relay is
reachable). These are authored separately and are inert-but-harmless until
Cilium is the dataplane.
