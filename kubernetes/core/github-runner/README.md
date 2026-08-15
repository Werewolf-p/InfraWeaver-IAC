# github-runner — in-cluster GitHub Actions runner

**Status:** live 2026-08-15. Runner `in-cluster-platform` (agent id 29) on
`example-owner/InfraWeaver-platform`, labels `self-hosted, Linux, X64, in-cluster`.

## Why this exists

Self-hosted runner capacity lived only on the ops VM `10.0.0.108`, which is
being retired. This is a runner with no dependency on that host.

## What was actually measured (2026-08-15)

The ops VM runs **three** runner services, not one:

| systemd unit | dir | repo | runner name | labels | state |
|---|---|---|---|---|---|
| `actions.runner.example-owner-InfraWeaver-platform.management-host-platform` | `/opt/platform-runner` | `InfraWeaver-platform` | `management-host-platform` | `prod-worker`, `management-host` | running |
| `actions.runner.infraweaver` | `/opt/infraweaver-runner` | `InfraWeaver-base` | `management-host` | `ontwikkel`, `produktie`, `productie` | running |
| `actions.runner.example-owner-homelab_infrastructure.proxmox-runner` | `/home/runner/actions-runner` | `homelab_infrastructure` | `proxmox-runner` | — | **failed / dead** |

`/home/runner/actions-runner` is a **dead runner for a retired repo**. It is not
the runner for platform or base, and moving it would move nothing.

Note `produktie` **and** `productie` are both registered on the base runner —
a typo variant kept alive alongside the correct one. Anything replacing that
runner must carry both or the workflows that select the misspelling will hang.

## Why this runner does NOT carry the existing labels

**This is the important part. Do not "fix" it by adding them.**

Every self-hosted workflow on both repos reads state that exists only in the ops
host's `$HOME`. Giving a pod those labels does not move the work — it makes the
work silently wrong.

### `InfraWeaver-platform`

| Workflow | `runs-on` | Ops-host state it requires |
|---|---|---|
| `apply-machineconfig.yml` | `[self-hosted, management-host]` | `$HOME/InfraWeaver-platform` checkout, its `.env` (Proxmox token), `envs/$ENV/generated/talosconfig`, `$HOME/.tofu/state/platform-$ENV/terraform.tfstate` |
| `talos-upgrade.yml` | `[self-hosted, management-host]` | same |
| `update-kubeconfig.yml` | `[self-hosted]` | writes `~/.kube/config-active` **on the runner** |

`apply-machineconfig.yml` is declared `continue-on-error: true`. On a runner
without that state it **reports success while applying nothing** — the exact
failure mode this platform has been bitten by before. That is why it must not be
scheduled here.

### `InfraWeaver-base`

`tofu.yml` (plan + apply) and `full-redeploy.yml` use
`[self-hosted, <productie|ontwikkel>]` and both go through
`.github/actions/setup-infra`, which:

* runs `sudo apt-get install …` and optionally installs Docker — impossible in
  this pod by design (no sudo, no root, no docker socket, `drop: ALL`); and
* drives `make plan/apply`, whose backend is **local state on the ops host**:

```make
STATE_DIR   ?= $(HOME)/.tofu/state/$(ENV)
BACKEND_CFG := -backend-config="path=$(STATE_DIR)/terraform.tfstate"
```
with `terraform/backend.tf` = `backend "local" {}`.

A pod has an empty `$HOME/.tofu`. `tofu plan` there does not fail — it succeeds
and reports **"create everything"**, and `tofu apply` would attempt to build a
duplicate estate. Broken is recoverable; this is not.

### ⚠️ Open hazard: `update-kubeconfig.yml` uses bare `[self-hosted]`

`self-hosted` is implicit on every self-hosted runner and cannot be removed. So
that workflow can now land on **either** the ops host or this pod,
non-deterministically. On this pod it writes `~/.kube/config-active` to an
ephemeral layer and the change evaporates — a silent no-op.

It is `workflow_dispatch`-only, so it fires only when an operator runs it, but
**it should be pinned**: change its `runs-on` to `[self-hosted, management-host]`.
That is a one-line change in the platform repo and it is not made here.

## What has to happen before the ops VM can actually be retired

Moving the runner is the easy half. The blocking work is the state:

1. **OpenTofu state → a remote backend** (or at minimum a restorable, shared
   location). Until then `productie`/`ontwikkel` cannot run anywhere but that VM.
   Note `$HOME/.tofu/state/platform-productie/` is **already empty** and
   `productie/` holds only `.backup`/`.pre-redeploy` files — that state's real
   home should be established before anything depends on it.
2. **talosconfig → OpenBao.** Already there: `secret/platform/talosconfig`,
   property `talosconfig_b64`. `apply-machineconfig.yml` prefers a local file
   and falls back to the `TALOSCONFIG_PRODUCTIE` GitHub Secret; neither path
   reads OpenBao yet.
3. **`setup-infra` must stop needing `sudo`/apt/Docker** — pin tool versions
   into an image instead.
4. Then, and only then, register in-cluster runners carrying `management-host`,
   `prod-worker`, `productie`, `produktie`, `ontwikkel` and decommission the
   ops-host services.

## Security posture

See the header comments in `namespace.yaml`, `rbac.yaml`, `networkpolicy.yaml`
and `externalsecret.yaml` — the reasoning lives next to the control it justifies.
Summary, all verified live by a job run on this runner:

* `k8s_serviceaccount_token_present=NO` — no API token in the pod
* `whoami=1001:1001` — non-root, `drop: ALL`, no privilege escalation
* egress FQDN-scoped to GitHub only — no OpenBao, ArgoCD, registry, Talos
* `_work` on `emptyDir` — nothing a job writes survives or reaches Longhorn
* the pod holds **no GitHub admin PAT**, only its own runner RSA identity

**Accepted, documented gap:** Kyverno's `generate-default-deny-cnp` also
generates `auto-default-deny` here, which permits egress to all *in-cluster*
endpoints. Cilium policies are additive, so `networkpolicy.yaml` cannot revoke
that. Closing it means excluding `github-runner` from that generate rule — whose
`exclude` block is immutable, so it requires deleting and re-syncing the
ClusterPolicy. That is a cluster-wide change and is deliberately not bundled
with introducing a runner.

## Operating notes

* **Keep the image tag current.** 2.334.0 registered fine, reached "Listening
  for Jobs", then GitHub's broker returned 403 `"Runner version v2.334.0 is
  deprecated and cannot receive messages"` and the process exited. `gh api`
  still listed the runner while the pod CrashLooped — **watch the Deployment,
  not the GitHub runner list.**
* Registration does not pass `--disableupdate`, so the runner self-updates and
  survives the next deprecation on its own.
* `replicas` must stay `1` — one registered agent identity, one pod.
* Re-registration runbook is in `externalsecret.yaml`.
