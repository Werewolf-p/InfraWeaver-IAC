# WordPress Staging — design

**Status:** proposed 2026-08-16; **built 2026-08-16 (evening)** — §10 steps 1, 2
and 4 are implemented and tested; step 3 is implemented but **unreachable**; step
5 (hi2 soak) has not started. Nothing is deployed yet.

## Build status — 2026-08-16 evening

| §10 step | State | Note |
|---|---|---|
| 1. Connector seal, `staging.state.set`, tab/outbox | **shipped** | `4b5b352f` (0.57.0), popup `1aae0934`; connector now 0.59.0 |
| 2. Console `lib/staging/`, routes, sweep CronJob | **built, uncommitted** | all 7 hops traced; the sweep never consumes a request from a non-enabled site, pinned by a mutation-checked test |
| 3. Merge Lane completion + review UI | **built, UNREACHABLE** | lanes shipped in `c2283f8c`; `ChangesetReviewPanel` is imported by nothing — see the trap below |
| 4. Environments/Manage UI, expiry warnings | **built** | 8 components; extend-TTL and merge status deliberately excluded |
| 5. hi2 soak, then per-site enablement | **not started** | |

⚠️ **The flag in §10 step 3 is already on.** `changesetsEnabled()` and
`stagingEnabled()` both fall through to `platformDefaultFor()`, and the live
console runs `PLATFORM_ENABLE_ALL=1` — so "then `WORDPRESS_CHANGESETS_ENABLED=true`"
is already satisfied here, and **writing either variable into the manifest would
PIN it**, removing the runtime kill switch for the feature whose failure mode is
copying production databases. Neither is set, deliberately.

⚠️ **Step 3's real blocker is scope, not the flag.** A changeset session lives on
the STAGING site, and `wordpressSiteScopeFrom`
(`apps/infraweaver-console/src/app/api/v1/_lib/scopes.ts:73`) resolves scope
literally as `/wordpress/sites/${id}`, so reviewing a merge means calling a scope
no operator holds a grant on. The fix is a resolver mapping a `--stg-`/`--sbx-`
derived id to its PARENT's scope, which is defensible because parent
`wordpress:admin` already governs whether the clone exists at all. Until then the
review panel cannot be mounted.

⚠️ **Before these manifests may be pushed:** seed `wordpress-staging-cron-token`
into OpenBao FIRST — the console ExternalSecret is `deletionPolicy: Retain`, so
one missing property aborts the sync for all 36 keys — and ship the console image
BEFORE the CronJob, or every two-minute tick 404s into a failed Job.

**Operator's requirement, verbatim (abridged):** "staging functionality, so someone can make a staging site (fully behind authentik) with a simple press on the button in the plugin in wordpress itself … once ready someone can set it to prod … seeable in infraweaver in the manage part … make sure that it won't make additional images in CDN that are not bound to a website. fully plan this out."

---

## Design in one page

**A staging site is an enrolled, longer-lived sandbox with a merge lane back to production.** It is not a new mechanism: it is the existing sandbox spawn pipeline (`lib/sandbox/spawn.ts`) with a different seal, plus the existing — fully built, currently switched-off — **Merge Lane** changeset system (`lib/changesets/*`, connector `class-iwsl-changeset*.php`) as the "set it to prod" path.

