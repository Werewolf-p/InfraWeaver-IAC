# In-cluster terminal — design and requirements

**Status:** phase 1 shipped 2026-08-15. Phases 2-5 specified, not built.
**Goal:** replace the ops VM (10.0.0.108) with in-cluster shells, reachable from
a browser, without the shell becoming a cluster takeover button.

Requirements below are drawn from four product categories researched on
2026-08-15: identity-aware access (Teleport, Boundary, StrongDM, Okta ASA/OPA),
cloud vendor shells (AWS SSM Session Manager, Azure Bastion/Cloud Shell, GCP
Cloud Shell/IAP, Cloudflare Access), self-hosted engines (ttyd, Guacamole,
Warpgate, Kasm, Wetty, GateOne, Sshwifty, xterm.js, asciinema) and cloud dev
environments (Coder, Gitpod, Codespaces, DevPod). Each requirement names the
product that made the case, so a future reader can re-check the premise rather
than trusting this document.

---

## 1. What "replace the VM" can and cannot mean

Three things on 10.0.0.108 argue in their own file headers against ever living
in the cluster, and the research agreed with all three:

| Workload | Why it cannot move into this cluster |
|---|---|
| Dead-man watcher (`/etc/cron.d/infraweaver-deadman`, every 5 min) | *"A heartbeat that stops when the cluster dies cannot be judged BY the cluster."* It exists because nothing detected the Watchdog heartbeat's absence. |
| etcd snapshot cron (`40 3 * * *`) | Holds a Talos `os:admin` credential, and backs up the cluster it would run inside. The Ansible inventory also explicitly rules out the Proxmox hosts as a destination. |
| Dispatch service (`:9876`) | It `git push`es to the deploy repo and runs an unattended coding agent. Inside the cluster it deploys to, a bad `/approve` can kill the thing that runs `/rollback`. |

**Therefore full decommission still requires a small off-cluster host.** What can
move is the interactive shell, the agent sessions, and image builds — builds via
the in-cluster BuildKit the dispatch service already uses (`buildctl` against
`build`:31234), not local Docker.

⚠️ The console→dispatch dependency is pinned to the literal IP `10.0.0.108` in
two places that must change in one commit: `DISPATCH_URL` in the console
Deployment, and the CIDR in
`kubernetes/catalog/infraweaver-console/base/ciliumnetworkpolicy-dispatch-egress.yaml`.

---

## 2. Requirements

Deduplicated across the four research streams. `MUST` = ship-blocking for the
phase that owns it. Provenance in the right-hand column.

### 2.1 Identity and credentials

| # | Requirement | Made by |
|---|---|---|
| C1 | The system MUST delegate human authentication to the existing OIDC provider and hold no password database of its own. | all four categories; Boundary's built-in password auth with no MFA is the anti-pattern |
| C2 | No credential that outlives a single session may sit on the target. | AWS SSM (none at all), EC2 Instance Connect (60s), GCP (ephemeral keypair), Cloudflare (CA public key only) — four incompatible mechanisms, one invariant |
| C3 | The system MUST hold exactly one standing credential — its own ServiceAccount — and that SA's `impersonate` verb MUST be restricted by `resourceNames`. | Teleport agent SA; StrongDM `sdm-user-impersonator` |
| C4 | A live session MUST terminate within a bounded time of its authorising credential expiring. | gap in **every** product surveyed; AWS documents the opposite outright |
| C5 | The default session identity MUST NOT have passwordless root. | negative requirement from AWS: `ssm-user ALL=(ALL) NOPASSWD:ALL` is the shipped default |

### 2.2 Authorisation

| # | Requirement | Made by |
|---|---|---|
| A1 | Authorisation MUST be evaluated against both the target and the session profile, so a user allowed a restricted shell is denied a full shell on the same target. | AWS SSM requires `ssm:StartSession` on instance ARN **and** document ARN |
| A2 | There MUST be at least two privilege tiers granted separately, one conferring no root. | GCP `compute.osLogin` vs `compute.osAdminLogin` |
| A3 | The shell MUST NOT be able to create workloads in namespaces hosting a more privileged ServiceAccount. | this cluster's own audit — see §3 |
| A4 | Time-bounded self-elevation SHOULD be supported: a privileged role requestable for a fixed TTL, logged as a distinct event. | Teleport Access Requests, StrongDM workflows — minus the second approver, which is meaningless at n=1 |

### 2.3 Attribution — the category's fault line

