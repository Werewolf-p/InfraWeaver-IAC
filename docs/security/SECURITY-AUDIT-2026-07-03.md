# InfraWeaver Security Audit — 2026-07-03

Full attacker-minded security review of both repositories:

- `InfraWeaver-platform` — Next.js console (274 API routes), `infraweaver-api` (privileged k8s backend), `infraweaver-node`, `infraweaver-init`, `infraweaver-dispatch` (feedback auto-fix)
- `InfraWeaver-infra` — GitOps manifests (~400 YAML), Terraform, Ansible, CI/CD

Method: six parallel specialist passes (authz coverage, injection/RCE/SSRF, RBAC engine, backend services, Kubernetes RBAC/workloads, IaC/CI-CD/secrets), each tracing input→sink and reading the real implementation. Per-area detail lives in `scratchpad/audit/{A..F}` during the session; this file is the durable consolidated record.

## Severity summary

| Severity | Count | Area |
|----------|-------|------|
| CRITICAL | 9 | RBAC privilege-escalation chain (2), console/API SA over-permission (2), network exposure of API (1), WebSocket hub no frame auth (1), dispatch prompt-injection→RCE (1), init server no auth (1), hardcoded Grafana/ArgoCD password (1), GH Actions script injection (2 files, counted as CI-1) |
| HIGH | 8 | game-hub symlink traversal, scope-blind PIM/group perms, self-grant re-grant, buildkit privileged NodePort, Kyverno audit-only, over-broad ArgoCD automation roles (2), PSA self-privileged namespaces, OpenBao plaintext HTTP + single-share unseal, public-mirror PII |
| MEDIUM | 6 | isFeedbackHost header spoof, feedback upstream-header bypass (latent), HMAC replay window, Proxmox insecure TLS, SSH no host-key check, unpinned Actions/images |
| LOW/INFO | several | open-redirect backslash, wiki:read default, cache revocation lag, stale gitleaks entries, etc. |

## What is already solid (do not regress)

- **Global auth gate** `src/proxy.ts` — every path requires a valid session except a small public allowlist; fail-closed on error, per-request CSP nonce, `X-Frame-Options: DENY`, HSTS, same-origin (CSRF) check + body-size limit + rate limit on all mutations, origin-checked login redirect.
- **RBAC scope/permission matching** — boundary-aware on `/` and `:` (`/game-hub` ≠ `/game-hub-secrets`; `game-hub:*` ≠ `game-hub-other:read`); deny-wins; scoped built-in roles cannot reach the escalation tier; PIM expiry evaluated live every request; no fail-open catch blocks.
- **Console↔API HMAC** — SHA-256 over `ts:userId:roles:clusterId`, `timingSafeEqual`, and the API **re-derives** elevated permissions server-side (never trusts the roles header blindly). A cluster pod cannot forge identity without `CONSOLE_API_SECRET`.
- **`/exec`** — `cluster:admin` gated, fail-closed namespace allowlist + exact-match command allowlist, argv (no shell).
- **Injection hygiene** — game-hub console/RCON/wp-cli all allowlist-first (throw on mismatch), passwords via stdin; SSRF guard resolves-then-connects-by-IP (defeats DNS rebinding), blocks private ranges, https-only; only one `dangerouslySetInnerHTML` (static content).
- **Secrets hygiene** — no real plaintext secrets committed; ExternalSecrets Operator + OpenBao is the pervasive path; catalog `secrets.yaml` are `"change-me"` placeholders; `.env` is gitignored/untracked.
- **Node hub protocol (node side)**, OpenBao `system:auth-delegator`, `infraweaver-node` least-privilege RBAC, hardened automation CronJobs — good templates to copy.

---

## CRITICAL findings

### C1. RBAC privilege-escalation chain — self-service, permanent, no approver
A 60-minute PIM `cluster-admin` activation (or any narrow `rbac:admin`/`cluster:admin` grant) converts into indefinite near-total platform control using only self-service endpoints:

1. **Custom-group creation has no privilege ceiling** — `src/app/api/groups/route.ts:34-58`, `src/lib/access-store.ts` `createGroup/updateGroup`. Gated only by `rbac:admin`/`cluster:admin` + a 6-item deny-list. The granter can put ~25 resource-tier permissions they never held into a group, self-add, and keep them permanently (survives PIM expiry via `computeExtraPermissions`). The code comment at `rbac.ts:66-73` names this exact threat; the deny-list doesn't close it.
2. **PIM eligibility grants have no ceiling and no self-grant guard** — `src/app/api/pim/eligibility/route.ts:56-86`, `access-store.ts createEligibility`. Self-grant eligibility for `rbac-admin`/`security-admin`/`platform-updater`, then self-activate, re-activatable forever (eligibility never expires).
3. **Custom-group/PIM perms ignore scope** — `src/lib/session-rbac.ts:53-87`. `extraPermissions` are checked without the `scope` argument → every group/PIM escalation is implicitly cluster-wide.
4. **Self-grant re-grant defeats time-boxing** — `src/lib/rbac-assignments.ts:108-167`. A holder of a time-boxed root `platform-admin`/`owner` can self-grant the same role with no `expiresAt` before it lapses; `assignmentExceedsGranter` passes trivially (same role).

