# Node lifecycle (add / decommission) — measured readiness

**Measured:** 2026-08-07, against the live hypervisors. Read-only except for one
throwaway VM created and destroyed deliberately (§3).
**Surface:** `/infrastructure` in the console, `POST /api/infrastructure/lifecycle`.

---

## 0. The short version

Previous handoffs said "add / remove node is unproven end-to-end". That is
wrong in one direction and needlessly alarming in another:

| Claim | Measured verdict |
|---|---|
| `create-vm` is unproven | **It is not implemented.** It refuses with a `LifecycleDependencyError`, by design, because no Talos template is registered. There is nothing to prove yet. |
| The Proxmox side might not work | **It works.** A VM was created, read back, started, stopped and destroyed through the same API calls the lifecycle ports make. |
| Proving it risks the control plane | **It cannot.** The ops credential holds no permission on the control-plane VMs at all. |

The gap is a **missing Talos template** — not missing plumbing, and not missing
privilege.

---

## 1. `create-vm` is deliberately unimplemented

`src/lib/infra-nodes/step-executors.ts`, `createDefaultPorts()`:

```
createVm: async () => missing(
  "Creating a node VM",
  "It needs a Talos template registered for the host; the add-node contract
   carries no template id and the console will not guess which guest to clone.
   Register the template (WP-11) and resume this run.")
```

Every other port in that file — `readVm`, `configureVm`, `startVm`, `stopVm`,
`destroyVm` — is wired to the real Proxmox API. `create-vm` is the only stub.

**Confirmed on the hypervisors — there is nothing to clone:**

```
proxmox     : 9300 talos-prod-cp1 (running, template=0)
              9301 talos-prod-cp2 (running, template=0)
microserver : 9302 talos-prod-cp3 (running, template=0)
```

Zero VMs with `template=1` on either host. The refusal message is accurate, not
defensive boilerplate.

---

## 2. The ops credential cannot touch the control plane

`iw-nodeops@pve!ops`, effective permissions (`GET /access/permissions?path=…`):

| Path | Granted |
|---|---|
| `/pool/infraweaver-nodes` | `VM.Allocate`, `VM.Clone`, `VM.PowerMgmt`, `VM.Config.{CPU,Disk,Memory,Network,Options,Cloudinit}`, `Datastore.{AllocateSpace,Audit}`, `Sys.Audit`, `VM.Audit` |
| `/vms/9300` (cp1) | **[] — nothing** |
| `/vms/9301` (cp2) | **[] — nothing** |
| `/vms/9302` (cp3) | **[] — nothing** |
| `/vms/9999` (arbitrary) | **[] — nothing** |
| `/vms` | **[] — nothing** |

Two consequences, both easy to assume wrongly in opposite directions:

- **A decommission run could not destroy a control-plane node even if every
  software interlock failed at once.** The credential has no rights on those
  VMs. That is a hypervisor-enforced backstop *underneath* the quorum /
  PodDisruptionBudget / storage-replica interlocks — not a second copy of the
  same check.
- **Node ops can only ever act inside `infraweaver-nodes`.** The rights hang off
  the pool, not off `/vms`. Anything WP-11 builds must be created **into that
  pool**, or this surface will not be able to manage it.

The VM listing endpoint still *shows* 9300–9302. Visibility is not authority —
read the effective-permission table above, not the VM list.

---

## 3. What was actually exercised, 2026-08-07

A throwaway VM backing no cluster node, on the 64 GB host, using the ops
credential, mirroring the calls the lifecycle ports issue:

| Step | Port it mirrors | Result |
|---|---|---|
| `POST /nodes/proxmox/qemu` (vmid 9390, `pool=infraweaver-nodes`) | what `createVm` will do post-WP-11 | **200** `UPID:…qmcreate:9390` |
| `GET …/status/current` | `readVm` | **200** `vmid=9390 name=iw-nodeops-drill-20260807 status=stopped` |
| `PUT …/config` `boot=order=scsi0;net0` | `configureVm` | **500** `invalid bootorder: device 'scsi0' does not exist` — a correct refusal; the drill VM has no disk. See §4. |
| `POST …/status/start` | `startVm` | **200**, `running` within 5 s |
| `POST …/status/stop` | `stopVm` | **200**, `stopped` within 5 s |
| `DELETE …/qemu/9390` | `destroyVm` | **200** `UPID:…qmdestroy:9390` |
| verify | — | 9390 absent from the host list **and** `/cluster/resources`; 9300/9301 still `running` |

Allocation, power management and destruction all work on this credential. The
`403` returned when re-reading the VM immediately after deletion is expected:
rights are pool-scoped, so a destroyed VM is not merely gone, it is out of scope.

---

## 4. One thing to check before WP-11 ships

`configureVm` is called by `configure-boot` with a hardcoded
`boot: "order=scsi0;net0"`. That assumes the cloned guest presents its disk as
**`scsi0`**. It is right for a Talos template built with a SCSI disk and wrong
for one built on `virtio0` or `sata0` — and it fails at `configure-boot`,
*after* `create-vm` has already made a machine. Check the template's disk bus
when registering it, or derive the boot order from the cloned config rather than
assuming it.

---

## 5. What is still NOT proven

- **The console route path.** `cluster:admin` is in `GROUP_DENIED_PERMISSIONS`,
  so no service-account token can mint it — deliberately. Driving
  `POST /api/infrastructure/lifecycle` needs a real interactive session with an
  active PIM elevation, and that was not exercised here. The gates' *refusal*
  behaviour was already covered; a successful pass *through* them was not.
- **`apply-machine-config` and `await-node-ready`.** Nothing here booted Talos
  or joined a node. The drill VM had no disk and never ran an operating system.
- **Decommission.** Not exercised at all. Its interlocks were read, not run.