| # | Requirement | Made by |
|---|---|---|
| T1 | Every Kubernetes API call MUST be made via impersonation headers carrying the human's identity, never directly as the ServiceAccount. | Teleport; StrongDM Identity Aliases; Boundary's inability to do this is the cautionary tale |
| T2 | **Acceptance test:** a `kubectl exec` in the terminal MUST produce an apiserver audit event whose `impersonatedUser.username` is the operator's IdP username. | Kubernetes audit Event API |
| T3 | Any host-level identity MUST be a per-user principal, never a shared account. | Okta ASA provisions real per-user Unix accounts |

### 2.4 Audit and recording

| # | Requirement | Made by |
|---|---|---|
| R1 | Every interactive session MUST be recorded in a replayable format. | all four categories |
| R2 | Recordings MUST be plain-text and greppable, not video or base64. | Cloudflare asciicast v2 beats Azure's MP4 and Warpgate's base64 NDJSON on searchability |
| R3 | Transcripts MUST stream off the host **during** the session, not at close. | AWS `cloudWatchStreamingEnabled`; AWS S3 and Azure Bastion both upload only at close and lose the record if the broker dies |
| R4 | Transcripts MUST be written where the session's own identity has no write path. | AWS stages on the recorded host for 14 days; Azure forbids immutable storage on its recording container. Both fail this |
| R5 | Recording MUST be enforced at the broker, with no per-session opt-out. | Azure Bastion: "records ALL sessions" |
| R6 | A session MUST NOT start if the audit destination is unwritable, and MUST say so explicitly. | AWS fails this: the symptom is a blank screen |
| R7 | Input MUST NOT be captured by default. | output-only is safe by construction — a non-echoing prompt emits nothing; input capture turns a greppable file into a credential store |
| R8 | Structured per-action events MUST exist independently of the TTY recording. | Teleport `kube.request`; TTY replay is grep-hostile |
| R9 | Denied attempts MUST be logged, not only successes. | Teleport's own documented gap |
| R10 | Recording storage MUST have enforced retention and MUST NOT be able to fill the volume. | Boundary `retain_for_days`; Teleport storage-bloat reports |

### 2.5 Session lifecycle and UX

| # | Requirement | Made by |
|---|---|---|
| S1 | A session MUST survive browser refresh and network drop, reattaching to the same shell with scrollback. | AWS made `ResumeSession` a first-class API; Coder kills disconnected web terminals after **5 minutes** and its docs do not say so |
| S2 | The session MUST be a server-side object with a stable ID; the browser holds only a short-lived attach token. | AWS `SessionId` + `StreamUrl` + `TokenValue` |
| S3 | "Disconnected" and "terminated" MUST be distinct, and terminated sessions MUST NOT be resumable. | AWS |
| S4 | Idle timeout and absolute max duration MUST both exist and be independent. | AWS added `maxSessionDuration` because the idle timer resets on window resize |
| S5 | The idle timer MUST NOT reset on non-input events such as resize or reconnect. | AWS documents exactly this defect |
| S6 | Long-running work MUST run under a session manager by default, not as documented user responsibility. | Coder issue #15435 concedes tmux is the workaround and that it is "onerous" |
| S7 | `Ctrl+C` MUST copy when text is selected and send SIGINT when not. | Azure Cloud Shell |
| S8 | There MUST be a documented chord to return keyboard focus to the browser. | Azure Bastion `Ctrl+Shift+Alt`. Note Ctrl+W/T/N are user-agent-reserved and never reach page JS |
| S9 | Scrollback MUST be searchable and default above 1000 lines. | universal gap — **no** surveyed engine ships `@xterm/addon-search` |
| S10 | An opt-in screen-reader mode MUST be available. | xterm.js supports it; canvas-based engines (Guacamole, Kasm) cannot |

### 2.6 Engine and operations

| # | Requirement | Made by |
|---|---|---|
| E1 | The terminal MUST reject WebSocket handshakes whose `Origin` does not match the served host. | ttyd source: `check_host_origin()` is only called when `-O` is set |
| E2 | The backend MUST NOT be reachable on a path that bypasses the identity-aware proxy. | ttyd has **no** authentication of its own; `check_auth()` returns true unconditionally without `-c`/`-H` |
| E3 | Concurrent sessions MUST be capped. | ttyd `max_clients` defaults to 0 = unlimited, and every WebSocket forks a process |
| E4 | The engine version MUST have had a release within 12 months, or a named backport process MUST exist. | ttyd 1.7.7 is the newest release and is ~2.5 years old, with shell-injection and `sprintf` hardening unreleased on `main` |
| E5 | The engine MUST be deployable as a pinned self-built image. | follows from E4 |
| E6 | Adding recording and persistence MUST NOT require replacing the engine. | true for ttyd + wrapper; false for Guacamole/Kasm |
| E7 | The licence MUST permit the use without per-seat or per-concurrent-session fees. | Kasm Community caps at 5 sessions and forbids commercial use |
| E8 | A persistent home volume MUST have a documented size and a warn-before-reclaim policy. | GCP Cloud Shell: 5 GB, 120-day reclaim, email warning |
| E9 | Persistent volume identity MUST NOT derive from a mutable attribute. | Coder: renaming a user recreates and **wipes** the volume |
| E10 | The AI agent's reasoning loop SHOULD run outside the workspace so LLM credentials never enter it. | Coder is **removing** Tasks (from v2.37, Sept 2026) in favour of Agents, which runs the loop in the control plane |

