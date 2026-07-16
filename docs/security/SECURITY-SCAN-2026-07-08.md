# InfraWeaver Security Scan — 2026-07-08

Scope: console (122k LOC, 287 API routes), infraweaver-api, node, init, dispatch. Focus: RBAC + platform security. Method: 4 parallel security-reviewer agents; both CRITICALs re-verified by direct source read.

## CRITICAL

### C1 — Privilege escalation to Owner via generic user edit  (CONFIRMED)
`apps/infraweaver-console/src/app/api/users-config/[username]/route.ts:7,51-53` (+ bulk `users-config/route.ts`)
- Body schema `z.record(z.string(), z.unknown())`, merged raw into user record incl. `role_assignments` / `authentik_groups`. Bypasses `assignmentExceedsGranter` ceiling.
- Exploit: actor with `users:write` (built-in `platform-admin`, not `"*"`) PUTs own record with `role_assignments:[{roleId:"owner",scope:"/",...}]` → Owner.
- Fix: strip `role_assignments`/`authentik_groups`/`access_level` from generic edit schema (400 if present); only mutate via `grantRoleAssignment`.

### C2 — Unauthenticated feedback write + prompt-injection into auto-deploy  (CONFIRMED)
`apps/infraweaver-console/src/app/api/feedback/route.ts:87-94` → `services/infraweaver-dispatch/server.js:60,579-632`
- `x-infraweaver-upstream: 1` header (client-settable, no secret) skips auth. No rate limit. Entry chains to `/approve` which runs coding agent WITH Bash on `description` then `bumpProdPin` to live prod.
- Fix: HMAC/mTLS fork↔canonical instead of header; rate-limit; require diff review before prod pin; sandbox agent Bash (no cluster creds/outbound).

## HIGH
- H1 `rbac-assignments.ts:176` `revokeRoleAssignment` — NO ceiling check (grant has one at :115). `users:write` can revoke Owner `"*"` (lockout) or strip a Deny (escalation). CONFIRMED. Fix: mirror grant ceiling.
- H2 `game-hub/servers/broadcast/route.ts:45-50` — skips `assertCommandAllowed` (single-server routes enforce it). Capped operator runs any RCON on 20 servers + bypasses blocklist. Fix: per-server `assertCommandAllowed` in loop.

## MEDIUM
- M1 `rbac.ts:642-643,740-741,758-759` — principal-match fails open on empty id (not reachable today; engine not fail-closed). Fix: empty id = deny.
- M2 `insecure-fetch.ts:26-32` — default `redirect:"follow"` past allowlist → SSRF pivot to internal (k8s/ArgoCD/OpenBao) via compromised NAS 302. `authentik.ts:47` uses `redirect:"error"` (outlier). Fix: `redirect:"manual"` + re-validate Location.
- M3 `cluster-context.ts:18` — hardcoded fallback HMAC `"infraweaver-cluster-secret"` when AUTH_SECRET unset → forgeable cluster cookie. Fix: refuse start without AUTH_SECRET.
- M4 `feedback-host.ts:36,42-44` — trusts `x-forwarded-host`, fails open when `FEEDBACK_DASHBOARD_HOST` unset (contradicts api-helpers.ts:31 policy). Fix: key on `host`/signed header; no fail-open.
- M5 `rbac.ts:633-635` — legacy `platform-admins` group grants `"*"`, exceeds capped `platform-admin` role. Fix: fold role permission set, not `"*"`.

## LOW
- L1 `game-hub/servers/[name]/players/route.ts:138` kick/ban skips blocklist (fixed template).
- L2 `admin.ts:4-11` default `ADMIN_EMAILS="admin@example.com"` (dead code, no callers).
- L3 `scripts/init/server.py` self-update no GPG/sig check (transport-only). Fix: `git verify-commit` pinned key.
- L4 `app-route-access.ts:57-71` weak 3-char substring → wrong access-tier badge (display only).

## Verified solid
shellQuote+allowlists+array-exec everywhere; `/exec` ns+cmd allowlist; `validate.ts` path guard + in-container symlink recheck; no live committed secrets; `outbound-url.ts` blocks private IPs/userinfo/redirects, no TOCTOU; HMAC verifiers constant-time+replay-windowed+fail-closed; console→API boundary HMAC-signed.

Prior fix (assignmentExceedsGranter, audit 2026-07-03) covers grant only — NOT revoke (H1) or generic PUT (C1).
