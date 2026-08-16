# WordPress Connector Release Channels

How the IWSL Connector release trains (`prod` / `beta` / `alpha`) work: where a
site's channel lives, what the signed-channel invariant does and does *not*
cover, how a build reaches a channel, and the exact promote-and-roll procedure.

Written 2026-08-16 against console `consoleup-20260816-135406` and connector
`0.56.0`. Authoritative code, in order of how much of the model each file owns:

| Concern | File (in `InfraWeaver-platform`) |
|---|---|
| The channel table + ladder rules | `apps/infraweaver-console/src/addons/wordpress-manager/lib/channels.ts` |
| Channel → version board (runtime) | `.../lib/channel-registry.ts` |
| Version → plugin bytes | `.../lib/connector-artifact.ts`, `.../lib/connector-package.ts` |
| Per-site targeting on update | `.../lib/update-sweep.ts`, `.../lib/iwsl-managed-ops.ts` |
| The APIs | `.../api/iwsl-handlers.ts` |

---

## 1. Where a site's channel is stored, and who can change it

A channel is **console-authoritative**. It is a single optional field on the
site's connector link record:

```ts
// lib/iwsl-link-store.ts — ExternalSiteRecord
channel?: ReleaseChannel;   // "prod" | "beta" | "alpha"; absent ⇒ prod
```

Those records are persisted as JSON in the ConfigMap
**`infraweaver-iwsl-sites`** (key `sites`) in namespace `infraweaver-console`.
`resolveChannel(record)` maps absent/garbage to `prod`, so an unassigned site is
a prod site — there is no "no channel" state at read time.

**The only supported way to change it** is the `set-channel` op:

```
POST /api/wordpress/sites/<site>/iwsl/ops
{ "action": "set-channel", "channel": "alpha" }
```

- Permission `wordpress:admin`, rate-limited 10/min (`OPS_POLICY` in
  `iwsl-handlers.ts`).
- Writes an audit line `wordpress:set-channel` (actor, site, target channel).
- Implemented by `setSiteChannel()`; it is **pure console bookkeeping — no wire
  push**. Nothing is signed, nothing is sent to the site, no `seq` is consumed.
  It returns `{ previousChannel, outcome: "changed" | "already" }`.
- UI equivalents: Connector tab → "Release channel"; Sites tab bulk toolbar →
  "Assign channel"; the site-create form (`channel` on the create schema).

A site can also be *enrolled* onto a channel:
`enrollManagedSite(site, actor, channel)`.

**A WordPress site can never select its own channel.** There is no channel
option in the plugin and no `channel.*` method in the plugin's command registry;
the field exists only in the console's ConfigMap. Editing the ConfigMap by hand
works but skips validation and the audit line — use the op.

---

## 2. What the signed-channel invariant actually enforces

⚠️ **Two unrelated meanings of "channel" collide here. Do not conflate them.**

| Term | Meaning |
|---|---|
| **Release channel** | `prod`/`beta`/`alpha` — *which build train a site rides*. This document. |
| **Signed channel** / **command channel** | The IWSL *transport* — the signed `/command` exchange. Nothing to do with release trains. |

The **signed-channel invariant** (`apps/infraweaver-console/docs/iwsl-secure-by-design.md`)
is a rule about *adding capabilities*, not about releases:

> Every new remote WordPress-management capability MUST be a new **signed
> method** in the IWSL command registry — never a new public-facing or
> separately-authenticated plugin REST endpoint. The Connector has exactly two
> ingress surfaces (one-time enroll + signed `/command`) and that number never
> grows.

A signed method inherits: dual signatures (Ed25519 + SLH-DSA), pinned-WP-key
reply verification (tamper → auto-quarantine), monotonic `seq` / single-use
nonce / `ts`+`exp` windows, retired-epoch floors, the §2 invariant (the site
never dials InfraWeaver), and **§6.4 channel/audience binding** — the
`aud: { site, chan }` field that commits a command to one site *and* one
transport (`"exec"` | `"https"`), so a command captured on one transport cannot
be replayed onto another. `chan` is what the plugin's
`handle_command($wire, $channel)` → `verify_command()` enforces against its own
ingress.