### 2.7 Deliberately out of scope

Multi-party approval and four-eyes (one operator); moderated/joinable sessions;
Slack/Jira approval integrations; credential vaulting and checkout-checkin (the
short-lived-credential model makes the problem not exist); **in-stream shell
command blocking** — no vendor does it for shells, Teleport's attempt was
bypassed in a Doyensec audit and withdrawn, and building it would produce a
false security boundary; eBPF session recording (privileged agents, kernel
pinning, still bypassable); multi-hop worker meshes; per-protocol deep parsers;
device attestation and FIPS/FedRAMP artifacts; SCIM and access-certification
campaigns.

---

## 3. Phase 1 — shipped 2026-08-15

The audit found that a compromise of one signed-in browser session equalled full
cluster-admin **and** hypervisor-admin. Not through any of the four exclusions
`terminal-admin.yaml`'s header defends — all four were literally true — but
through grants the header never discussed.

**The escalation.** Cluster-wide `create` on `pods` plus `pods/exec`:

```
kubectl -n argocd run x --serviceaccount=argocd-application-controller ...
kubectl -n argocd exec -it x -- sh          # that SA holds * on */*
```

Create-a-pod-as-any-ServiceAccount plus exec-into-it *is* "widen yourself",
spelled in a different API group. The same pair reached a shell inside
`authentik-server`, and `kube-system`/`longhorn-system` are PSA `privileged`
**and** Kyverno-webhook-exempt, so a hostPath+privileged pod there reached node
root. Cluster-wide `apps` write was a third lever: Kyverno webhooks run
`failurePolicy: Ignore`, so deleting the admission controller disables
enforcement without touching a `kyverno.io` object.

Shipped:

* `kubernetes/platform/agent` brought under GitOps (`platform-agent-manifests`),
  and four orphaned `agent-admin-configmaps` RoleBindings deleted by hand —
  ArgoCD prune cannot collect what it never tracked.
* Namespaced write moved to `agent-admin-workloads`, RoleBound to
  `infraweaver-console`, `wordpress`, `game-hub`, `infraweaver-agent` only. That
  RoleBinding list is now the readable answer to "what can a stolen session
  break?" (A3)
* `argoproj.io` write removed — an Application is arbitrary cluster mutation
  laundered through a CRD.
* The credential ExternalSecret **deleted**, taking a Talos `os:admin` config, a
  Proxmox ops token and a GitHub push token out of `$HOME`; the Talos (50000)
  and Proxmox (8006) egress exceptions removed in the same commit. (C2)
* ttyd hardened: `-O` (E1), `-m 8` (E3), `scrollback=100000` (S9 partially),
  `screenReaderMode=true` (S10).
* Admin sessions recorded via `script` to `$HOME/.session-recordings`,
  output-only (R7), plain text and greppable (R2), 30-day retention pruned
  before each session (R10).

**Verified after rollout:** 12 escalation paths denied, 10 ordinary-work paths
still allowed, `agent-admin-creds` Secret gone entirely, both hosts return 302 to
Authentik, both shells `1/1 Ready` with the new flags visible in `ps`.

## 3b. Phases 2-4 — shipped 2026-08-15 (same day)

**Phase 2 — purpose-built image** (`images/agent-shell`). ttyd built from pinned
commit `2922cb8` (2026-08-12) rather than release 1.7.7 (2024-03-30), satisfying
E4/E5. tmux and asciinema baked in, so both shells now run `tmux new -A -s ops`
and a refresh **reattaches** instead of starting a new shell — S1/S6, the worst
property of the old setup, fixed.

⚠️ `DOCKER_BUILDKIT=0` in `build.sh` is load-bearing: this host uses the
containerd snapshotter, so BuildKit emits an OCI index plus attestation manifest
and Zot rejects both (`provided digest did not match uploaded content`, then
`manifest invalid` with provenance and SBOM disabled). The legacy builder pushes
clean.