**Fix:** ceiling-check `createGroup/updateGroup/createEligibility/createResourceAssignment` against the granter's own effective permissions at `/`; block self-grant of eligibility/assignments unless backed by a non-PIM, non-self grant; thread scope into extra-permission checks (or enforce root-only + treat as the ceiling). Also apply the group deny-list to `ResourceAssignment.permissions` (C5, currently dead code but a landmine).

### C2. `infraweaver-api` / `infraweaver-console` ServiceAccounts are cluster-admin-equivalent
`kubernetes/catalog/infraweaver-api/base/rbac.yaml`, `.../infraweaver-console/base/rbac.yaml`. Both SAs hold cluster-wide Secrets get/list/watch **and** create/update/patch/delete, cluster-wide Deployment/StatefulSet/**DaemonSet** CRUD, ArgoCD `Application`/`AppProject` write (console: also `create`), and console adds CiliumNetworkPolicy CRUD + Namespace delete. Escalation from a compromised console/api pod: read every Secret; plant a privileged hostPath DaemonSet in `kube-system` → node root; or repoint an ArgoCD `Application` → the application-controller (broad built-in RBAC) applies attacker manifests → `ClusterRoleBinding` to cluster-admin.
**Fix:** split into namespace-scoped Roles per feature; never grant cluster-wide `secrets` — use `resourceNames`/per-namespace; remove `argoproj.io` write (use ArgoCD's scoped API instead); scope CiliumNetworkPolicy CRUD by name. **Validate actual usage before narrowing — see remediation note.**

### C3. `api.int` reachable by any pod without SSO
`external-routes/manifests/10-routes-vpn-only.yaml` + `01-middlewares.yaml` + `infraweaver-api/base/networkpolicy.yaml`. `api.int.$BASE_DOMAIN` is exempted from Authentik forward-auth and trusts the `internal-cluster-only` middleware, whose allow-list is the **entire pod CIDR `10.244.0.0/16`**; the API NetworkPolicy also allows all of namespace `traefik`. Any pod can reach the privileged API backing C2 without a session — the network counterpart of header-trust.
**Fix:** mTLS or short-lived signed service token console→api; narrow NetworkPolicy `from` to the console pod identity only; terminate the node-agent WS on a distinct port with its own mutual auth.

### C4. BuildKit: privileged, rootful, unauthenticated NodePort
`kubernetes/core/buildkit/buildkit.yaml`. `privileged: true` + `--allow-insecure-entitlement security.insecure` exposed via NodePort 31234, **no TLS/auth**. Anyone routing to `<node-ip>:31234` gets root RCE in a privileged container → node compromise. Kyverno privileged policy is Audit-only (E6) so it's admitted.
**Fix:** buildctl TLS client-cert auth; move to ClusterIP + jump host/VPN; verify Cilium actually gates NodePort (kube-proxy-replacement often DNATs before policy) and add a host-firewall `CiliumClusterwideNetworkPolicy` for 31234.

### C5. Agent WebSocket hub verifies no inbound frames
`apps/infraweaver-api/src/lib/agent-registry.ts:158-182, 279-314`. `/v1/ws/cluster/:clusterId` is wired on the raw `http` `upgrade` event, outside `authMiddleware`. `handleCluster` registers the socket for any `clusterId` (existing or new) with no signature/token/challenge, and `message` frames (`heartbeat`/`response`) are trusted unsigned — while the node side *does* sign. A foothold pod connects as any cluster, hijacks its `_agents` slot, and the next admin RBAC sync (`routes/rbac-sync.ts`) pushes the full `infraweaver-users` ConfigMap to the attacker.
**Fix:** verify every post-registration frame's `sig` against the stored per-cluster public key; reject connections for a `clusterId` with no registered key; add connect-time challenge/response.

### C6. Dispatch feeds attacker feedback into an LLM with Bash + full env + prod push
`services/infraweaver-dispatch/server.js`. Attacker-controlled feedback `description`/`pagePath`/`note` is composed into the prompt for `claude`/`copilot` run with `Bash` in the default allowlist and the **full `process.env`** (incl. `DISPATCH_SECRET` + git push creds); `/approve` ships the result to the live prod image pin. Prompt-injection → credential exfil / malicious commit / supply-chain. Also `GET /runs*` transcripts are unauthenticated (IP-allowlist only). And `authedBody` **fails open** if `DISPATCH_SECRET` is unset (F4).
**Fix:** run feedback-triggered agents in a scrubbed-env sandbox (no secret/git creds), drop `Bash` from the default allowlist, require a diff policy-check before `/approve` can build; add HMAC to `GET /runs*`; make `DISPATCH_SECRET` mandatory (exit on unset in prod).

### C7. `infraweaver-init` bootstrap server: no authentication
`scripts/init/server.py` binds `0.0.0.0:8080`; only a CORS-origin check (browser protection, not network). `GET /api/get-kubeconfig` returns the **cluster-admin kubeconfig**; `GET /api/load-env` returns every provisioning secret (Proxmox/Cloudflare/DO/Hetzner tokens, SSH keys, admin passwords) in cleartext; `POST /api/save-env`, `/api/deploy`, `/api/self-update` all unauthenticated. One `curl` = full cluster + cloud-credential takeover.
**Fix:** bearer token generated at startup (printed once), checked on every request; bind `127.0.0.1` by default; ensure `cleanup-init` actually kills the process.

### C8. Hardcoded Grafana + ArgoCD admin password in Ansible
`ansible/playbooks/openbao.yml` (both repos). Seeds `secret/platform/grafana#admin-password` and `secret/platform/argocd#admin-password` with the literal `"Unified*Presume8*Sudoku*Karate"` — every other seed uses `DEMO-PLACEHOLDER-replace-before-use`. ExternalSecret/values confirm this path feeds the real Grafana (and ArgoCD) admin login → GitOps control-plane takeover.
**Fix:** rotate both credentials now; purge the string from git history (both repos); replace with the placeholder convention or a runtime `openssl rand`.

### C9. GitHub Actions script injection on self-hosted runners
`.github/workflows/update-kubeconfig.yml:22,41,60` and `apply-machineconfig.yml:73`. `${{ github.event.inputs.* }}` is interpolated directly into `run:` shell text (not via `env:`) on `[self-hosted, management-host]` runners with LAN access to Talos/Proxmox/cluster-admin. Anyone who can `workflow_dispatch` gets RCE + credential theft on the management host. `update-kubeconfig.yml` also takes a raw cluster-admin kubeconfig as an unmasked input; `apply-machineconfig.yml` lacks an `environment:` protection gate.
**Fix:** pass inputs only via `env:` and reference `$VAR`; add `::add-mask::`/artifact for kubeconfig; add `environment:` gate.

---

## HIGH findings

- **H1 — game-hub symlink path traversal → SA token exfil.** `src/lib/validate.ts` validates container paths lexically, never resolves symlinks. A `game-hub:files` user uploads an archive with a symlink → `/var/run/secrets/.../serviceaccount`, extracts (`files/route.ts` PATCH extract), then reads via `files/content` (`base64 <path>` follows the link). No pod sets `automountServiceAccountToken: false` (incl. the ephemeral reader pod). **Fix:** `realpath -m` re-validation inside the container before read/write; reject symlink entries on extract; set `automountServiceAccountToken: false`.
- **H2 — scope-blind PIM/group perms** (part of C1.3) — `session-rbac.ts:53-87`.
- **H3 — self-grant re-grant** (part of C1.4) — `rbac-assignments.ts`.
- **H4 — Kyverno hardening policies all `Audit`** — `core/kyverno/manifests/cluster-policies.yaml`. None enforce; scoped only to `catalog-app` namespaces. **Fix:** flip `disallow-privileged-containers`/`host-namespaces`/`hostpath-volumes`/`privilege-escalation` to `Enforce` with a documented exception list; broaden namespace coverage. **Rollout risk — see note.**
- **H5 — over-broad ArgoCD automation roles** — `node-automation.yaml` (cluster-wide `patch` on apps), `self-healer.yaml` (all-namespace ConfigMap write). Scripts self-restrict; RBAC doesn't. **Fix:** `resourceNames`/namespaced Roles.
- **H6 — PSA self-privileged namespaces** — jellyfin/plex/homeassistant/wordpress set their own `pod-security…enforce: privileged`, bypassing the documented single-source-of-truth `core/psa/namespace-labels.yaml`. **Fix:** reject PSA labels in app namespace manifests in `validate-iac.sh`; centrally track the few that legitimately need privileged.
- **H7 — OpenBao plaintext HTTP + single-share unseal** — `ansible/playbooks/openbao.yml`. `0.0.0.0:8200 tls_disable=true`; `key-shares=1` with unseal key + root token in plaintext on the same VM. **Fix:** enable TLS / bind loopback+proxy; KMS or multi-share unseal off-host; rotate.
- **H8 — public-mirror PII leak** — `scripts/sync-to-public.sh` strip-list omits root `users.yaml` (real name/email); only an unauditable gitignored deny-list protects it. **Fix:** add `users.yaml` to the explicit strip-list.
- **H9 — long-lived static SA token pushed to Vault** — `infraweaver-console/base/service-account.yaml`. Non-expiring token, copy in OpenBao, SA currently unbound. **Fix:** projected/TokenRequest short-lived tokens; remove if unused.

## MEDIUM / LOW (abridged)

- **M1** `isFeedbackHost` trusts `X-Forwarded-Host` (in-cluster spoof) — routes still need `rbac:admin`, so isolation-control bypass not full authz bypass. `src/lib/feedback-host.ts`.
- **M2** `POST /api/feedback` skips auth on `x-infraweaver-upstream: 1` header — dead today (proxy.ts 401s first) but a landmine if `/api/feedback` is ever allowlisted. Use HMAC.
- **M3** API HMAC has no replay cache (±30s window) — `apps/infraweaver-api/src/middleware/auth.ts`. Add nonce/replay set.
- **M4** Proxmox `insecure = true` (TLS verify off); **M5** SSH `StrictHostKeyChecking=no` everywhere; **M6** all Actions + base images on mutable tags (pin to SHA/digest).
- **L1** open-redirect backslash bypass in `src/app/api/auth/start/route.ts` (not exploitable via current Auth.js path; fix for defense-in-depth). Note: `proxy.ts` login redirect is already safe (origin-checked).
- **L2** implicit `wiki:read` for any authenticated user (`rbac.ts:622-624`) — confirm intent.
- **L3** ~60s revocation cache lag on `users.yaml`-sourced assignments.
- **L4** legacy admin trusts literal Authentik group name `platform-admins` (IdP trust boundary — lock down group creation/membership there).
- **L5** stale `.gitleaksignore` entries; **L6** `etcd-metrics-logger` CronJob unhardened in kube-system; **L7** duplicate game-hub Role manifest.

---

## Remediation status

Legend: ✅ fixed in this pass · 📝 documented, needs operator action/validation · ⚠️ prepared but rollout-risky on live GitOps cluster

| ID | Item | Status |
|----|------|--------|
| C1 | RBAC privilege-ceiling on groups create+update, PIM eligibility, resource assignments (shared `permissionsBeyondCeiling` helper + deny-list on resource assignments) | ✅ **fixed** — console typechecks clean |
| C8 | Hardcoded Grafana/ArgoCD admin password → `DEMO-PLACEHOLDER` | ✅ **fixed in git** · 📝 ROTATE live creds + purge history |
| C9 | GH Actions script injection — inputs via `env:` + env-name whitelist (both workflows) | ✅ **fixed** |
| C6 | Dispatch fail-closed startup guard (refuse to start without `DISPATCH_SECRET`) | ✅ **fixed**; `/runs*` HMAC + env-scrub/Bash-drop sandbox 📝 (needs caller change) |
| H1 | game-hub reader pod `automountServiceAccountToken: false` | ✅ **fixed** (defense-in-depth); realpath re-validation on file read/write 📝 |
| H8 | `sync-to-public.sh` strips `users.yaml` | ✅ **fixed** |
| L1 | auth/start open-redirect backslash bypass | ✅ **fixed** |
| C2 | Narrow `infraweaver-api`/`console` ClusterRoles | 📝 validate real usage first — wrong narrowing breaks the console (live GitOps auto-sync) |
| C3 | mTLS/signed-token + NetworkPolicy narrowing on `api.int` | 📝 architecture change |
| C4 | BuildKit auth / remove bare NodePort | ⚠️ infra — stage in maintenance window (runner build path) |
| C5 | WebSocket hub inbound-frame signature verification | 📝 deferred — wrong impl disconnects live nodes; apply + test against a node |
| C7 | init server bearer-token auth + loopback bind | 📝 touches every bootstrap-wizard endpoint; apply + test the wizard |
| H4 | Kyverno `Enforce` | ⚠️ would block existing privileged workloads — staged rollout + exception list |
| H5 | ArgoCD automation role `resourceNames`/namespaced scoping | 📝 low risk, not yet applied |
| M3 | API HMAC replay/nonce cache | 📝 not yet applied |

**Operator actions that code cannot perform (do these):**
1. Rotate Grafana + ArgoCD admin credentials; rotate anything served over OpenBao plaintext HTTP.
2. Purge `"Unified*Presume8*Sudoku*Karate"` and the historical `generated/kubeconfig` blob from git history (both repos) with `git filter-repo`/BFG.
3. Confirm both GitHub repos are Private and the public mirror carries no prior `users.yaml` PII.
4. Enable OpenBao TLS + KMS/multi-share unseal.
5. Validate the real k8s API/console permission usage, then narrow the ClusterRoles (C2) and stage Kyverno Enforce (H4) behind a maintenance window.