- **Identity:** `<parent>--stg-<id>`, host under the existing wildcard DNS. Same double-label ownership model as sandboxes, plus `role=staging` on the record. One staging per site, ever.
- **Provisioning:** the sandbox pipeline verbatim — `createSite` with `authMode: "full"` **forced** (Authentik forward-auth on everything, non-negotiable), pod-to-pod clone of DB (`mariadb-dump` via `db-pod.ts`) and `wp-content` (`duplicate/pod-copy.ts`), URL search-replace, mail trap, egress-deny NetworkPolicy.
- **The one structural difference from a sandbox:** instead of purging *all* `iwsl_*` options and deleting the connector plugin, staging runs the **narrow reset** (`resetConnectorStateScript` — link state only) plus a verified delete of `iwsl_media_offload`, keeps the plugin, and is then **§5.1-enrolled with a fresh identity** over k8s exec (`iwsl-managed.ts`). That gives the console a signed channel to staging — what makes Merge Lane possible — while the parent's key material, sequence numbers, and S3 credentials never survive into the copy.
- **Merge = Merge Lane, never overwrite.** `changeset.begin` fires at birth; the connector captures the user's edits as entity-level ops. "Merge to production" is a reviewed, dry-run-planned, undo-snapshotted apply of those ops to prod — pessimistic on conflicts, loud about refusals, one-click reversible. Prod's orders, comments, users, and logins are never touched: Merge Lane has no delete verb and no path that writes rows it didn't capture.
- **CDN gate:** staging can never write to or delete from the object store, three ways (§5).
- **Surfaces:** primary — a **Staging tab** in the connector's wp-admin (create / open / merge / delete, honest status). Secondary — the console's per-site Environments page (today `pages/site-sandboxes.tsx`) and Manage tab, where the operator creates, extends, deletes.
- **Lifecycle:** create → work (days) → merge (repeatable) → delete; TTL default 14 days, 30-day total ceiling, reaped by the existing sweep machinery.

What the user sees in wp-admin: a Staging tab with one button, "Create staging site". Minutes later the tab shows a link (`https://blog--stg-ab12cd.example.com`, behind Authentik), an expiry date, and two more buttons: "Review & merge to production" and "Delete staging".

---

## 1. Inventory verdict — reuse map

| Existing piece | Verdict | Why |
|---|---|---|
| **Sandboxes** (`lib/sandbox/*`, `api/sandbox-handlers.ts`) | **Reuse as the chassis.** Staging is a *superset*: same spawn, claim, quota, TTL, teardown-guard, sweep. Deltas: role field, `--stg-` infix, narrow seal + fresh enrollment, longer TTL, quota of one. | The pipeline already solved the hard provisioning problems (RWO double-mount census, capacity preflight, seal-before-ready, guarded reaper); a rebuild is a second copy that must agree forever. |
| **Merge Lane / changesets** (`lib/changesets/*`, connector `changeset.begin/status/export/apply/abort`) | **Reuse as the entire merge story.** Built, tested, feature-switched off (`WORDPRESS_CHANGESETS_ENABLED`), explicitly designed for "promote out of a sandbox" — but no spawnable environment today can be its source, because sandboxes are never enrolled. Staging is the missing source. | See §3. |
| **Blue/green slot-b** (`lib/updates/slots.ts`) | **Not the staging mechanism; reserved for a v2 files lane.** Both slots share ONE database — what makes a core-update promote lossless is exactly why slot-b cannot carry staging: the database is the thing that diverges. | A v2 "file changes" lane (theme edits, plugin installs) could build a candidate in the inactive slot against the *live* DB and promote atomically. |
| **Release channels** (`lib/channels.ts`) | **Reuse unchanged for rollout.** Connector changes ship down the alpha channel to hi2 first; a staging site inherits its parent's channel at enroll. | Console-authoritative per link record; nothing new. |
| **Duplicate** (`lib/duplicate/*`) | Reuse its scripts (search-replace, content tar, `connectorResetScript`) — the sandbox pipeline already does. | |
| **Backups / Deep Restore** | Reuse: Merge Lane's undo snapshot (`changesets/undo.ts`) is already a Deep Restore snapshot of the touched tables. | |

Nothing new is invented at the mechanism level. The new code is: the role variant in the sandbox modules, the staging seal+enroll step, the request outbox + sweep, two UI surfaces, and the Merge Lane completion work in §3.

## 2. Why sandboxes alone are not staging