**Phase 3 — attribution (partial).** `-H X-authentik-username` on the admin
shell, so `TTYD_USER` carries the signed-in identity and recordings are
attributable. Verified in-pod: **407 without the header, 200 with it**.

> ⚠️ **THE SENTENCE THAT USED TO FOLLOW HERE WAS WRONG, AND IT COST A BREACH.**
> It read: *"it fails closed, which also means a direct in-cluster connection
> bypassing the proxy gets no shell."* The premise is true and the conclusion
> does not follow. ttyd's `check_auth()` verifies the header is **present** and
> nothing else — no value, no signature, no notion of who set it. "407 without
> the header" only means an attacker has to type one. On 2026-08-16 an audit
> sent `curl -H 'X-authentik-username: totally-made-up-attacker'` from an
> unrelated pod in `monitoring` and got **HTTP 200**, then upgraded `/ws` to
> **101**. The read-only shell was worse: no `-H` at all, 200 to anyone.
>
> The deeper error is structural and worth more than the bug. §2.6 E2 says the
> backend must not be reachable on a path that bypasses the proxy, and this
> document treated the NetworkPolicy as satisfying it. That NetworkPolicy was
> decorative: the Kyverno-generated `auto-default-deny` CiliumNetworkPolicy
> additively re-allowed the whole `monitoring` namespace on every port, and
> **Cilium unions allow-rules**. So the header gate was safe only because of the
> network rule, and the network rule was never checked because the header gate
> existed. **Two controls that are each only safe because of the other are one
> control with extra words**, and neither will be audited on its own.
>
> Fixed 2026-08-16, as two controls that hold independently:
> * **Generated CNP** narrowed to the Prometheus pods on metrics ports only
>   (2112, 8080-8085, 9090-9999). 7681 is outside every range.
>   `kubernetes/core/kyverno/manifests/resource-governance-policies.yaml`.
> * **mTLS**: ttyd runs `-S -C -K -A`, so libwebsockets sets
>   `LWS_SERVER_OPTION_REQUIRE_VALID_OPENSSL_CLIENT_CERT` and the handshake
>   demands a certificate signed by a dedicated in-namespace CA whose only key
>   holder is Traefik. A forged header never reaches HTTP.
>   `kubernetes/platform/agent/manifests/certificate.yaml`.
>
> Measured after the fix, from a pod that **can** reach 7681 (so the network is
> deliberately not the control under test): TCP open, then every HTTP attempt
> dies at `curl exit 55` immediately after the server's `Request CERT (13)` —
> no status code at all. Through Traefik with the client certificate: 200, and
> `/ws` → 101.
>
> E2 is now satisfied by the transport, not by an assumption about the network.
> **Do not restate "`-H` fails closed" as an authentication property.** It is
> attribution, plus a fail-closed assertion that forward-auth-admin was
> traversed. That is all it has ever been.

T1/T2 (Kubernetes impersonation) remain open; this is attribution of the
*session*, not of each API call.

**Phase 4 — audit shipped off-pod.** A read-only sidecar tails every asciicast to
stdout, where Loki already scrapes container logs. Verified end to end: a canary
string written inside a recording appeared in the shipper's log stream within
seconds. This closes the delete-the-evidence-afterwards hole (R3, partially R4).

⚠️ Still not tamper-proof: Loki is not WORM, the shipper races the writer by a
few seconds, and a session that never starts is never recorded.

### What phases 1-4 do NOT satisfy

Stated plainly so nobody reads the above as more than it is:

* **T1/T2 — no attribution.** Every action still logs as ServiceAccount
  `agent-admin`. This is the single largest remaining gap.
* **R3/R4/R5 — recording is not an audit control.** It lands on the session's
  own PVC as the session's own uid: the recorded party can edit or delete it.
* **S1/S6 — no persistence.** ttyd SIGHUPs on disconnect; a refresh starts a new
  shell and kills what was running. tmux is absent from `node:22-bookworm` and
  the container is uid 1000 with no apt.
* **C4** — a live session outlives its authorisation, as in every surveyed product.
* **E4** — still running a ~2.5-year-old ttyd release.

### Corrections applied 2026-08-16

* **E4/E5 were not actually satisfied on 2026-08-15.** The purpose-built image's
  own ttyd could never start: the runtime stage installed `libwebsockets17` but
  not `libwebsockets-evlib-uv`, which Debian ships separately and which the
  build stage got only transitively from `libwebsockets-dev`. Every invocation
  died with `lws_create_context: unable to load evlib plugin evlib_uv`. The
  smoke test did not catch it because `ttyd --version` returns before any
  context is created. The pods looked healthy because `$HOME/bin` precedes
  `/usr/local/bin` on PATH and the persistent home volume still carried the
  curl-installed **ttyd 1.7.7 release from 2024-03-30** — the exact binary the
  image exists to replace. Fixed: the plugin is installed, the build smoke test
  binds a port and serves a request, both Deployments invoke
  `/usr/local/bin/ttyd` by absolute path, and the stale binary is deleted from
  the volume on every start.