**How this constrains release-channel work:** assigning a release channel is not
a remote capability at all — it never crosses the wire — so it needs no signed
method, and adding one would be the wrong shape. What *does* cross the wire is
the install (`update-plugin` / the sweep), and that already rides the existing
signed path: `updateConnectorPlugin` pushes bytes over `execInWpPod` and then
proves the result with a signed `health.check` verified against the site's
pinned WP key. The correct way to move a site's channel is therefore the
console-side `set-channel` op — **not** a plugin option, a WP `iwsl_*` option
written by hand, or a new endpoint.

---

## 3. How a build reaches a channel, and how a site picks it up

Three independent hops. All three must line up or nothing installs.

### Hop 1 — a version is pinned onto a channel (the release board)

The board is the ConfigMap **`infraweaver-iwsl-channels`** in
`infraweaver-console`, one entry per channel: `{ version, updatedAt, updatedBy }`.

```
GET  /api/wordpress/connector-channels                     # wordpress:read
POST /api/wordpress/connector-channels                     # wordpress:admin, 10/min
     { "action": "set-version", "channel": "alpha", "version": "0.56.1" }
     { "action": "promote", "from": "alpha", "to": "beta" }
     { "action": "rollback", "channel": "prod", "version": "0.55.0" }
```

No console rebuild is needed to publish. Rules:

- **`promote` moves exactly one rung toward prod** — `alpha→beta` and
  `beta→prod` only. `alpha→prod` is rejected (`canPromoteChannel`). It copies
  `from`'s version verbatim onto `to`.
- **`rollback` / `set-version` have no direction rule** — any channel to any
  parseable version.
- **Seeding:** a channel with no stored entry reads as the console image's
  bundled version. Reads never write.
- **Auto-heal:** `reconcileChannelToDeliverable()` runs at the start of a sweep
  and again inside `updateConnectorPlugin` when the artifact is missing. If a
  channel's pin cannot be built but a **strictly newer** deliverable exists, the
  pin is advanced to it (actor `system:auto-advance-on-sweep` / `-on-update`).
  It never downgrades, so a deliberate rollback pin is respected.

  > ⚠️ **It used to run for EVERY channel, and that was a defect** — see §5.1.
  > As of platform `a53a7ea0` it runs **only for a channel declared
  > `autoAdvance` in `channels.ts`, which is `alpha` alone**. prod and beta move
  > only through `promote` / `set-version` / `rollback`; a stale pin there now
  > fails closed at install time with an error naming the remedy. **Not yet in
  > the running console image.**

### Hop 2 — the version must be materializable as bytes

`resolveConnectorArtifact(version, channel)` builds the plugin zip from that
channel's own source and returns it **only if the source's version string equals
the requested version**. Otherwise it throws `ConnectorArtifactUnavailableError`
and the install is refused. It never ships bundled bytes under a different
label.

Source resolution (`connector-package.resolveDir`), first match wins:

1. `IWSL_CONNECTOR_DIR_<CHANNEL>` — e.g. `IWSL_CONNECTOR_DIR_ALPHA`
2. `IWSL_CONNECTOR_DIR` — the shared git-sync volume
3. the copy baked into the console image

> **Live status 2026-08-16: only step 2 is wired.** The console deployment sets
> `IWSL_CONNECTOR_DIR=/connector-src/plugin`, fed by the single
> `connector-git-sync` sidecar that tracks `origin/main`,
> `apps/infraweaver-wp-connector`, every 60s. There is **no**
> `IWSL_CONNECTOR_DIR_ALPHA/_BETA/_PROD`. Consequences in §5.

### Hop 3 — the site installs it

There is **no cron for connector updates** — deliberately, so a bad build cannot
auto-deploy fleet-wide unattended. (The hourly `wordpress-connector-health-sweep`
only health-checks; it does not install.) Two operator-initiated paths:

- **Per site:** `POST /api/wordpress/sites/<site>/iwsl/ops` `{"action":"update-plugin"}`.
  Target defaults to `registry[resolveChannel(record)]` — channel-correct.
- **Fleet / selection:** `POST /api/wordpress/connector-update-sweep` with an
  optional `{ "sites": ["a","b"] }`. Per site it computes
  `target = registry[resolveChannel(site)]` and **skips** any site whose
  *recorded* `connectorVersion` already compares `>= target` (outcome `already`).
  Otherwise it calls `updateConnectorPlugin(site, target, channel)`.

  > As of platform `a53a7ea0` that recorded-version check is only a cheap
  > pre-filter. The authoritative "is there anything to do?" answer comes from
  > `updateConnectorPlugin` probing the pod, so a stale record can no longer
  > cause a downgrade — it comes back as `already` or as a named refusal. See
  > §5.2.

After the install, `updateConnectorPlugin` runs a signed `health.check`, persists
the version the plugin itself reports, and re-pushes the site's current tier
entitlement map (`connector-auto-resync`).

---

## 4. Promoting a release from alpha to prod — exact procedure

Worked for the case "promote connector `X.Y.Z` to prod and roll it to
`zonnevaarwater.nl`". All calls need `wordpress:admin`.

**Step 0 — make the version deliverable.** `X.Y.Z` must be the version the
console can actually build, i.e. the `Version:`/`IWSL_CONNECTOR_VERSION` on
`main` in `apps/infraweaver-wp-connector` (or in that channel's own
`IWSL_CONNECTOR_DIR_<CHANNEL>` source, once those exist). Merge and let git-sync
pick it up (≤60s), then confirm:

```bash
kubectl exec -n infraweaver-console <console-pod> -c console -- \
  grep -m1 IWSL_CONNECTOR_VERSION /connector-src/plugin/infraweaver-connector.php
```

If you skip this, every install fails closed with
`ConnectorArtifactUnavailableError` — safe, but the roll does nothing.

**Step 1 — pin alpha to it** (if it is not already there):

```json
POST /api/wordpress/connector-channels
{ "action": "set-version", "channel": "alpha", "version": "X.Y.Z" }
```

**Step 2 — soak on the canary.** `hi2` is the alpha site. Update it and verify:

```json
POST /api/wordpress/sites/hi2/iwsl/ops        { "action": "update-plugin" }
POST /api/wordpress/sites/hi2/iwsl/ops        { "action": "health" }
```

**Step 3 — promote one rung at a time.** `alpha→prod` in one call is rejected.

```json
POST /api/wordpress/connector-channels  { "action": "promote", "from": "alpha", "to": "beta" }
POST /api/wordpress/connector-channels  { "action": "promote", "from": "beta",  "to": "prod" }
```

Each copies the source channel's version verbatim and re-stamps the actor.
(`set-version` on `prod` directly is possible and is what a hotfix uses, but it
skips the soak — prefer the two hops.)

**Step 4 — roll it to the target site only.** Scope the sweep; an unscoped POST
hits every enrolled link.

```json
POST /api/wordpress/connector-update-sweep
{ "sites": ["zonnevaarwater-nl"] }
```

Use the k8s **site name** (`zonnevaarwater-nl`), not the domain. Add
`Accept: application/x-ndjson` for a per-site progress stream.

**Step 5 — verify.**

```json
POST /api/wordpress/sites/zonnevaarwater-nl/iwsl/ops   { "action": "health" }
```

`result.plugin` is the plugin's own signed report of its version — that, not the
badge, is the fact. Then confirm the site serves 200.

**Rolling back:** `{ "action": "rollback", "channel": "prod", "version": "<older>" }`
then re-run the scoped sweep. This only works if the older version is what the
channel's source currently holds (see Step 0) — otherwise it fails closed. There
is no artifact store yet; `connector-artifact.ts` carries the
`TODO(§5.1 artifact store)` for arbitrary tagged versions.

### Headless (no browser) invocation

All of the above are console API calls that need an Auth.js session. Mint one
locally from the repo checkout (which has `next-auth`; the pod's standalone build
does not), then POST from inside the console pod:

```bash
export AUTH_SECRET=$(kubectl get secret infraweaver-console-secret \
  -n infraweaver-console -o jsonpath='{.data.nextauth-secret}' | base64 -d)
# encode({ token: { email, sub, groups: ["platform-admins"], groupsRefreshedAt: Date.now() },
#          secret, salt: "__Host-authjs.session-token" })
kubectl exec -n infraweaver-console <console-pod> -c console -- node -e '...fetch...' "$JWE"
```

Send `Origin: http://127.0.0.1:3000` and
`Cookie: __Host-authjs.session-token=<jwe>`. The console pod has **no `curl`** —
use `node -e` with `fetch`.

---

## 5. Known gaps and trip hazards

1. **Channels did not deliver different code, and a sweep could push `main` to
   prod.** ~~With no `IWSL_CONNECTOR_DIR_<CHANNEL>` volumes, all three channels
   resolve to the one `main`-tracking git-sync dir. Combined with the
   forward-only auto-heal, the first sweep after `main` moves silently advances
   **prod, beta and alpha alike** to `main`'s version.~~

   **FIXED, NOT YET DEPLOYED** — platform `a53a7ea0`, infra `c760bdf`
   (unpushed). Two halves:

   - Auto-advance is now `alpha` only (`ChannelDefinition.autoAdvance`,
     enforced inside `reconcileChannelToDeliverable`). `main` can no longer
     reach prod or beta because a sweep ran.
   - Bytes come from a **version-addressed artifact store**,
     `IWSL_CONNECTOR_VERSIONS_DIR=/connector-src/versions`, one directory per
     Connector version, filled by the *existing* `connector-git-sync` sidecar.
     A channel is then a real version pin: alpha can ride 0.57.0 while prod
     stays on 0.56.0, and a promote is immediately deliverable. `resolveDir`
     also now **throws** when a declared `IWSL_CONNECTOR_DIR_<CHANNEL>` is
     unusable, instead of quietly serving the shared `main` tree.

   ⚠️ After the console image ships, **re-pin the board**: it currently reads
   `prod/beta/alpha = 0.54.2`, all written by `system:auto-advance-*`, and with
   auto-advance gone from prod/beta those pins fail closed until an operator
   promotes or sets a deliverable version.
2. **In-pod `tar | kubectl exec` deploys are invisible to the console until the
   next health sweep.** The sweep's skip check reads the *recorded*
   `connectorVersion` on the link record, which such a deploy does not update.
   For up to an hour the console believes the site is older than it is, and a
   sweep in that window will reinstall. Fix the record immediately after a
   manual deploy with a per-site `{"action":"health"}`, which persists the
   reported version.

   ~~and, if the pod is genuinely ahead of the channel target, **downgrade** it
   — `updateConnectorPlugin` has no "pod already newer" guard~~

   **FIXED, NOT YET DEPLOYED** — platform `a53a7ea0`. `updateConnectorPlugin`
   now reads the version the **pod** actually has on disk before installing
   (`readConnectorVersionScript`) and `connector-install-guard.ts` decides:
   older target ⇒ refused with a named reason quoting both versions; equal ⇒
   `already` with no reinstall; newer ⇒ install. A deliberate rollback needs an
   explicit per-call reason that lands in the audit log, and the fleet sweep
   cannot pass one. Measured while writing this: zonnevaarwater-nl's pod ran
   **0.56.4** while the record said **0.56.3** — the drift is real and routine,
   not theoretical.
3. **The release board pins are advisory until §5.1 lands.** They can only ever
   name a version the current source can build; anything else fails closed at
   install time.
4. **`update-plugin` is refused** while a link is quarantined, in identity safe
   mode, or mid-restore — by design; the remedy for a suspected clone is
   quarantine, not a reinstall.
5. **`seq-rollback` on a signed op** means the console's `lastSeq` drifted behind
   the plugin's. The install path opts into a one-shot reconcile
   (`recoverFromSeqDrift`); a bare op may need a retry.