A sandbox is operator-facing forensics: connector purged entirely, never enrolled, 72h default TTL, dies quietly. Staging is user-facing authorship: it must keep the connector **running** (the capture hooks live in it), be **enrolled** (the signed channel's transport is k8s exec, so the egress-deny NetworkPolicy stays), and live long enough to finish a redesign. The purge-everything seal would also delete every feature setting (redirects, cache, SEO) and change staging's behavior versus prod — wrong for an environment whose purpose is "test what prod will do".

## 3. The merge problem — the honest section

**Rejected: wholesale copy of staging over prod.** Destroys every order, comment, user, and form submission prod took while staging was open, and re-imports staging's rewritten URLs and reset connector state into a live enrolled site. There is deliberately **no "replace production" button anywhere in this design** — true replacement already exists as Deep Restore, which at least says "restore" instead of "merge".

**Rejected: generic row-level DB merge.** Serialized PHP embeds row ids that differ per environment; auto-increment id spaces collide; plugin tables have no readable schema. Mergebot died proving this is a research project.

**Rejected: table-level selective push (WP Engine / WP Staging style).** "Push wp_posts + wp_postmeta" *sounds* scoped but is still an overwrite: order rows interleave with content rows in those same tables, so a table push loses orders exactly like a full copy — with a checkbox that made the user feel careful.

**Rejected: slot-b flip as merge.** Shared database; cannot carry DB divergence at all (§1).

**Chosen: Merge Lane, completed.** The existing system is precisely "the smart way" the operator invited: while the staging session is open, the connector records *what changed* as entity ops (ring-capped at 2000, overflow terminal and loud, `iwsl_*` options never captured). Merge is then:

1. **Plan** (`lib/changesets/apply-plan.ts` + site-side `IWSL_Changeset_Apply::plan`): pure dry-run, both sides independently, *pessimistic* — a prod fingerprint that no longer matches the capture base, a missing base, or an update to a row prod deleted are all conflicts. The entanglement report warns (never auto-expands) when a post travels without its meta; a diverged plugin inventory blocks the whole plan.
2. **Undo first** (`changesets/undo.ts`): a Deep Restore snapshot of exactly the touched tables, taken and *awaited* before the site is claimed. No snapshot ⇒ no merge.
3. **Apply** (`changesets/run.ts`): idempotent batches over the signed channel; a mid-run failure latches for a human.
4. **Undo is one click** and restores only the touched tables.

**What v1 honestly moves, and what it refuses.** Today the connector *captures* only `save_post` + option updates, and *applies* only `post` and scalar `option` ops (`IWSL_Changeset_Apply::classify` has write paths for nothing else — every other class is planned, shown, refused). For an Elementor-heavy fleet that is not enough: a page edit without its `_elementor_data` postmeta does not travel, and an image added in staging would merge as a broken reference. **So this build includes finishing two Merge Lane lanes:**

- **postmeta lane:** capture `added_post_meta`/`updated_post_meta` (scalar and JSON-string values; PHP-serialized values refused by name, as `model.ts` documents) plus a `postmeta` write path in `IWSL_Changeset_Apply`. Capture must allow-list content post types — never `shop_order`, never users.
- **media lane:** capture `add_attachment` as `media_ref`; on apply the console streams the file staging-pod → prod-pod via `duplicate/pod-copy.ts` (bytes never cross the 64 KB command channel), then site-side apply creates the attachment row. Prod's offload engine then treats it like any local upload (§5).

Refused **forever**, stated in the UI (already written in `UNPORTABLE`): deletions (no delete verb on the wire — a merge tool that can delete can be talked into deleting), users/roles, arbitrary SQL/schema, unknown plugin tables, serialized PHP, media bytes over the command channel. Theme/plugin **file** changes and plugin installs do not travel in v1: install on prod through the normal plugin flow, then merge the settings as options. The v2 files lane via slot-b (§1) is the designed successor.

A merge that says "these 14 changes will apply, these 2 conflict because production changed underneath you, these 3 cannot travel and here is why, and here is your restore point" is the feature. A silent button is the catastrophe.

## 4. The staging spawn — deltas from the sandbox pipeline

`lib/sandbox/spawn.ts` steps 1–5 and 7 run unchanged (preflight, claim, provision inert with `connector: false`, label + egress lockdown *before* data arrives, hydrate, finalize URLs). Step 6 (seal) is replaced for `role: "staging"`:

1. **Narrow identity reset** — `resetConnectorStateScript()` (link-state keys/families only; self-verifying, already used by Duplicate). Feature settings survive; the parent's signing key, epoch, and seq do not.
2. **Offload settings purge, verified** — `wp option delete iwsl_media_offload` + a printed re-read proof, same idiom as `purgeConnectorIdentityScript`. Removes the S3 **credentials**: staging can neither upload nor `delete_object` against the site's bucket.
3. **Mail trap** — `installMailTrapScript()` unchanged (`pre_wp_mail` at `PHP_INT_MAX`; API mail transports never run).
4. **Object-cache drop-in removal** — delete `wp-content/object-cache.php` *before* the finalize `wp cache flush`. The tar import copies the parent's drop-in: prefix `iw:<parent>:`, and its `flush()` is `flushDb()` — a fleet-wide flush on the shared Valkey. Egress-deny already blocks Valkey (drop-in fails open), but the file must not exist to be re-enabled later; staging simply has no persistent object cache. *(Separately: that `flushDb()` in `runtime/object-cache.ts` is a pre-existing fleet bug — any site's `wp cache flush` flushes every site. File it; fix is prefix-SCAN delete.)*
5. **SSO plugin deactivation** (best-effort) — a copied OIDC client points at the parent's host and can never complete on staging's; users log into staging wp-admin with their copied WP credentials.
6. **Fresh §5.1 enrollment** — `installConnector`/`enrollBundle` via `iwsl-managed.ts` exec transport, creating a **new** link record flagged `environment: "staging"`, `parent: <site>`, channel inherited from the parent. The bundle carries the environment; `IWSL_Plugin::is_staging()` reads it.
7. **`changeset.begin`** over the new signed link, base = now. The record cannot reach `ready` without steps 1–3, 6, 7 verified — the same `withReady`-refuses-unsealed structure as today.