* **C4 is now partially satisfied.** `TMOUT=900` gives an idle timer that does
  not reset on resize or reconnect (S5). A `timeout 3600` around the attach caps
  one connection at an hour; ttyd's client reconnects on socket close, and a
  reconnect is a fresh HTTP request back through `forward-auth-admin`, so the 1h
  Authentik cookie is genuinely re-checked — without killing the tmux session,
  so running work survives the re-auth. A daily reaper CronJob bounds the tmux
  server itself; `agent-admin` had no reaper at all before.
* **S1/S6 are satisfied** — tmux is in the image and both shells run
  `tmux new -A -s ops`, so a refresh reattaches.

---

## 4. Phase 5 — specified, not built

**Phase 2 — purpose-built terminal image.** Unblocks E4, E5, S6, S9. Pin a ttyd
commit from `main` (or backport), add `tmux`, `asciinema`, and an xterm.js bundle
carrying `@xterm/addon-search` via ttyd's `-I/--index`. The wrapper becomes
`asciinema rec --command "tmux new -A -s ops"`.

**Phase 3 — attribution.** Wire `forward-auth`'s identity header into ttyd
(`-H`), then make Kubernetes calls through impersonation restricted by
`resourceNames` (C3, T1, T2). Acceptance is the audit-event test in T2, not a
screenshot.

**Phase 4 — audit that survives its subject.** Stream transcripts off-pod during
the session (R3) to storage the session identity cannot write (R4), and fail the
session closed when the destination is unavailable (R6).

**Phase 5 — in-console surface.** An iframe is dead twice over: the console CSP
has no `frame-src` so frames fall back to `default-src 'self'`
(`src/proxy.ts:168`), and the terminal hosts serve `X-Frame-Options: DENY`. Next
16 in standalone mode cannot upgrade a WebSocket in a route handler. The workable
shape is xterm.js in the console with SSE down and POST up, the console server
holding an outbound WebSocket to the pod — all three patterns already exist in
the console (the feedback SSE proxy, the Game Hub xterm console, `execInWpPod`).

⚠️ Nav compliance is not optional and has already broken one build for fifteen
hours. A `/terminal` page needs: a real `page.tsx` (nav rows must point at live
internal routes), a `CORE_NAV_ACCESS` entry (`canAccessNavHref` fails closed —
no entry denies everyone, including `*`), an argued raise of `MAX_CORE_NAV_ROWS`
and `MAX_DASHBOARD_ROUTES`, and `withRoute` handlers declaring
`scope`/`rootScope` so the downward-only untriaged-handler ratchet does not move.

---

## 5. Engine verdict

**Keep ttyd, with the flags above and a self-built image.** Everything it gets
wrong is fixable with flags and a wrapper; nothing is architectural.

* **Guacamole** has the best native recording, but its terminal is a server-side
  emulator painting to canvas — no native selection, no browser Ctrl+F, no screen
  reader, clipboard via a side panel. A large daily-UX regression bought for a
  recording feature a wrapper provides.
* **Warpgate** is the better *product* (per-target authz, OIDC, native recording,
  real server-side resume with a 60s grace) and is the right answer **if this
  ever needs to be a bastion**. Not today: it wants its own hostname, its
  recordings are base64 NDJSON (not greppable), it is 0.x with bus factor 1, and
  it shipped five security advisories in 2026 — including one where any
  authenticated user could eavesdrop on the live recording stream. Revisit at 1.0.
* **Kasm** — wrong shape, Enterprise-only recording, Community forbids commercial
  use.
* **Wetty / Sshwifty** — strictly worse than ttyd; no recording, and Wetty needs
  `unsafe-eval` in its own CSP.
* **GateOne** — dead since 2017, unpatched critical RCE, will not install on
  modern Python. Steal its `.golog` idea only.
* **Coder** — would mean adopting Terraform-driven workspace provisioning to get
  a terminal, has no session recording at any tier, kills disconnected terminals
  after 5 minutes, and its agent token is over-scoped by default such that code
  in a workspace can read the owner's git credentials. Its **Agents** direction
  (agent loop in the control plane, no LLM credentials in the workspace) is worth
  copying as a pattern (E10).
