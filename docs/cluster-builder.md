# Cluster Builder — node roles & MetalLB VIPs

The Talos/Proxmox cluster is defined in `envs/<env>/cluster.yaml` and built by the
`terraform/modules/talos-cluster` module. This page documents the node **role**
model and how **MetalLB VIPs** are wired onto the control-plane nodes.

## Node roles

Every node in `cluster.yaml` has a `role`:

| Role      | etcd / control plane | Runs user workloads | Taint                                            |
|-----------|----------------------|---------------------|--------------------------------------------------|
| `control` | yes                  | no                  | `node-role.kubernetes.io/control-plane:NoSchedule` kept |
| `worker`  | no                   | yes                 | none                                             |
| `hybrid`  | yes                  | yes                 | control-plane taint removed after bootstrap      |

```yaml
nodes:
  talos-prod-cp1:
    proxmox_node: "pve1"
    ip: "10.0.0.11"
    vm_id: 9300
    role: hybrid          # control-plane + schedulable
    datastore: "local-lvm"
  talos-prod-worker1:
    proxmox_node: "pve2"
    ip: "10.0.0.21"
    vm_id: 9310
    role: worker          # workloads only
    datastore: "local-lvm"
```

### How roles map to Talos

- **Control-plane-capable** = `role != worker` (i.e. `control` or `hybrid`).
  These nodes get `machine_type = controlplane`, run etcd, and are used as
  talosctl/Kubernetes API endpoints.
- The cluster machine config sets `cluster.allowSchedulingOnControlPlanes = false`,
  so Talos taints every control-plane node at registration.
- After etcd bootstrap, `null_resource.untaint_hybrid_nodes` removes the
  control-plane `NoSchedule` taint from each `hybrid` node (Step 8b in
  `main.tf`). Pure `control` nodes keep the taint and therefore run no user
  workloads.
- Each VM is labelled with its role as a Proxmox tag (`control` / `worker` /
  `hybrid`) and in the VM description, so the topology is visible in the PVE UI.

### Validation rules

The module enforces (in `variables.tf`):

1. `role` must be one of `control`, `worker`, `hybrid` (or omitted — see back-compat).
2. At least one node must be control-plane-capable (`control` or `hybrid`).
3. The number of control-plane-capable nodes (`control` + `hybrid`) must be **odd**
   (1, 3, 5, …) so etcd can form a quorum.

The init wizard performs the same checks before writing `.env`.

### Back-compat with the legacy `controlplane` flag

Older `cluster.yaml` files used a boolean `controlplane` flag instead of `role`.
That still works: when `role` is omitted it is derived from `controlplane`:

| Legacy                | Derived role |
|-----------------------|--------------|
| `controlplane: true`  | `hybrid`     |
| `controlplane: false` | `worker`     |

This keeps the previous all-control-plane HA topology (3× `controlplane: true`,
all schedulable) behaving **identically** — three `hybrid` nodes, all untainted.

## MetalLB VIPs

MetalLB runs in L2 mode. Proxmox bridges drop gratuitous ARP for IPs that are not
assigned to a VM interface, which would otherwise prevent MetalLB from announcing
its VIPs. To work around this, the module appends every address in
`metallb_vip_addresses` to the **control-plane-capable** nodes' interfaces
(`local.node_addresses`), so the bridge allows ARP responses for those VIPs.

```yaml
metallb_vip_addresses:
  - "10.0.0.200/32"
  - "10.0.0.201/32"
```

> Choose VIPs inside your LAN but **outside** your DHCP pool. They are added to
> control-plane / hybrid node interfaces only — worker-only nodes do not carry VIPs.

If a cluster has no hybrids (e.g. a dedicated `control` + `worker` split), the
VIPs still land on the `control` nodes, which is correct: MetalLB speakers run
cluster-wide and only need one interface to answer ARP.