**Record/naming:** `SandboxRecord` gains `role: "sandbox" | "staging"`; `id.ts` gains the `--stg-` infix beside `--sbx-` (same 32-char composed-label ceiling — every current site name fits). Store, claim, heartbeat, staleness reuse the existing ConfigMap store. **TTL:** `DEFAULT 14d / MAX total 30d` beside the sandbox's 72h/14d, same `extendTtl` arithmetic. **Quota:** `maxStagingPerSite = 1` — hard: the connector refuses a second concurrent changeset session anyway, and two stagings of one prod is merge chaos by construction. Storage counts against the existing fleet sandbox budget (a staging pair provisions ~10 Gi at current 5 Gi site PVCs; local-path is thin — fits today's headroom, and the quota refusal is the guard when it doesn't). Copied: DB + `wp-content`, uploads included — at this fleet's size that is megabytes; the share/symlink-media optimization is deferred until a site's uploads make the copy hurt. Never copied: `wp-config.php`, salts, DB credentials, `.htaccess` — the clone gets its own (existing duplicate rules).

**Access:** `authMode: "full"` forced. After the reconcile provisions staging's own Authentik gate (`recordSetupIntent(…, applied: false)`, exactly as sandboxes do), the spawn syncs the parent's granted users onto it via `lib/access.ts` `syncSiteAccess` + `grant-authentik-user.ts`, so exactly the people who may reach the parent's protected surfaces may reach staging. Search engines see nothing (`blog_public 0` plus the mu-plugin filter).

## 5. The CDN gate — exact code path

The decision "does this image go to the object store" lives in **`includes/class-iwsl-media-offload.php`**: `register()` attaches the URL-rewrite filters and AJAX handlers only when `entitlements->evaluate('image_optimization')` unlocks; every upload path (`offload_one`, backfill, re-sync) requires settings-complete (`is_configured_static()` / `settings()['enabled']` + bucket + credentials) read from the `iwsl_media_offload` option; the same credentials drive `delete_object`. Three independent staging barriers:

1. **Credentials do not exist** — seal step 2 deletes `iwsl_media_offload`, verified. No upload, no delete, no re-sync can execute. This also closes the nastier inverse risk: a clone holding prod's credentials could *delete prod's live CDN objects* via unoffload/cleanup.
2. **The connector refuses the feature structurally** — new checks in `register()`, `handle_save()`, and `is_configured_static()`: return early when `IWSL_Plugin::is_staging()`. This is required, not belt-and-braces: the plugin stays installed on staging, so without it a user could re-enter S3 credentials in staging's CDN tab and re-arm offload against the production bucket. The staging flag is console-authoritative (set at enrollment), not user-editable.
3. **Merges cannot carry it** — Merge Lane never captures `iwsl_*` options, and media travels as bytes into prod's pod (§3), where **prod's** offload engine picks it up through its normal backfill. Every CDN object is therefore created by, and bound to, production. Staging serves copied local files at local URLs (the rewrite filters are unattached, and saved post content holds local URLs — bucket rewriting happens only at render time on prod).

## 6. The button — both surfaces

**Plugin (primary).** New `includes/class-iwsl-staging.php` + a "Staging" tab in the existing grouped admin surface (`class-iwsl-admin.php` `group_tabs` pattern), gated by a new custom capability `iwsl_manage_staging` (mirror of `iwsl_manage_changesets`) — administrators by default. The button writes a local **request outbox** option `iwsl_staging_request` `{request_id, action: create|delete, requested_by, requested_at}` (nonce + capability checked; one pending request at a time). The tab renders `iwsl_staging_state`, which the **console pushes** over the signed channel after every transition (new connector method `staging.state.set`, allow-listed like the changeset methods): `requested → provisioning → ready(url, expiresAt) → merging → merged(undo available) → deleting`. "Review & merge to production" deep-links to the console's review page — the plan is computed and approved console-side, where RBAC and audit live; a diff-review duplicated inside wp-admin would be a second implementation of the most safety-critical surface. (Assumption to verify on hi2: site owners hold scoped console access via the existing per-site grants/foyer; where they don't, the operator drives the merge.)

**Pickup.** There is deliberately **no site→console network path** on this platform (zero-trust; the managed transport is k8s exec), and this design does not open one. A new `k8s/staging-sweep-cronjob.yaml` (2-minute schedule, cloned from `sandbox-sweep-cronjob.yaml`, POST `/api/wordpress/staging-sweep`) polls the outbox via one `wp option get` exec per *staging-enabled* site (1–2 sites initially), consumes the request (delete option — at-most-once), authorizes it, and starts the spawn/teardown. The same sweep reaps expired staging records through the existing guarded teardown (`sandbox/teardown.ts` — both-labels re-check, `deleteSite` does the deleting). Latency is honest UX: creation takes minutes regardless; the tab says "being prepared — a few minutes".

**Console (secondary).** Routes: `POST/GET/DELETE /api/wordpress/sites/[site]/staging` (thin delegators to `api/staging-handlers.ts`; RBAC `wordpress:admin` to create/delete, `wordpress:read` to view — same tiers and rate-bucket idiom as `sandbox-handlers.ts`), plus `POST /api/wordpress/staging-sweep`. UI: `pages/site-sandboxes.tsx` becomes the per-site **Environments** page (sandboxes + staging: create, open, extend TTL, delete, merge status), a staging chip on `components/manage-page.tsx` / site detail, and the merge-review surface (`pages/site-staging-review.tsx` + `components/changesets/plan-view.tsx` — the changesets API has **no UI today**; this is the largest genuinely-new UI build). Per-site staging enablement is an operator switch on the link record, set from Manage — that switch authorizes the sweep to act on a site's outbox; the WP capability decides *who inside the site* may press. **No new entitlement flag**: `flag.ts` documents how a 33rd flag silently freezes old connectors' entire entitlement maps (`ENTITLEMENT_RAISE_PRECONDITIONS`); staging follows Merge Lane — feature switch + link-record field + custom capability.

## 7. Lifecycle and failure modes

| Phase | Mechanism | Failure → outcome |
|---|---|---|
| Request | outbox option + sweep | Sweep down: request sits visibly "requested"; button disabled while pending. Quota/capacity refusal → refusal sentence pushed back (existing preflight messages). |
| Create | sandbox pipeline + staging seal | Any seal/enroll/`changeset.begin` failure ⇒ record `failed`, never `ready`, reaped like a failed sandbox. Failed records still hold quota (`occupiesCapacity`). |
| Work | user edits; capture runs | Ring overflow (>2000 ops) ⇒ session `overflow`, export refuses; tab says "too many changes — merge sooner or recreate". Console dead mid-spawn ⇒ heartbeat staleness reaps. |
| Refresh | delete + recreate | v1 has **no in-place re-hydrate**: fresh parent data invalidates the capture base, so refresh is honestly "recreate" (`hydrate.ts`'s published-refusal already encodes this instinct). |
| Merge | plan → undo snapshot → apply | Conflicts/refusals shown, never auto-resolved. Undo snapshot fails ⇒ merge never starts. Batch failure ⇒ job latches for a human; undo available. Repeatable: after apply, the session re-begins with a fresh base. |
| Expire | TTL sweep | Warning pushed at T-48h; reaper deletes via guarded teardown; no extension past 30d total. |
| Delete | user button / console / reaper | `deleteSite` (DNS, gate, PVCs, vault) + delete the staging link record + abort any open session. No recovery point, stated up front — merged work lives on prod; unmerged work dies with it. |

## 8. Testing plan — hi2 as proving ground

hi2 moves to the **alpha** channel (existing `channel-registry` flow); all connector changes (staging tab, `is_staging()` offload refusals, `staging.state.set`, postmeta/media lanes) ship down alpha and reach only hi2 until promoted.

1. **Unit** (jest, `--maxWorkers=1` on this box): `--stg-` id grammar + label ceiling; staging seal script catalogue (no `mysql`, no `|| true` on proof lines — extend the existing catalogue tests); quota-of-one; TTL constants; outbox parse/consume; offload refusal when `is_staging()` (the offload class is dependency-injected, testable without WP).
2. **Spawn E2E on hi2:** wp-admin button → staging ready behind Authentik (anonymous → redirect; granted user → through). Fresh identity verified: staging `health.check` green on its *own* link, parent's link untouched (the seq-rollback quarantine is the regression this guards).
3. **CDN gate proof:** upload an image on staging → bucket listing unchanged, local URL served; saving S3 settings in staging's CDN tab → refused; `iwsl_media_offload` absent. Merge that image → file lands on prod → prod's backfill offloads it → object bound to prod.
4. **Merge E2E:** edit a page + an option on staging; plan shows both; edit the *same* post on prod → plan shows a conflict and refuses it; apply the clean ops; undo restores exactly the touched tables (an order/comment written to prod mid-test must survive both apply and undo).
5. **Lifecycle:** short-TTL staging expires and is reaped; teardown leaves no PVC, DNS, gate, or link record; parent unaffected.
6. **Soak:** one real content-editing week on hi2 staging before enabling the switch anywhere else.

## 9. Traps and open uncertainties

- **`flushDb()` on the shared Valkey** (`runtime/object-cache.ts`) — pre-existing, fleet-wide; staging sidesteps it by drop-in removal, but fix it independently.
- **Elementor depends on the postmeta lane.** Until it lands, merges move page *rows* but not `_elementor_data` — the plan shows the refusals, but v1-without-postmeta only serves classic content and settings. Ship the lanes before the button.
- **Staging wp-admin login** where the parent is SSO-only: SSO deactivation assumes users hold WP passwords; they may not. Fallback: a console "reset staging admin password" action (`wp user update --user_pass`). Verify on hi2.
- **Uncertain:** whether every site-owner persona holds console access for the review step (§6 assumption); whether `save_post` capture excludes WooCommerce order types (must be allow-listed before GA — an order captured as a "post" op would be offered for merge); Authentik gate provisioning latency at spawn (reconcile-driven — `ready` must wait for the gate, not race it).
- **YAGNI kept out:** multiple stagings per site, staging-of-staging (nesting already refused), in-place refresh, a site→console HTTP channel, a new entitlement flag, per-file media diffing, the slot-b files lane (designed, deferred).

## 10. Build order (each step shippable alone)

1. Connector: `is_staging()` + offload refusals + `staging.state.set` + staging tab/outbox → alpha → hi2.
2. Console: role variant in `lib/sandbox/*` + `lib/staging/` seal/enroll orchestrator + staging routes/handlers + staging-sweep CronJob.
3. Merge Lane completion: postmeta + media lanes (connector capture + apply, console pod-copy for media) and the console review UI; then `WORDPRESS_CHANGESETS_ENABLED=true`.
4. Environments/Manage UI polish, access sync, expiry warnings.
5. hi2 soak (§8), then per-site enablement by the operator.
