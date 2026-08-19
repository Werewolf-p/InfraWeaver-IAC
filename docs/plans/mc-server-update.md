# Minecraft Server Update — Design & Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status: PLAN ONLY.** Nothing in this document has been implemented. Every claim about
> the current system below was verified on 2026-08-18 against the repos on this machine
> (`/home/runner/InfraWeaver-platform`, `/home/runner/InfraWeaver-infra`) and the live
> cluster (`kubectl --server=https://10.0.0.92:6443`, read-only). Anything that could
> not be verified is listed under **Open questions** rather than assumed.

**Goal:** A per-server "Update this server" flow in the console's Game Hub: pick a target
version from a dropdown of what actually exists upstream, confirm, and get a **new**
server instance on its own DNS name carrying the world, player data and server-specific
config — while the old server and its volume are never mutated, so rollback is "keep
using the old one".

**Architecture:** Blue/green **by capture-and-seed**, orchestrated by the console (no new
controller, no new copy path). The world leaves the old server only through the existing
World Timeline capture machinery (quiesced, signed, verified), and enters the new server
only through the existing companion-pod restore machinery, extended to allow a
cross-server target. The new server is created through the existing `createServer` path
with the chosen version, proves it can boot the new version on a fresh world first, is
then stopped, seeded, restarted, and watched with the Update Rehearsal log-signature
verdict machinery before the operator is told to point players at it.

**Tech Stack:** Next.js console (`apps/infraweaver-console`), gamehub addon
(`src/addons/gamehub`), Kubernetes client (`@kubernetes/client-node`), World Timeline
(`lib/timeline/*`), Update Rehearsal (`lib/rehearsal/*`), modpack resolvers
(`lib/modpacks/*`), external-dns + Cloudflare SRV (`lib/game-srv-record.ts`), jest.

## Global Constraints

- The old server's volume is **never written** by any part of this feature. The only verbs issued against the old server are RCON `save-off`/`save-all`/`save-on` (the quiesce bracket) and, when quota requires it, scale-to-0.
- Exactly one capture implementation and one restore implementation exist. This feature adds **no second tar path** — see `lib/rehearsal/run.ts`: "a private capture in this file would be a second, weaker answer".
- Namespace `game-hub` quota is `requests.memory: 16Gi` hard; GTNH requests 12Gi (measured live). Two GTNH-class servers **cannot** run concurrently without a git quota change; the flow must sequence around this, not assume it away.
- Any new pod spec must be restricted-compliant: `runAsNonRoot`, seccomp `RuntimeDefault`, drop ALL capabilities, no hostPath, no SA token (`game-hub` is PSA enforce=baseline / warn=restricted; the Kyverno Enforce policies match `infraweaver.io/type: catalog-app` namespaces, which `game-hub` is not, but every existing game-hub helper is written restricted-compliant regardless — keep that).
- All feature routes follow the existing gate pattern: a `GAMEHUB_UPDATE` env flag registered in `src/lib/feature-defaults.ts` with `dependsOn: ["GAMEHUB_TIMELINE"]`, `accepts: ON_TRUE_ONE_WORDS`, resolving through `platformDefaultFor` (live console runs `PLATFORM_ENABLE_ALL=1`).
- Console file conventions: many small files, `lib/` pure logic separated from route glue, `import "server-only"` on anything touching the cluster, refusal codes as string literals, "omit rather than fake".
- Fresh-worker note: repo conventions live in the file headers of the modules this plan touches — read the header of every file you modify before editing it; they are load-bearing (`lib/rehearsal/types.ts`, `lib/timeline/restore.ts`, `lib/worlds/world-layout.ts` especially).

---

# Part A — Design record (brainstorming outcome)

## A.1 The request, restated

The operator asked (verbatim intent): on a GTNH server — or better, any Minecraft
server — a Settings-area option to **update the server**: a dropdown of all newer
versions available; applying creates a **new server on a different DNS name** (or one
the operator chooses), copies **world, user info, and server-specific things** into it,
installs the new version there, and leaves the old server intact so "rollback" is just
keeping the old one. Stated goal: *use the newest version without data loss*.

## A.2 What already exists (all verified)

| Capability | Where | State |
|---|---|---|
| Version resolution, GTNH | `gamehub/lib/modpacks/gtnh.ts` — scrapes `https://www.gtnewhorizons.com/downloads/` for `GT_New_Horizons_<v>_Server_Java_<ch>.zip` links; pinned fallback `2.8.4` + warning | live; resolves **latest only**, no list yet |
| Version resolution, CurseForge / FTB | `modpacks/curseforge.ts`, `modpacks/ftb.ts`; `listFtbVersions()` exists; `/api/game-hub/modpacks/versions` serves FTB lists | live |
| Version list, vanilla MC | `lib/minecraft-java-compat.ts` (Mojang `launchermeta` manifest, 1 h in-memory TTL) + `/api/game-hub/minecraft-versions` | live |
| Paper installs | `lib/game-hub-install-patches.ts` — installer patched to PaperMC **v3 fill API** (`fill.papermc.io/v3`); v2 is sunset | live (install-time only) |
| Outbound egress, console pod | KNP `infraweaver-console` allows `0.0.0.0/0` (minus RFC1918) on 443/587 — measured live | version feeds reachable from console |
| Outbound egress, game pods | CNP `allow-game-downloads`: world:443/80 for pods labelled `infraweaver.io/game=true` (`core/network-policies/manifests/allowlists.yaml`) | pack zips downloadable by installer |
| World capture (quiesced, signed, dedup'd) | `gamehub/lib/timeline/*` — quiesce bracket with flush proof, content-addressed chunk store on the `infraweaver-backup` datastore pod (`/datastore/game-worlds`, 30Gi longhorn-retain PVC, live), signed manifests, verify, GC | shipped behind `GAMEHUB_TIMELINE`; **defaults ON** via `PLATFORM_ENABLE_ALL=1` (not in `NEVER_DEFAULTED`) |
| Restore to a stopped server via companion pod | `timeline/restore.ts`, `restore-target.ts`, `game-hub-companion.ts` — signature verify → mandatory pre-capture → stop → **zero pod objects** → writable companion → stream in | live code; restores onto the **same** server only |
| Candidate boot verification | `gamehub/lib/rehearsal/*` — clone pod (never mounts a PVC), log signatures (crash-report, world-load-failed, mixin errors…), `fail` vs `inconclusive` discipline, startup budget | shipped behind `GAMEHUB_REHEARSAL` (defaults ON, `dependsOn` timeline) |
| Server creation | `/api/game-hub/servers/impl.ts` `createServer` — egg or resolved modpack, quota preflight (`assertFitsQuota` hard, `predictNodeFit` acknowledged), PVC (default class `longhorn`), RCON secret, installer + config-sync initContainers, probes | live (GTNH itself was created this way) |
| Server clone (spec only) | `impl.ts` `cloneServer` — new PVC/Deployment/Service/Secret; **does not copy data** | live |
| Game DNS | Service annotations `external-dns.alpha.kubernetes.io/{hostname,target,ttl,managed}` → external-dns (Cloudflare provider, `domainFilters: [example.com,…]`, upsert-only) publishes `<name>.games.example.com` → `203.0.113.10`; `lib/game-srv-record.ts` publishes `_minecraft._tcp.<host>` SRV → WAN NodePort via the Cloudflare API; UDM WAN forward `game-<name>` via `game-port-forward.ts` | live; measured on the GTNH Service |
| Durable power state | `lib/game-hub-power-state.ts` — untracked ConfigMap `game-hub-power-state` | live |
| Per-server run store pattern | `rehearsal/store.ts` — one untracked ConfigMap per server, `resourceVersion` CAS, run read from record not position | live |
| Unattended work pattern | `lib/deferred/*` + sweep CronJobs (`game-hub-power-sweep`, `game-hub-capacity-retry` — both observed running live) | live |
| Health probe pattern | `catalog/game-hub/manifests/world-health.yaml` — port accepts, `level.dat` `gzip -t`, log-follows-progress, snapshot-follows-play | live (GTNH, git-authored) |
| GameServer CRD | `crds/gameserver-crd.yaml` | **vestigial — zero CRs live**; console manages Deployments directly |

The live GTNH server: Deployment `gt-new-horizons` (currently `replicas: 0`), image
`ghcr.io/parkervcp/yolks:java_21`, `IW_MODPACK_URL=…2.8.4_Server_Java_17-25.zip`,
annotation `infraweaver.io/modpack: gtnh/gtnh@2.8.4-java17`, DNS annotation
`gt-new-horizons.games.example.com`, resources requests `600m / 12Gi`, volume
`gt-new-horizons-container-local` (`local-path-retain`, PV nodeAffinity → cp1).

## A.3 Two real gaps this plan must close (found during design, both verified)

1. **The timeline's Minecraft layout cannot see GTNH's world.**
   `lib/worlds/world-layout.ts` hardcodes `MINECRAFT_JAVA_WORLDS = ["./world",
   "./world_nether", "./world_the_end"]` (lowercase). GTNH's world directory is
   `World` (capital), as documented and measured in
   `catalog/game-hub/manifests/world-archive.yaml`. A GTNH capture today would tar
   three nonexistent paths ("a tar of a path that does not exist is a warning, not a
   failure") and produce an empty point that verifies. **The layout must resolve the
   world directory name** (from `server.properties` `level-name`, with a probe
   fallback) before this feature can trust a capture.

2. **The timeline captures the world only — not the server identity files.**
   `include` is the world dirs; `ops.json`, `whitelist.json`, `banned-*.json`,
   `usercache.json`, `server.properties`, and modded per-world state
   (`serverutilities/`, `visualprospecting/`, `journeymap/`, `blueprints/` for GTNH —
   the exact set `world-archive.yaml` learned the hard way) are outside every include
   list. "Copy user info and server specific things" requires a second, explicit
   **identity** file set per engine, captured in the same point.

## A.4 Approaches considered

**Approach 1 — extend in-place promote (rejected as the primary UX).**
`rehearsal/promote.ts` already applies a new image/lock to the live server after a
mandatory pre-promote capture. It deliberately rejects blue/green because a clone's
world diverges from live. But the operator explicitly asked for a *new* server with the
old kept intact; promote mutates the one server and its rollback is a restore, which is
exactly the anxiety the request is trying to remove. Promote remains for mod-level
changes; this feature is the *server-level* sibling.

**Approach 2 — raw PVC-to-PVC copy Job (rejected).**
A Job mounting old PVC read-only + new PVC read-write (world-archive style) is the
obvious shape, and it is wrong here three ways: it is a second capture path that can
disagree with `quiesce.ts`/`flush-proof.ts` about whether the world is at rest (the
platform lost a world to exactly that class of guess); a live-directory tar is
crash-consistent, which the operator's own environment doc calls "worse"; and RWO +
the old PV's cp1 nodeAffinity force same-node scheduling games the companion machinery
already solved. It also cannot express "don't bring the old mods/config", which is the
difference between an upgrade and a copy.

**Approach 3 — capture-and-seed blue/green (CHOSEN).**
Capture a quiesced, signed point from the old server (timeline). Create the new server
with the chosen version through `createServer` (fresh world). Let it boot once — this
alone proves "the new version starts on this cluster" before any data is at stake.
Stop it, seed the captured world + identity into it through the companion restore
path (extended for a cross-server target and an engine-compat gate), start it, and
watch the seeded boot with the rehearsal log-signature verdict. The old server is
untouched throughout (stopped, if quota demands, but never written).

Why 3: it is the only approach that reuses the platform's single answers to "is this
world at rest" and "who may hold the volume while the game does not", it produces the
operator's requested topology (two servers, two DNS names, old intact), and every
phase has a rollback that is a deletion or a scale — never an un-restore.

## A.5 The quota reality, worked out explicitly (do not skip)

Measured: `game-hub-quota` hard caps `requests.memory: 16Gi`, `requests.cpu: 12`,
pods 20, PVCs 20, `requests.storage` 500Gi (156Gi used), `longhorn` class 100Gi (60Gi
used). GTNH requests **12Gi** when running (live Deployment). Nodes: cp1 47.9Gi
allocatable, cp3 8.7Gi, cp4 21.1Gi — so the *nodes* could host two 12Gi servers, but
the **namespace quota cannot**: 12 + 12 = 24Gi > 16Gi, and `createServer`'s own
`assertFitsQuota` preflight would refuse the second server while the first runs.

Consequences, designed in rather than hand-waved:

- The update run computes a **capacity plan** in preflight: `fits-together` (small
  servers — e.g. two 2Gi vanilla servers = 4Gi ≤ 16Gi) vs `requires-source-stopped`
  (GTNH-class). The confirm dialog states which one applies **before** anything runs.
- In `requires-source-stopped` mode the sequence is: capture (old may be running) →
  **stop old** (recorded in the durable power store, so nothing restarts it) → create
  + install + verify new. Old and new never run concurrently; nothing is deleted.
  Rollback at any point: stop/delete new, start old.
- In `fits-together` mode old keeps running through the whole flow; the dialog instead
  carries the divergence warning (A.7) prominently, because play continuing on old
  after the capture is precisely the data that will not be on new.
- Raising the quota is a **git decision**, not something this feature does: edit
  `kubernetes/catalog/game-hub/manifests/resource-quota.yaml` (e.g. `requests.memory:
  28Gi`) and let ArgoCD sync. The UI links to this fact when it reports
  `requires-source-stopped` ("to run both side by side, raise the namespace quota in
  git"), it never edits the quota itself.
- Storage: a second GTNH-class server adds one 30Gi `longhorn` PVC → 90/100Gi of the
  class cap, 186/500Gi total. Fits, but the preflight asserts it rather than assumes
  it (the same `footprintFromRequest` / `assertFitsQuota` calls `createServer` uses).
- The new server's PVC defaults to `longhorn` (portable), per the hard-won comment in
  `impl.ts` — the new instance deliberately escapes the old server's cp1
  `local-path` pin. This is a feature: the upgrade is also the migration off the
  storage that no backup system can reach.

## A.6 Safety model (the heart — mandate §3)

Guarantees, each tied to the mechanism that enforces it:

1. **The old server's volume is never mutated.**
   - Capture execs a read-only `tar` inside the old server's *existing* pod
     (`pod-stream.ts`); it mounts nothing new and writes nothing to the volume.
   - The quiesce bracket writes no files; it issues RCON `save-off` / `save-all`,
     proves the flush by sampling anchor bytes, and **always** re-issues `save-on`
     (unconditional, on success and failure — `quiesce.ts` header).
   - The seed path's restore target is resolved **by server name = the new server**;
     Task 6 adds a `targetServer !== sourceServer` assertion plus a test that the
     restore deps never receive the source name.
   - Stopping the old server is `spec.replicas: 0` + the power-state intent — a
     scheduling verb, not a data verb.

2. **The copy is quiesced, or honestly labelled.**
   - A running source: quiesce bracket + flush proof → point labelled `quiesced`
     only if the anchor rewrite was *observed* (`claimedConsistency`).
   - A stopped-with-pod source: the world is at rest — "the strongest capture there
     is" (`timeline/route-support.ts`).
   - A source with no pod at all: the run **refuses** with the timeline's own
     `no-pod` message ("start it once") or, operator-chosen, uses the newest
     *existing verified* point with its timestamp displayed. It never silently
     substitutes stale data.
   - Every point is signed; restore verifies the signature **and** binds the index
     to the signed stream checksum before a byte moves (`restore.ts` steps 1–2).
   - Belt and braces for GTNH: the server's own ServerUtilities zips
     (`/home/container/backups/`, 30-min cadence) and the nightly
     `gt-new-horizons-archive` copies continue untouched — three independent
     recovery paths exist during the entire flow.

3. **The new instance is verified before anyone is pointed at it.**
   - Stage 1 (version proof): the new server first boots the new version on a
     *fresh* world. A pack that cannot even generate a world fails here, with zero
     data involved.
   - Stage 2 (seeded proof): after seeding, the first boot is watched with the
     rehearsal log-signature engine (`crash-report`, `world-load-failed`,
     `mixin-apply-failed`, `java-version-mismatch`, …) and the world-health checks
     (game port accepts a TCP connection; `level.dat` and `level.dat_old` pass
     `gzip -t`; log-writing distinguishes "loading" from "wedged" — the exact
     checks `world-health.yaml` runs for GTNH today).
   - The verdict vocabulary is the rehearsal's: `fail` only on observed candidate
     misbehaviour; anything the harness could not do is `inconclusive` with the
     step named. A verdict that cannot be trusted is worse than none.
   - The new DNS name resolves from creation (external-dns), but the flow's "done"
     state — the moment the UI shows "share this address" — is gated on the verdict.

4. **Rollback exists at every phase, and is stated per phase:**

   | Phase | Rollback | Cost |
   |---|---|---|
   | preflight / capture | none needed — nothing changed | zero |
   | old stopped (quota mode) | press Start on the old server | seconds |
   | new created / installing / fresh-boot | delete the new server (existing delete path); start old | the new PVC |
   | seeding (restore into new) | same — the seed writes only the new volume | same |
   | verifying | same | same |
   | done, players moved | stop new, start old — **with the divergence caveat below** | play since capture |

5. **The one thing this feature cannot promise, said out loud.**
   Once players join the new server, the old world is frozen at the capture point
   and the two histories diverge. "Rollback" after that means abandoning everything
   played on the new server. The confirm dialog and the done screen both carry this
   sentence; hiding it would be the WordPress-blue/green mistake `promote.ts`
   documents (shared database vs. unshared world).

## A.7 What "copy the data" means, file by file (mandate §2)

One capture point carries two streams, both signed: **world** (exists today, gap-fixed
for the dir name) and **identity** (new). What each engine copies and refuses:

**Every Minecraft Java server (vanilla, Paper, Forge, modpack):**

| Copied | Why |
|---|---|
| world dir(s) — resolved from `server.properties` `level-name`, plus `<name>_nether` / `<name>_the_end` when present (Paper split) | the world, incl. `playerdata/`, `data/`, region files |
| `ops.json`, `whitelist.json`, `banned-players.json`, `banned-ips.json`, `usercache.json` | "user info" — operators, allow/ban lists, UUID cache |
| `server.properties` | gameplay identity (level-name, motd, gamemode, difficulty, seed…). RCON keys are re-templated on boot anyway by the config-sync init (`egg-config-sync.ts`), so a copied file cannot smuggle stale credentials |

| Never copied | Why |
|---|---|
| `server.jar`, `libraries/`, `versions/`, `cache/`, `.mixin.out`, `dumps/` | version-specific; the new installer provides them |
| `logs/`, `crash-reports/`, `backups/`, `.infraweaver-backups/`, `.timeline-stage/` | noise / recursion traps (`UNIVERSAL_EXCLUDES` already refuses these) |
| `eula.txt` | re-generated from the create path's own EULA acceptance record — acceptance identity must be the new create's, not a copied file |

**GTNH specifically (modpack upgrade — the pack replaces the platform, the world stays):**

| Copied (adds to the base set) | Evidence |
|---|---|
| `World/` (capital) — via the level-name fix | `world-archive.yaml`, measured |
| `serverutilities/` | ranks & permissions — caught "falling out of a first draft" of the archive job |
| `visualprospecting/` | per-world ore discovery the World zip does not carry |
| `journeymap/` | server-side map data |
| `blueprints/` | player-created blueprints |

| Never copied for a GTNH version bump | Why |
|---|---|
| `mods/`, `config/`, `coretweaks/`, `scripts/`, `libraries/`, all top-level jars / launch scripts | **this is the update.** The new pack zip ships all of them; carrying the old set forward would undo the upgrade or corrupt it. Operators who customised `config/` diff old vs new via the Files tab afterwards (the old server remains browsable) |
| `World2/` | grouped with pack materials in `world-archive.yaml` ("changes only on a modpack update") — believed pack-owned, **Open question Q1** |

**Bedrock (phase 3):** `worlds/`, `allowlist.json`, `permissions.json`,
`server.properties`; never `bedrock_server` binaries.

**Paper plugins:** `plugins/` jars are version-sensitive and `plugins/<name>/`
subdirs hold data. The skeleton copies **neither** and says so in the dialog; phase 2
adds an opt-in "carry plugin data directories (not jars)" toggle. Copying half-right
silently is worse than copying nothing loudly.

**Consistency rule:** the identity stream is captured inside the same quiesce bracket
as the world stream — one point, one consistency label, no window where the world and
its ops file disagree.

## A.8 Where versions come from, per type (mandate §1)

All console-side fetches run in the console pod, which has world:443 egress (KNP
`infraweaver-console`, measured live). The pack/server **downloads** run in the game
pod's installer under CNP `allow-game-downloads` (world:443/80, label-scoped). The
cluster is airgapped-by-default; both holes exist today and no new hole is needed.

| Server type | Source of the dropdown | Cache | Feed unreachable |
|---|---|---|---|
| GTNH | scrape of `https://www.gtnewhorizons.com/downloads/` — extend `gtnh.ts` with `listGtnhVersions(channel)`: same `SERVER_PACK_PATTERN`, **all** matches, sorted desc (the scrape already collects them; today only the max is kept). Hosts pinned by `MODPACK_ALLOWED_HOSTS.gtnh` | in-memory TTL 1 h (the `minecraft-java-compat.ts` precedent), keyed by channel | dropdown shows the pinned known-good (`GTNH_PINNED_VERSION`, env-overridable) with an explicit warning banner — the existing resolver behaviour, surfaced instead of silent |
| CurseForge packs | `api.curseforge.com` files list for the pack id (the resolve response already carries `versions`; `/api/game-hub/modpacks/versions` grows a `curseforge` branch) | 1 h TTL keyed by packId | provider card disabled with the existing "no `CF_API_KEY`" affordance; on transient failure, last cached list + staleness note |
| FTB packs | `listFtbVersions(packId)` — **exists** | 1 h TTL | error surfaced verbatim via `ModpackResolveError` code, no fake list |
| Vanilla | `listMinecraftReleaseVersions()` — **exists** (Mojang `launchermeta` manifest) | 1 h TTL — exists | route already errors cleanly; UI shows "version feed unreachable — retry" |
| Paper (phase 2) | `fill.papermc.io/v3/projects/paper` versions + builds — the same API the installer already uses | 1 h TTL | same pattern |
| Forge/Fabric loaders (phase 2+) | the egg installer resolves loader builds at install time; the dropdown lists **MC versions** (Mojang manifest) and the loader build stays "latest for that MC version" | — | — |

"An update is available" comparison keys, per type: GTNH/CF/FTB — the
`infraweaver.io/modpack` annotation (`<provider>/<packId>@<versionId>`, live on GTNH as
`gtnh/gtnh@2.8.4-java17`) vs. the feed head. Vanilla/Paper — the
`VANILLA_VERSION` / `MINECRAFT_VERSION` env on the Deployment
(`MINECRAFT_VERSION_ENV_KEYS`) vs. the feed head. Servers whose version cannot be
determined show "unknown — pick a version manually", never a guessed banner.

Downgrade guard: the dropdown lists newer versions by default with an "show older /
all versions" expander; picking an **older** version than the world has seen is
allowed for modpacks (GTNH worlds are not forward-stamped the way vanilla is) but
carries a red warning for vanilla/Paper (Minecraft worlds do not load in older
versions once touched by a newer one).

## A.9 UI/UX (mandate §4)

**Where it lives.** Following the addon's explicit convention ("own pages rather than
more tabs on `pages/server-detail`, which is already 3.3k lines" —
`addon.manifest.ts`): a per-server page at **`/game-hub/[name]/update`**
(`pages/server-update.tsx`), registered in the manifest route table with
`requiredPermissions: ["game-hub:admin"]` (it creates servers and stops this one —
the `share` page precedent for admin-gating a page whose whole purpose is
privileged). Entry points:

- **Settings tab**: an "Update server" card in the existing "Export / Clone" section
  (`server-detail.tsx` ~line 2511) showing `current → newest available` and a button
  to the update page.
- **Dashboard tab**: a banner chip "Update available: 2.8.5" (only when the feed
  comparison says so), linking to the same page — the pattern the dashboard already
  uses for banners (`dashboard-banners.tsx`).

**The page** (wizard above, run view below — the `server-rehearsal.tsx` shape):

1. **Version step**: dropdown grouped by channel where relevant (GTNH: Java 17+ /
   Java 8), current version pinned at top and marked, newer versions listed newest
   first, feed state shown honestly (fresh / cached N min ago / unreachable →
   pinned-only + warning).
2. **Name & DNS step**: new server name, default `<name>-<version-slug>`
   (`gt-new-horizons-2-8-5`), validated by `validateK8sName`; DNS hostname field
   prefilled `<newname>.games.example.com` and editable (the create wizard's
   existing `dnsHostname` affordance — `new.tsx` line 749) — this is the "or ask
   what DNS to use" of the request. A note states the old address is untouched.
3. **Capacity panel**: the quota math, shown not implied — "GTNH requests 12Gi; the
   namespace allows 16Gi; **the old server will be stopped after the world is
   captured and before the new one starts**" (or "both fit; the old server keeps
   running — note the world snapshot is taken at the start, anything played after
   it stays on the old server only").
4. **Confirm dialog** — must state, before it acts:
   - source + target version, new server name and DNS name;
   - exactly what is copied and what is not (the engine's two lists from A.7,
     rendered, not summarised);
   - whether and when the old server stops, and that it is **stopped, never
     deleted**;
   - the divergence sentence (A.6.5);
   - expected downtime/duration (install ≈ pack download + unzip; GTNH ≈ 420 MB);
   - the final button is hold-to-confirm (`hold-gated-actions.tsx`, the existing
     danger-action pattern).
5. **Progress**: the run's phase list (`planned → capturing → source-stopped? →
   provisioning → fresh-boot-proof → seeding → verifying → done`), each phase with
   status, timestamps and its evidence line (point id + consistency label; pod
   events; log-signature findings verbatim). The page polls the run record — the
   rehearsal page convention. Failures show the phase's named error verbatim and
   the applicable rollback button (`Start old server`, `Delete new server`).
   An Abort button is present wherever abort is safe and states what it will do.
6. **Done screen**: the new address in a copy box, the verdict evidence, the
   divergence sentence again, and the old server's status ("stopped, intact — start
   it any time to go back").

## A.10 Execution mechanism (mandate §5)

**What runs the work: the console's API routes + a persisted run record + the
existing sweep pattern.** Explicitly not:

- **Not a GameServer-CRD controller** — the CRD is vestigial (zero CRs live); the
  console manages Deployments directly; building a controller contradicts the
  codebase's grain for zero gain here.
- **Not a copy Job** — rejected in A.4 (second capture path).

Mechanics:

- **Run record**: `UpgradeRun` JSON in ConfigMap `game-hub-upgrade-<server>`
  (`rehearsal/store.ts` shape: one CM per server, `run-<id>.json` keys, no ArgoCD
  tracking label, `resourceVersion` CAS on every write, phase read from the record
  never inferred). Persisted after **every** phase transition so the UI and the
  resumer both see truth.
- **Idempotency per phase**: every phase is a check-then-act:
  capture records the point id in the run before phase-advance (re-run finds it);
  provisioning checks whether Deployment `<newName>` exists before creating;
  seeding is guarded by the restore machinery's own staged-marker + release gates;
  stop/start phases re-assert scale (idempotent by nature). A crashed console pod
  mid-run therefore resumes by re-executing the current phase from its record.
- **Resume**: a sweep (piggybacking the existing `game-hub-power-sweep` CronJob
  cadence, or a sibling `upgrade-sweep` following `deferred/sweep.ts`) lists
  upgrade CMs, finds non-terminal runs whose `updatedAt` is older than the phase
  budget, and either resumes the phase or fails it with `inconclusive:
  console-restarted` — never leaves a run silently frozen. The sweep names work
  from the run record only (the `deferred/catalog.ts` rule: the queue may only
  *name* work the code implements).
- **Concurrency guards**: one active run per server (store check), and a fleet-wide
  cap of 1 active upgrade (these runs hold GiBs); a second start is refused with
  `busy` — the rehearsal's `StartRefusalCode` pattern.
- **Who copies bytes**: capture = exec tar in the source pod streaming to the
  datastore pod's chunk store (existing); seed = `streamToPod` into the **new**
  server's writable companion (existing `resolveRestoreTarget`, pointed at the new
  server). No new pod spec is invented for data movement; the companion is already
  restricted-compliant and quota-floor-sized.
- **State back to the UI**: `GET /api/game-hub/servers/[name]/update` returns the
  latest run (+ version feed + capacity plan for the wizard); the page polls. Same
  transport as rehearsal/timeline pages.

## A.11 Phasing (mandate §6)

**Phase 0 — prerequisites (operator, no code):** verify the timeline answers on this
console (`GET /api/game-hub/servers/gt-new-horizons/timeline` — flag resolves ON via
`PLATFORM_ENABLE_ALL`, datastore pod + 30Gi PVC verified live); take one manual
capture of a cheap server end-to-end to prove the datastore path before building on
it. Confirm the `infraweaver-console` Deployment is healthy (1/2 with one pod in
Error observed 2026-08-18 — an unrelated instability that a long-running
orchestration should not be built on top of; see Q6).

**Phase 1 — walking skeleton (the deliverable of the task list below):**
GTNH-shaped Minecraft Java only. GTNH version dropdown (list, not just head). New
server on auto-suggested, editable DNS name. Quota mode `requires-source-stopped`
implemented; `fits-together` recognised but small-server-only by arithmetic. The two
layout gaps fixed (level-name resolution + identity stream). Seed via cross-server
restore. Verification = rehearsal log signatures + port + `level.dat gzip -t`.
Rollback buttons. No old-DNS cutover, no plugin copies, no Bedrock.

**Phase 2:** vanilla + Paper types (Paper v3 version feed, plugin-data opt-in);
CurseForge/FTB dropdowns; "adopt the old DNS name" as an explicit post-verify cutover
step (swap the Service `external-dns` hostname annotations + re-publish SRV +
UDM forward note — upsert-only external-dns makes the old record linger, so the
cutover is annotation-move + TTL-60 wait, documented in the dialog); a git-authored
`world-health` CronJob template stamped per new server; quota-raise guidance link.

**Phase 3:** Bedrock engine; "archive the old server" (delete with `Retain`-class PV
kept + timeline point pinned); integration with Update Rehearsal ("rehearse this
version first" shortcut when `GAMEHUB_REHEARSAL` is on); bulk "update all vanilla
servers" via the bulk-ops surface.

## A.12 How to make it work — operator steps once built (mandate §7)

Prerequisites (someone must have done these once):

1. Console reachable and healthy; `PLATFORM_ENABLE_ALL=1` (live) or explicitly
   `GAMEHUB_TIMELINE=on` + `GAMEHUB_UPDATE=on` on the console Deployment.
2. The backup **datastore** pod running with its PVC (live today:
   `infraweaver-backup`, 30Gi longhorn-retain) — the timeline store lives there.
3. Cloudflare token configured (live — external-dns + console SRV path already
   publish game records) and `PUBLIC_INGRESS_IP` set (live: 203.0.113.10).
4. For CurseForge packs only: `CF_API_KEY` set. GTNH/FTB/vanilla need no key.
5. `game-hub:admin` on the operator's role for the server in question.
6. Enough namespace quota for **one** server of the target's size to run (the flow
   sequences around the rest); enough storage quota for one more PVC (checked in
   preflight, shown in the wizard).

Using it (GTNH example):

1. Open **Game Hub → gt-new-horizons → Settings → Update server** (or click the
   dashboard's "Update available" banner).
2. Pick the target version from the dropdown (e.g. `2.8.5`, Java 17+ channel).
3. Accept or edit the new server name (`gt-new-horizons-2-8-5`) and its DNS name
   (`gt-new-horizons-2-8-5.games.example.com`).
4. Read the capacity panel: for GTNH it will say the old server stops after the
   world snapshot is taken.
5. Read the confirm dialog (what's copied / not copied / divergence / downtime);
   hold the confirm button.
6. Watch the phases. Expected duration: capture minutes (the whole GTNH volume is
   2.9 GiB actual per `world-archive.yaml`, and the world stream is a fraction of it),
   install ≈ pack download + unzip, seeded boot ≈ GTNH's usual multi-minute mod
   load. Failures stop with a named phase error and a rollback button.
7. On the done screen, join `gt-new-horizons-2-8-5.games.example.com` yourself
   and check your builds/inventory; then share the address with players.
8. Rollback at any time before players commit: **Start** on the old server (it was
   only stopped). Delete the new server whenever satisfied — or keep both.

## A.13 Open questions (verified-unknowns, not assumptions)

- **Q1 — `World2/`.** Grouped with pack materials in `world-archive.yaml` ("changes
  only on a modpack update"), which implies pack-owned, but nothing on this machine
  proves it holds no per-server state. Verify inside the pod before finalising the
  GTNH identity set (one `ls -la`/mtime inspection during Task 3).
- **Q2 — GTNH cross-version config expectations.** GTNH release notes occasionally
  require carrying specific config or running migration steps between versions. The
  skeleton's "never copy `config/`" default matches a clean-pack upgrade; the release
  notes for the *actual* target version must be linked in the confirm dialog
  ("read the pack's changelog") — the feed page scrape can carry the changelog URL.
  Whether any GTNH version pair requires a `config/` carry-over is unverified.
- **Q3 — capture of a fully stopped server (no pod).** The timeline requires *a*
  pod as exec source; today the answer is "start it once". Whether to grow a
  read-only companion as a capture source (clean, but a new code path in
  `route-support.ts`) or accept "start it once" in the skeleton is an implementation
  decision deferred to Task 5; the run must handle both truthfully either way.
- **Q4 — `server.properties` carry policy.** Skeleton carries the whole file (then
  config-sync re-templates RCON keys on boot). If the new pack's file carries new
  keys with load-bearing defaults, whole-file carry drops them. A key-merge (carry
  gameplay keys onto the new pack's file) is safer but needs a defined key list.
  Decide during Task 3 with a diff of 2.8.4-vs-newer stock files.
- **Q5 — `level-name` resolution edge**: a copied `server.properties` whose
  `level-name` matches the copied world dir is self-consistent by construction, but
  the *new pack's* startup scripts may assume `World` specifically (GTNH's do).
  Covered by keeping the source's names verbatim; flagged for the Task 3 test list.
- **Q6 — console pod stability.** `infraweaver-console` observed 1/2 Available with
  one pod in Error during design. The resume/sweep design (A.10) exists precisely
  because a run must survive a console restart — but the underlying instability
  should be diagnosed before shipping Phase 1.
- **Q7 — WAN forward for the new server.** `setupWanPortForward` runs on create and
  is best-effort against the UDM connector; unverified whether the connector is
  currently configured live (`getUdmClientAsync` returns null when not). The SRV
  record publish is gated on the WAN port, so if the connector is absent the new
  hostname will need the `:nodePort` suffix — the done screen must detect and say
  which of the two shapes applies (the create path already returns this).

---

# Part B — Implementation plan (Phase 1 walking skeleton)

All paths are under `/home/runner/InfraWeaver-platform/apps/infraweaver-console`
unless stated. Tests run with the repo's jest setup — **shard or `--maxWorkers=1`**
(full runs OOM this box; known constraint). TypeScript: `tsc` needs ~4 GB — do not
run beside other heavy processes. Commit after every task with a conventional
message; do not push from this plan.

### Task 1: GTNH version listing

**Files:**
- Modify: `src/addons/gamehub/lib/modpacks/gtnh.ts`
- Test: `src/addons/gamehub/lib/modpacks/__tests__/gtnh-versions.test.ts` (follow the sibling test layout used by `curated-packs.test.ts` — locate it and mirror placement)

**Interfaces:**
- Consumes: existing `scrapeServerPacks`/`SERVER_PACK_PATTERN` internals, `fetchAllowed` from `modpacks/hosts.ts`, `ModpackVersionSummary` from `modpacks/types.ts` (`{ id, name, type, releasedAt? }`).
- Produces: `export async function listGtnhVersions(channel: GtnhChannel): Promise<{ versions: ModpackVersionSummary[]; source: "live" | "pinned-fallback"; warnings: string[] }>` — versions sorted newest-first by `compareDottedVersions`, `id` = `<version>-<channel>` (matching the resolver's `versionId` format so a picked row feeds `resolveModpackRef` unchanged), `type` = `"release"`.

- [ ] **Step 1: Write the failing test** — pure-parse tests against a fixture HTML string containing three `GT_New_Horizons_<v>_Server_Java_17-25.zip` links out of order plus one `Java_8` link: expect 3 rows for `java17`, sorted `2.8.5, 2.8.4, 2.8.0`, ids `2.8.5-java17`…; expect 1 row for `java8`. Add a fallback test: a fetch failure (mock `fetchAllowed` to throw) yields `source: "pinned-fallback"`, one row = pinned version, and a warning string.
- [ ] **Step 2: Run the test, verify it fails** (`listGtnhVersions is not a function`).
- [ ] **Step 3: Implement** — extract the existing scrape into a shared helper; `listGtnhVersions` reuses it, maps to summaries, dedupes, sorts desc; on any failure falls back to the pinned version with the same warning text style the resolver uses.
- [ ] **Step 4: Run the test, verify it passes.**
- [ ] **Step 5: Commit** — `feat(gamehub): list all GTNH server-pack versions per channel`.

### Task 2: world-dir resolution (gap 1)

**Files:**
- Modify: `src/addons/gamehub/lib/worlds/world-layout.ts`
- Modify: `src/addons/gamehub/lib/timeline/route-support.ts` (thread the resolved name), `src/addons/gamehub/lib/timeline/capture.ts` only if the layout is built there — follow the single call site of `worldLayoutForEgg` on the capture path.
- Test: alongside the existing world-layout tests (locate `world-layout` in `src/**/__tests__` and extend).

**Interfaces:**
- Produces: `worldLayoutForEgg(egg, worldName?: string)` — optional third input: when provided, `include`/`anchors`/`probePaths` are built from `./<worldName>`, `./<worldName>_nether`, `./<worldName>_the_end` instead of the lowercase constants; when absent, behaviour is byte-identical to today (pinned by a regression test).
- Produces: `export function levelNameFromProperties(text: string): string | null` — parses `level-name=` from `server.properties` content (trimmed, comment-safe); pure.
- The capture path reads `server.properties` via the existing pod-exec channel (one `cat`, same exec transport as the flush probe) and passes the resolved name; a missing/unreadable file falls back to the current defaults **and records a warning in the manifest** (omit-rather-than-fake).

- [ ] **Step 1: Failing tests** — `levelNameFromProperties("level-name=World\nmotd=x")` → `"World"`; `level-name=My World` → `"My World"` (space-in-name legal — `world-scripts.ts` PATH_TRAPS allow interior spaces); missing key → null. Layout test: `worldLayoutForEgg(gtnhEgg, "World").include` deep-equals `["./World", "./World_nether", "./World_the_end"]` and anchors start with `./World/level.dat`; `worldLayoutForEgg(gtnhEgg)` unchanged vs. a snapshot of today's output.
- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement** (pure functions; keep `world-layout.ts` free of I/O per its header).
- [ ] **Step 4: Run, verify pass. Also run the existing timeline test files touching layout to catch regressions.**
- [ ] **Step 5: Commit** — `fix(gamehub): resolve Minecraft world dir from level-name (GTNH uses World/)`.

### Task 3: identity stream (gap 2)

**Files:**
- Create: `src/addons/gamehub/lib/worlds/identity-layout.ts`
- Modify: `src/addons/gamehub/lib/timeline/capture.ts`, `src/addons/gamehub/lib/timeline/manifest.ts` (a second `ManifestStream` named by a new `IDENTITY_STREAM` const beside `WORLD_STREAM` in `timeline/layout.ts`), `src/addons/gamehub/lib/timeline/restore.ts` (restore both streams when present; points without an identity stream restore exactly as today).
- Test: `src/addons/gamehub/lib/worlds/__tests__/identity-layout.test.ts` + extend the capture/restore manifest tests.

**Interfaces:**
- Produces: `export interface IdentityLayout { include: readonly string[]; optional: readonly string[] }` and `export function identityLayoutForEgg(egg: WorldEggFacts): IdentityLayout` — minecraft-java base: `["./ops.json","./whitelist.json","./banned-players.json","./banned-ips.json","./usercache.json","./server.properties"]`; when the egg id starts with `modpack/gtnh/`: plus `["./serverutilities","./visualprospecting","./journeymap","./blueprints"]`. `generic`/bedrock: empty (phase 3). Missing files are warnings, not failures (the archive job's "not captured" report is the model).
- The identity tar is produced **inside the same quiesce bracket** as the world tar and lands as a second stream in the same signed manifest.
- `eula.txt` is explicitly excluded (test-pinned): acceptance belongs to the new create.

- [ ] **Step 1: Failing tests** — base list for a vanilla egg; GTNH egg adds the four dirs; bedrock/generic empty; `eula.txt` never present in any list. Manifest round-trip test: a manifest with two streams parses; a legacy one-stream manifest still parses (back-compat pinned).
- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement.** During this task, resolve **Q1** (inspect `World2/` in the GTNH pod: file types + mtimes vs. pack install date) and **Q4** (diff stock `server.properties` across two pack versions); record both answers as comments in `identity-layout.ts` in the archive-yaml evidence style.
- [ ] **Step 4: Run, verify pass; run timeline capture/restore test files.**
- [ ] **Step 5: Commit** — `feat(gamehub): capture server identity files alongside the world`.

### Task 4: upgrade run vocabulary + store

**Files:**
- Create: `src/addons/gamehub/lib/upgrade/types.ts` (pure), `src/addons/gamehub/lib/upgrade/store.ts` (`server-only`)
- Test: `src/addons/gamehub/lib/upgrade/__tests__/types.test.ts`, `.../store.test.ts` (mirror `rehearsal/store.ts` tests — same CAS/409-retry cases).

**Interfaces (produced, exact):**

```ts
export const UPGRADE_SCHEMA = "game-hub.upgrade.run/v1";
export type UpgradePhase =
  | "planned" | "capturing" | "stopping-source" | "provisioning"
  | "fresh-boot-proof" | "seeding" | "verifying"
  | "done" | "failed" | "aborted";
export type CapacityMode = "fits-together" | "requires-source-stopped";
export interface UpgradeTarget {
  readonly ref: ModpackRef | { kind: "vanilla"; version: string }; // vanilla arm unused until phase 2
  readonly versionName: string;
  readonly newServerName: string;
  readonly dnsHostname: string;
}
export interface UpgradeRun {
  readonly schema: typeof UPGRADE_SCHEMA;
  readonly id: string;                    // point-id-style timestamp + random suffix
  readonly server: string;                // the SOURCE server
  readonly target: UpgradeTarget;
  readonly capacityMode: CapacityMode;
  readonly phase: UpgradePhase;
  readonly pointId: string | null;        // set at end of "capturing"
  readonly sourceStopped: boolean;        // set by "stopping-source"
  readonly newServerCreated: boolean;     // set by "provisioning"
  readonly verdict: UpgradeVerdict | null;// set by "verifying"
  readonly error: string | null;          // phase-named, verbatim for the UI
  readonly startedBy: string;
  readonly startedAt: string;
  readonly updatedAt: string;
}
export type UpgradeVerdict =
  | { kind: "pass"; evidence: readonly string[] }
  | { kind: "pass-with-warnings"; evidence: readonly string[] }
  | { kind: "fail"; findings: readonly RehearsalFinding[] }     // reuse rehearsal's type
  | { kind: "inconclusive"; step: string; reason: string };
export function isTerminalUpgradePhase(phase: UpgradePhase): boolean;
export function nextAllowedPhases(phase: UpgradePhase): readonly UpgradePhase[]; // the state machine, pure
```

Store: ConfigMap `game-hub-upgrade-<server>` in `game-hub`, keys `run-<id>.json`,
no ArgoCD tracking labels, `resourceVersion` CAS with 3 attempts, run history capped
(mirror `MAX_RUN_HISTORY`).

- [ ] **Step 1: Failing tests** — state machine: `nextAllowedPhases("planned")` is `["capturing","aborted"]`; `"capturing"` → `["stopping-source","provisioning","failed","aborted"]` (stopping only in `requires-source-stopped` mode — encode mode into a second parameter or assert in the transition helper); terminal phases return `[]`; store: write/read round-trip, 409 retry, newest-is-not-automatically-live (read by id).
- [ ] **Step 2–4: red → implement → green.**
- [ ] **Step 5: Commit** — `feat(gamehub): upgrade run vocabulary and per-server store`.

### Task 5: orchestration

**Files:**
- Create: `src/addons/gamehub/lib/upgrade/run.ts` (the phase executor, deps-injected exactly like `rehearsal/run.ts` — every step converts its exception into a phase-named error), `src/addons/gamehub/lib/upgrade/capacity.ts` (pure: `planCapacity(sourceRequests, quotas) → CapacityMode | { refused: reason }` using `footprintFromRequest`/`assertFitsQuota` arithmetic)
- Test: `.../__tests__/run.test.ts` with fake deps (the rehearsal test style: assert *which* deps were called per phase, and that the source-server deps are **never** passed a write verb — the Task 6 invariant lives here too).

**Interfaces:**
- Consumes: timeline capture (`route-support.ts` entry, with Task 2/3 layouts), `createServer` (via a thin `provisionTarget` dep so tests fake it), power-state stop/start, `resolveRestoreTarget` + `restorePoint` (Task 6 wrapper), rehearsal `log-signatures` + `judge`-style verdict assembly, `game-hub-companion` release gates.
- Produces: `export async function advanceUpgrade(run: UpgradeRun, deps: UpgradeDeps): Promise<UpgradeRun>` — executes exactly ONE phase and returns the persisted successor; the route and the sweep both drive it, which is what makes resume trivial.
- Phase behaviours (each idempotent, each check-then-act):
  - `capturing`: if `run.pointId` set, skip forward. Else capture from the source pod (running → quiesce; stopped-with-pod → at-rest; no pod → refuse with the timeline's `no-pod` message, or accept the operator's pre-selected existing point id from the wizard).
  - `stopping-source` (only `requires-source-stopped`): scale 0 + power intent + wait zero pod objects (the promote/restore rule — never `deletionTimestamp`).
  - `provisioning`: if Deployment `<newServerName>` exists, skip; else call `createServer` with the target ref, `dnsHostname`, and the source's memory/cpu/storage as defaults.
  - `fresh-boot-proof`: watch the new pod to Ready (or first crash) with the rehearsal observation window; a crash here is `fail` with findings and **no data has moved**.
  - `seeding`: stop the new server, wait zero pods, cross-restore the point (Task 6), start it.
  - `verifying`: observe the seeded boot (log signatures) + port-accepts + `level.dat gzip -t` via one exec probe (reuse `flushProbeScript`'s transport, or the world-health check shapes); assemble `UpgradeVerdict` with the rehearsal's fail/inconclusive discipline.
- [ ] **Steps: red (fake-deps tests per phase incl. idempotent re-entry and the never-write-source assertion) → implement → green → commit** — `feat(gamehub): upgrade orchestration, one phase per advance`.

### Task 6: cross-server restore target

**Files:**
- Create: `src/addons/gamehub/lib/upgrade/seed.ts`
- Modify: `src/addons/gamehub/lib/timeline/restore-target.ts` only if its signature needs the target name threaded (it already takes a server name — the change is the *caller* passing the new server); do not fork the restore.
- Test: `.../__tests__/seed.test.ts`.

**Interfaces:**
- Produces: `export async function seedNewServer(input: { sourceServer: string; targetServer: string; pointId: string }, deps: SeedDeps): Promise<void>` — **throws** `SeedRefusal("same-server")` when `sourceServer === targetServer`; verifies the point's manifest egg-engine equals the target's engine (`worldEngineForEgg` both sides) before any stop; then delegates to `resolveRestoreTarget(targetServer)` + `restorePoint` with both streams. The mandatory pre-capture step of `restorePoint` is **skipped for a fresh target** only via its existing deps surface if one exists — otherwise leave it on (capturing the throwaway fresh world is wasted minutes, not a hazard) and note the cost in the run's phase evidence.
- [ ] **Steps: red (same-server refusal; engine-mismatch refusal; deps receive only the target name — assert the source name never reaches restore deps) → implement → green → commit** — `feat(gamehub): seed a captured point into a different server`.

### Task 7: API routes

**Files:**
- Create: `src/app/api/game-hub/servers/[name]/update/route.ts` (GET: latest run + version list + capacity plan; POST: start — validates target with zod, re-resolves the version ref server-side exactly as `createServer` does via `resolveModpackRef`, refuses on `busy`/`already-running`), `src/app/api/game-hub/servers/[name]/update/abort/route.ts` (POST).
- Modify: `src/lib/feature-defaults.ts` — register `{ flag: "GAMEHUB_UPDATE", label: "Server Update", area: "game-hub", accepts: ON_TRUE_ONE_WORDS, dependsOn: ["GAMEHUB_TIMELINE"] }`.
- Test: route tests in the pattern of the existing rehearsal route tests (locate them beside the rehearsal routes and mirror auth/permission/rate-limit cases).

**Interfaces:**
- `withAuth({ permission: "game-hub:admin", scope: "/game-hub/" , rateLimit: { name: "game-hub-update", limit: 10, windowMs: 60_000 } }, …)`; server name through `validateK8sName`; every refusal is a named code + sentence (503 with the flag's reason when gated — the timeline's `availability` pattern).
- POST body (zod): `{ provider: "gtnh", channel: "java17"|"java8", versionId: string, newServerName: string, dnsHostname: string, useExistingPointId?: string }`.
- [ ] **Steps: red → implement → green → commit** — `feat(gamehub): server update API routes behind GAMEHUB_UPDATE`.

### Task 8: sweep resume

**Files:**
- Create: `src/addons/gamehub/lib/upgrade/sweep.ts` (list upgrade CMs; for each non-terminal run stale past its phase budget: call `advanceUpgrade` once, or mark `inconclusive: console-restarted` after N failed resumes) + wire into the existing sweep cron surface the way `deferred/sweep.ts` is wired (locate its caller — the power-sweep route — and register alongside).
- Test: `.../__tests__/sweep.test.ts` — a stale `capturing` run gets advanced; a terminal run is untouched; a run past its resume budget is failed with the named reason.
- [ ] **Steps: red → implement → green → commit** — `feat(gamehub): resume abandoned upgrade runs from the sweep`.

### Task 9: UI

**Files:**
- Create: `src/addons/gamehub/pages/server-update.tsx`, `src/addons/gamehub/components/update/` (wizard-steps.tsx, capacity-panel.tsx, confirm-dialog.tsx, run-progress.tsx, copy-matrix.tsx — the A.7 lists rendered from a shared pure module so dialog and docs cannot drift).
- Modify: `src/addons/gamehub/addon.manifest.ts` (route `{ path: "/game-hub/[name]/update", component: "pages/server-update", title: "Server Update", group: "gaming", requiredPermissions: ["game-hub:admin"] }`), `src/addons/gamehub/pages/server-detail.tsx` (Settings tab card beside Export/Clone; dashboard banner via the existing banners component).
- Test: component tests for the pure pieces (copy-matrix renders both lists; confirm-dialog refuses to enable the hold button until the capacity mode is displayed; progress renders every `UpgradePhase`).
- [ ] **Steps: red → implement → green → commit** — `feat(gamehub): server update page, settings entry, dashboard banner`.
- Note: the repo has ratchet tests (`route-scope-manifest.test.ts` AST census, status-dot ratchets) that **silently reject unregistered routes** — run the manifest/ratchet test suite after wiring the route and expect to update the census fixtures deliberately.

### Task 10: end-to-end rehearsal of the feature itself (manual gate, not CI)

- [ ] Stand up a **small throwaway vanilla server** via the console; run a full update through the UI (small pack = fast cycle, `fits-together` mode) — verify: point captured with both streams; new server named + DNS'd; seed verified; old untouched (compare a checksum of one region file before/after).
- [ ] Then the GTNH-shaped dry run in `requires-source-stopped` mode against a clone-scale stand-in (NOT production GTNH), verifying the stop/start sequencing and rollback buttons.
- [ ] Only after both: offer the operator the real GTNH run (their call, their timing — the flow was designed so this is boring).

## Self-review checklist (run after implementation, per task)

- Spec coverage: every A-section requirement maps to a task (A.8→T1, A.3.1→T2, A.3.2/A.7→T3, A.10→T4/5/8, A.6→T5/6 invariant tests, A.9→T9, §7→A.12 + T10).
- The never-write-the-source invariant has a **test**, not a comment, in both T5 and T6.
- Type names used across tasks match (`UpgradeRun`, `UpgradePhase`, `CapacityMode`, `advanceUpgrade`, `seedNewServer`, `listGtnhVersions`, `identityLayoutForEgg`, `levelNameFromProperties`).
- No task edits the live cluster; the only infra-repo change in Phase 1 is **none** (quota raise is documented as an operator decision, deliberately not a task).

---

# Part C — What is BUILT, what it corrects in Part A, and how to make it work

> Written 2026-08-18 after implementing the first slice. Everything in this part
> is either shipped code with a test behind it or a measured fact from the live
> cluster. Commits are in `/home/runner/InfraWeaver-platform` (local only, not
> pushed).

## C.1 What shipped

| Plan task | State | Commit |
|---|---|---|
| Task 2 — world-dir resolution | **DONE** | `9ad28f1b` |
| Task 3 — identity stream (capture **and** restore) | **DONE** | `ca525ed6` |
| Task 1 — GTNH version list | **DONE**, plus the version now actually builds | `3668cbf5` |
| Task 5 — `capacity.ts` `planCapacity` | **DONE** (the phase executor is not) | `f42ae312` |
| Tasks 4, 5 (`run.ts`), 6, 7, 8, 9, 10 | **NOT STARTED** | — |

126 gamehub suites / 2905 tests green; `tsc --noEmit` and `eslint` clean.

## C.2 Corrections to Part A — places the plan was wrong about the code

**A.3.1 was right about the bug and wrong about its severity, in the safe
direction.** The claim is that a GTNH capture today "would tar three nonexistent
paths … and produce an empty point that verifies". It does not. Two guards catch
it first:

- `worlds/flush-proof.ts` `decideFlushProof` → `pickAnchor` finds no existing
  anchor and returns `safe: false, code: "anchor-missing"` ("No world data was
  found on this server (no level.dat under any world directory)"). `capture.ts`
  turns a `!safe` proof into a refusal before a byte is read.
- Even past that, `worlds/world-scripts.ts` `worldTarScript` guards its include
  list with `[ -e ]` and `[ "$#" -gt 0 ] || exit 8`, and `capture.ts` refuses a
  zero-byte world stream as `empty-world`.

So the pre-fix behaviour was a **loud failure with a misleading message**, not a
silent empty point. The fix is unchanged; the framing is.

**Task 1's stated rationale does not hold, and hid a worse bug.** The plan says
the version ids should match `versionId` format "so a picked row feeds
`resolveModpackRef` unchanged". It does feed it unchanged — and
`modpacks/resolve-ref.ts:47` called `resolveGtnh(channel)`, which takes **only a
channel** and always returns the downloads page's HEAD. The version half of the
id was discarded. `isVersionDrift`, written for exactly this hazard, has **zero
callers** (one definition at `resolve-ref.ts:63`, no uses anywhere). A dropdown
built on that contract would have let an operator confirm 2.8.4 and get 2.8.5.
`resolveGtnh` now takes an optional version and `resolveModpackRef` passes it.

**Task 3's GTNH gate is not expressible.** The plan says the four modded
directories apply "when the egg id starts with `modpack/gtnh/`". `WorldEggFacts`
(`worlds/world-layout.ts`) carries `gameType`, `name`, `dockerImage`,
`mountPath` and the save commands — **no egg id**. The available substitute is a
name substring, which would silently drop ranks, ore discovery and blueprints
for a GTNH server an operator named something else. Since a path that does not
exist costs nothing (`worldTarScript` drops it), the four are listed for every
Minecraft Java server, with `IdentityLayout.modded` keeping the groups
distinguishable for the UI.

**A.7's identity file list is missing two files that the live server has.**
Measured at `/home/container` on 2026-08-18: `usernamecache.json` (Forge's
UUID↔name cache beside `usercache.json`; without it every offline player's name
is unresolvable until they next log in) and `server-icon.png`. Both are now
captured.

**Restore had to change too, and the plan does not say so.** Fixing capture
alone would have been worse than not fixing it: a point captured as `World`
restored through a `./world` layout moves nothing aside and then `mv`s the
incoming `World` **into** the live `World/`, giving `World/World`. The resolved
name is therefore recorded on the point (`manifest.worldName`), it is **signed**
because it decides what a restore destroys, and `restorePoint` builds its layout
from the point. The identity stream also restores through its own staging
directory `.timeline-stage-identity` — sharing `.timeline-stage` would make the
second restore rotate the first's move-aside copy of the world into
`previous.prior` and delete it on success, destroying the only rollback copy at
the exact moment the restore reported success.

## C.3 Q1 — ANSWERED. `World2/` is out.

Measured inside the running pod on 2026-08-18:

```
/home/container/World2/level.dat        213,299 bytes   Jul 29 12:46
/home/container/World2/playerdata/      EMPTY
/home/container/World2                  25M, own region/ and full DIM* set
/home/container/World/level.dat         213,302 bytes   Aug 18 20:43  (current)
```

It is a real world, not pack material — the pack was installed Jul 28 16:14 and
`World2` first appears a day later, so it is server-generated. But its
`playerdata/` is empty and its `level.dat` has not been rewritten since the day
it appeared, while `World/level.dat` is current to the minute. **Nothing has ever
been played in it.** Not copying it loses nothing measurable, which is the reason
it is out; the evidence is recorded in `worlds/identity-layout.ts` so the
decision can be revisited if a GTNH release ever makes it load-bearing.

Q2, Q4, Q5, Q6 and Q7 remain open. Q3 is moot for the shipped slice: capture
still requires a pod, and `runCapture` already refuses with the `no-pod` message.

## C.4 How to make it work — TODAY

Only one of the operator-visible behaviours has actually changed yet: **the
World Timeline can now protect GT New Horizons.** Before this slice it could
not, at all.

Prerequisites (all verified live on 2026-08-18):

1. The console is up and `PLATFORM_ENABLE_ALL=1` (so `GAMEHUB_TIMELINE`
   resolves ON), or `GAMEHUB_TIMELINE=on` explicitly.
2. The `infraweaver-backup` datastore pod is running with its 30Gi
   `longhorn-retain` PVC — that is where timeline points live.
3. The server has a **pod** (running or stopped-with-pod). A server scaled to
   zero with no pod is refused with "Start it once".
4. `game-hub:admin` on your role for that server.

To use it:

1. Deploy the console image built from this commit. Nothing else changes —
   no manifest edits, no quota change, no restart of the game server.
2. Open **Game Hub → gt-new-horizons → Timeline → Capture now**.
3. It should now succeed where it previously refused with *"No world data was
   found on this server (no level.dat under any world directory)"*.
4. Check the point's detail. Two things prove the fix end to end:
   - the point lists **two streams**, `world.tar` and `identity.tar`;
   - its manifest carries `worldName: "World"`. If that field is absent and
     there is a warning about `server.properties`, the properties read failed
     and the capture fell back to the vanilla directories — the capture is then
     as broken as before, but it now says so instead of blaming the world.
5. Verify the point (**Verify** on the point) before trusting it. That
   re-derives every chunk digest and both stream checksums.

⚠️ Do not test the RESTORE half against production GTNH. Restore is destructive
by design and the two-stream path has unit coverage but no live rehearsal yet.
Stand up a throwaway vanilla server and prove the round trip there first — that
is Task 10 and it has not been done.

## C.5 How to make it work — the full update flow, once the rest lands

Unchanged from A.12 except for the two corrections below. Re-read A.12 for the
steps; these are the amendments.

- **Step 2 (pick a version) now means something.** `listGtnhVersions(channel)`
  returns every published version newest-first, and the picked one is the one
  that gets installed. If the console cannot reach
  `https://www.gtnewhorizons.com/downloads/`, the dropdown shows **exactly one
  row — the pinned known-good version — labelled `pinned-fallback` with a
  warning naming it.** It is never empty. An empty dropdown reads as "there are
  no updates", which is indistinguishable from "you are up to date"; that
  sentence is the one this feature must never say by accident. **The UI must
  render the `source` label and the warnings** — a silent fallback is the same
  lie one step later.
- **Step 4 (the capacity panel) is computed, not asserted.** `planCapacity`
  returns one of four modes and the arithmetic behind it:
  `fits-together`, `requires-source-stopped`, `refused`, `unknown`. For GTNH
  against the live quota it returns `requires-source-stopped` with
  `requests.memory would need 12Gi but only 4Gi is free (12Gi of 16Gi used)`.
  `unknown` (the quota could not be read) must **stop the flow**, not default to
  either mode — it decides whether a running server gets stopped.
- To run both side by side instead, raise `requests.memory` in
  `kubernetes/catalog/game-hub/manifests/resource-quota.yaml` and let ArgoCD
  sync. Nothing in this feature edits a quota.

## C.6 What a fresh worker should do next

In order, because each depends on the last:

1. **Task 10's first half, early.** Stand up a throwaway vanilla server, take a
   point, restore it, and diff. The two-stream capture/restore path has 20 unit
   tests and zero live runs. Do this before Task 5, not after.
2. **Task 4** (`upgrade/types.ts` + `store.ts`) — the run vocabulary. Note the
   phase list will want a `capture-identity` step; `capture.ts` already emits
   one on its job record.
3. **Task 6** (`seed.ts`) before Task 5's `run.ts`: the cross-server restore is
   where the never-write-the-source invariant lives, and `restorePoint` now
   restores two streams, so `seedNewServer` gets both for free.
4. **Task 5** (`run.ts`), then **7**, **8**, **9**.

Two things to know before touching Task 5:

- `restorePoint`'s pre-restore capture is mandatory and its failure ABORTS. On a
  freshly created target with a generated world that is a wasted capture, not a
  hazard — leave it on and record the cost in the phase evidence, as the plan
  says.
- `RestoreOutcome`'s `restored` arm now carries optional `warnings`. A failed
  identity restore lands there rather than as a refusal, because by then the
  world is already swapped in. The run's verdict assembly must read them, or a
  server whose `ops.json` did not land will be reported as a clean pass.

---

# Part D — The first LIVE run, and the four defects it found

> Written 2026-08-19 after standing up a throwaway server and driving the real
> capture/restore code against it. Commits (local, not pushed):
> `457dffcf` probe path, `11984fab` LimitRange floor, `220c11c7` stream
> transport.
>
> Everything here is measured. The unit suite was green for all of it
> beforehand — none of these defects was findable without a cluster.

## D.1 What was run

A throwaway `tl-roundtrip` was created in `game-hub` through the console's own
`createServer` (egg `minecraft-java`, itzg image, `TYPE=VANILLA`, 2Gi request,
5Gi `longhorn` PVC), with two deliberate deviations: `dnsHostname: ""` so no
external-dns record was published for a server about to be deleted (external-dns
here is upsert-only), and no UDM connector configured in the driver process, so
`openGameServerWan` resolved `{configured:false}` and opened no WAN port. Neither
touches the code under test.

`LEVEL=RoundTrip` was set on purpose: a capitalised, non-default world directory
is the exact shape of GTNH's `World/`, reproduced on something disposable.

The driver calls the SAME functions the routes call — `runCapture` from
`timeline/route-support.ts`, `restorePoint` with `resolveRestoreTarget`,
`gracefulStopServer`, `gamePodCount` — assembled the way
`app/api/game-hub/servers/[name]/timeline/[point]/restore/route.ts` assembles
them. Two substitutions, both recorded: the timeline root was a local directory
(`GAMEHUB_TIMELINE_DIR`, the module's own env var) because this box cannot mount
the datastore PVC, and `startServer` recorded its call instead of performing it
so the restored volume could be hashed before a booting server rewrote
`session.lock` and `level.dat`. The call is asserted, so the "always restart"
contract is still checked, only deferred.

## D.2 Defect 1 — the flush probe and the proof did not speak the same path

**Every Minecraft Java capture was refused, on every server, whatever its world
was called.** Not GTNH's problem, not the world-name problem C.2 describes — a
second, independent cause underneath it.

`worldLayoutForEgg` names anchors as `./world/level.dat` (or
`./RoundTrip/level.dat`). `flushProbeScript` passes each path through
`assertSafeWorldPath`, which **strips the leading `./`**, and then printed that
stripped value as the row label. `decideFlushProof` → `pickAnchor` → `findFile`
looks the anchor up by exact string against `layout.anchors`. The two never
matched, so `pickAnchor` returned null and the capture died as:

```
anchor-missing — "No world data was found on this server (no level.dat under any
world directory), so there is nothing to capture. Start the server once to
generate the world."
```

Measured: the probe's own output in the same run said
`RoundTrip/level.dat  1  397  1787090104` — the file was there, 397 bytes, and
had just been rewritten by the flush. The proof could not see it.

Why no test caught it: every flush-proof test builds its `FlushProbe` in
TypeScript from `layout.anchors[0]`, so both sides of the comparison came from
one constant. The probe-parsing tests in `world-scripts.test.ts` even assert the
pod emits `./world/level.dat` — the intended contract was always the layout's
spelling; only the script disagreed.

**Fix:** the probe answers in the spelling it was ASKED in — the row label is the
caller's path, the `stat` still runs against the validated one.
`tests/unit/gamehub/world-probe-roundtrip.test.ts` runs the real script under a
real `/bin/sh` over a real directory and feeds the real output to the proof, the
only shape of test that can catch a shell/parser disagreement.

**Consequence for C.4:** its "How to make it work TODAY" is wrong. Deploying
`9ad28f1b` alone would NOT have made a GTNH capture succeed; it would have
refused with the same misleading sentence, and the world-name fix would have
looked like it had not worked.

## D.3 Defect 2 — no pod this addon builds could be admitted to `game-hub`

The restore refused with `no-restore-target`:

```
pods "tl-roundtrip-files" is forbidden: [minimum cpu usage per Container is 100m,
but request is 10m, minimum memory usage per Container is 256Mi, but request is
32Mi]
```

`game-hub` carries a LimitRange (`game-hub-limits`, min 100m / 256Mi per
container). Three builders sat under it:

| Pod | Asked | Effect |
|---|---|---|
| `game-hub-companion.ts` | 10m / 32Mi, mem limit 128Mi | the ONLY writer a restore has → capture worked, restore could never run; offline Files tab equally dead |
| `rehearsal/pod.ts` staging container | 50m / 128Mi | every Update Rehearsal refused at admission |
| `sleep/doorman.ts` | 10m / 32Mi, mem limit 96Mi | a hibernated server could not be woken |

All three were "deliberately tiny" by comment. Under a LimitRange, asking for
less than `min` is not cheaper — it is rejected, 403, no pod, no retry.

**Fix:** `lib/namespace-floor.ts` states the floor once, all three sit on it, and
`tests/unit/gamehub/namespace-limit-floor.test.ts` holds the invariant for every
pod this addon builds. Two existing tests pinned the rejected values
(`"requests the agreed small budget (10m CPU / 32Mi)"`, `"is small enough that
hibernating is still a win"`) — a test that pins a spec the API server refuses
guarantees the bug, so both were rewritten to the floor.

## D.4 Defect 3 (NOT FIXED HERE) — the live console cannot write a timeline point at all

Not fixed here, because it is a manifest change and this plan's worker may not
edit `InfraWeaver-infra` outside this document. Measured on the running console:

```
$ kubectl get deploy infraweaver-console -n infraweaver-console -o jsonpath='{...volumeMounts}'
/infra-routes, /connector-src, /etc/ssl/proxmox, /app/.next/cache, /git-cache, /tmp
$ kubectl exec deploy/infraweaver-console -- touch /datastore-probe-test
touch: /datastore-probe-test: Read-only file system      # readOnlyRootFilesystem: true
```

`timelineRoot()` resolves to `/datastore/game-worlds` **inside the console
container**, and the console mounts no such volume and has a read-only root, so
`writeJob` — the first write a capture makes, before the quiesce — fails with
EROFS. C.4's prerequisite 2 ("the `infraweaver-backup` datastore pod is running
with its 30Gi PVC — that is where timeline points live") describes the pod, not
the path the console writes through. The backup pod's `/datastore` holds
`sites/` and `.chunks` (the WordPress store) and **no `game-worlds` directory at
all**, which is consistent with what the two defects above imply: no world
timeline point has ever been written on this platform.

Before the World Timeline can work in production, the console Deployment needs
the datastore PVC mounted (or `GAMEHUB_TIMELINE_DIR` pointed at a writable
mount). That is a change in `InfraWeaver-infra` and is left for the operator.

## D.5 Defect 4 — the transport silently dropped the head of the archive

Found because the fixed restore hung: the world stream landed and swapped, then
the identity stream's `tar -xf -` sat in the companion pod for two minutes having
read **zero bytes**. Isolated against the live companion with a script that only
runs `wc -c`:

| source | pod received | verdict |
|---|---|---|
| 51,200 B, one chunk | **0** | call hung until its budget expired |
| 2,621,440 B, three chunks | **1,572,864** | first 1 MiB chunk gone — and the exec exited **0** |

`streamToPod` counted progress with `source.on("data", …)`. A `data` listener
switches a `Readable` into flowing mode immediately, while `k8s.Exec.exec()`
attaches its stdin handler only after the WebSocket handshake resolves. Whatever
the source emitted in that window went nowhere. A small stream lost everything
and the pod waited forever; a larger one lost its head and the pod unpacked what
was left.

The second row is the dangerous one and it is the exact failure mode this feature
exists to prevent: **a truncated archive streamed into a restore, reported as
success.** The world tar survived on the runs observed only because its
generator's first disk read happened to be slower than the handshake.

**Fix:** the bytes are counted inside a `Transform` the exec consumes
(`countedSource`), so a late consumer costs one high-water mark of buffering
instead of the head of the archive; backpressure still bounds console memory for
a 30 GB world. Source errors are forwarded to the transform (`pipe` does not) and
the transform carries a no-op `error` listener so a chunk-store failure before
the exec attaches cannot become an uncaught exception. Pinned by
`tests/unit/gamehub/pod-stream-late-consumer.test.ts`, which models the handshake
as a delayed consumer and asserts the FIRST chunk's identity, not just the total.

After the fix, live: 51,200 B delivered in 315 ms; 2,621,440 B delivered whole.

## D.6 The round trip — what was proven, and how

Order of operations, all on `tl-roundtrip`, world directory `RoundTrip/`:

1. **Seeded** — a world canary (`RoundTrip/IWTL-CANARY.txt`, plus a 1 MiB random
   blob under `RoundTrip/data/` and a 4 KiB one under `RoundTrip/players/`) and a
   full identity set: `ops.json` (CanaryOp, level 4), `whitelist.json`,
   `banned-players.json`, `banned-ips.json`, `usercache.json`,
   `usernamecache.json`, `server-icon.png`, and one file in each of
   `serverutilities/`, `visualprospecting/`, `journeymap/`, `blueprints/`.
   40 files, hashed with `sha256sum` from inside the pod.

2. **Captured** — `runCapture` (the route's own glue), point
   `2026-08-18T22-00-37Z`:

   ```
   worldName:   "RoundTrip"
   consistency: "quiesced"
   flushProof:  proven, ./RoundTrip/level.dat, 397 bytes,
                "The world was flushed to disk and level.dat rewritten before any byte was read."
   streams:     world.tar    3,389,440 B  3 chunks  csum 8437a041…
                identity.tar    51,200 B  1 chunk   csum 97c84877…
   ```

   This is the FIRST successful World Timeline capture on this platform.

3. **Verified** — `verifyPoint`: `ok: true`, 4 chunks re-hashed, 3,440,640 bytes
   checked, no issues. Both streams reassembled locally under their SIGNED
   checksums; the extracted tars hold exactly the 40 files, and their hashes are
   identical to the live volume's (only `level.dat`, `level.dat_old` and one
   `entities/r.0.0.mca` differ from the PRE-flush snapshot — i.e. exactly what
   the quiesce's `save-all flush` rewrote, which is what `proven` claims).

4. **Destroyed** — Deployment, Service, Secret, ConfigMap and **PVC** deleted,
   then recreated through `createServer`. The new server generated a different
   world (different `level.dat`, four new region files, `ops.json` = `[]`, none
   of the canaries, no modded directories).

5. **Restored** — `restorePoint`: mandatory pre-capture taken
   (`2026-08-18T22-45-46Z`), server stopped, zero pod objects awaited, writable
   companion created, both streams staged and swapped:

   ```
   status: "restored"   bytes: 3,389,440   warnings: none
   ```

6. **Compared** — the restored volume hashed through the companion:

   ```
   restored files: 40   point files: 40
   IDENTICAL — every file in the point came back byte for byte
   ```

7. **Booted** — the server started on the restored volume: `Preparing level
   "RoundTrip"`, `Done (1.299s)!`, and Minecraft itself re-read and re-wrote
   `ops.json` with `CanaryOp` at level 4. The identity stream is not just bytes
   on disk; it is a working operator entry.

The throwaway and every object it owned were then deleted; `game-hub` is back to
`requests.memory 12Gi / 4 PVCs`, and nothing named `tl-roundtrip` remains.

## D.7 What a fresh worker should do next

C.6's order still holds for tasks 4/6/5/7-10, with these amendments:

1. **The datastore mount (D.4) is now the top blocker.** Nothing about this
   feature works in production until the console can write its timeline root.
   That is an `InfraWeaver-infra` change.
2. **The live round trip is done and green** — C.6's item 1 is discharged, and
   the three defects it found are fixed with tests.
3. When Task 6 (`seed.ts`) lands, re-run the same shape of live proof for the
   CROSS-server direction: this run restored into the same server name, which is
   the one thing the update flow does differently.
4. Do not trust a green unit suite about anything that crosses a process
   boundary. All three defects here — a shell script vs its parser, a PodSpec vs
   an admission controller, a stream vs a WebSocket handshake — were invisible to
   3,108 passing tests and took one live run each to surface.

---

# Part E — D.4 answered: the timeline persists through the datastore pod

> Written 2026-08-19. Commits (local, not pushed): `74c2b45d` the hop moves to
> `@/lib`, `f32201c4` the timeline takes it, `4307d2be` config-sync ownership.

## E.1 The remedy D.4 proposed was wrong

Part D said the console Deployment needed the datastore PVC mounted. It does
not, and mounting it would have been wrong three ways — all three visible in
`kubernetes/catalog/infraweaver-console/base/`:

- `backup-deployment.yaml` runs the SAME console image with
  `IW_BACKUP_ROLE=datastore`, `replicas: 1`, `strategy: Recreate`, and its own
  comment calls it "THE datastore. The only writable path that survives a
  restart. DO NOT add an HPA, raise replicas, or switch to RWX."
- The volume is **RWO** and the console runs **1-8 replicas behind an HPA**, so
  at most one replica could ever mount it and the rest would fail to schedule.
- The console is the internet-facing pod. Direct write access to the backup
  store would hand any application-layer bug the backups as well — and a second
  writer to a content-addressed store with a mark-and-sweep collector is exactly
  how chunks get swept out from under a live point.

`deployment.yaml` is `readOnlyRootFilesystem: true` **by design**, with two
writable emptyDirs, and reaches the datastore over `BACKUP_SERVICE_URL` with
`BACKUP_SERVICE_TOKEN`. The timeline was not missing a mount. It was the only
persistent writer in this app that had not taken the hop.

## E.2 What changed

**The hop is now platform plumbing.** `addons/wordpress-manager/lib/backup/
service.ts` was never WordPress-specific — its nine exports are the role check,
the service URL, the constant-time token compare, the actor header and the
streaming proxy. Moved verbatim to `@/lib/datastore-hop`, old path re-exports.
180 tests across six backup suites pass unchanged. A second hop would have been
the same mistake as a second capture implementation.

**The timeline takes it.** Three pieces:

| Piece | What it does |
|---|---|
| `timeline/datastore.ts` | the fork — `proxy` on a console replica, token-authenticated `local` on the datastore pod, `refused` with no usable token — and the wall behind it, `assertTimelineDatastore()` |
| `timeline/route-gate.ts` | `withTimelineRoute`, stated once for six route files and thirteen handlers. Datastore fork FIRST (that pod has no session); console side still spends rate limit, session, scope and RBAC before forwarding |
| `proxy.ts` | a third service-token bypass, anchored to `servers/<name>/timeline/**` and nothing else under `servers/<name>/` |

The point segment in that pattern is bounded by **shape** (`[A-Za-z0-9-]{1,40}`),
not by the point-id grammar: two places that must agree about a timestamp format
is a trap, and the route validates the id twice already. `proxy-credential-census`
also probes reachability with a generic `sample` segment, and a pattern it cannot
match reports the route as unreachable.

The wall makes one pre-existing breakage legible rather than fixing it:
`rehearsal/promote` takes a mandatory pre-promote capture and is still
console-side, so it now fails with a sentence naming the pod that can do the work
instead of an `EROFS` errno. **It needs the same hop** — the natural next piece
of work in this area.

## E.3 The round trip, re-run through the datastore role

Everything below was driven by **HTTP calls to a datastore-role process** against
the live cluster, not by an in-process driver.

| Step | Evidence |
|---|---|
| no token | `403` |
| wrong token | `403` |
| valid token on the sibling `/power` | `403` — the bypass does not admit it |
| valid token on `/files` | `401` |
| **capture** `POST /timeline` | `HTTP 200 54.0s` — `captured: true`, point `2026-08-18T23-13-18Z`, `consistency: quiesced`, flush `proven`, `./RoundTrip/level.dat` 387 B |
| **list** `GET /timeline` | 200, the point is there |
| **verify** `POST /timeline/<id>/verify` | `ok: true`, 3,420,160 bytes re-hashed, 0 issues |
| destroy | Deployment, Service, Secret, ConfigMap **and PVC** deleted |
| recreate | through `createServer` — booted 1/1 with **no manual ownership repair**, the first time in the session |
| **restore** `POST /timeline/<id>/restore` | `HTTP 200 82.5s` — `restored: true`, 3,368,960 bytes, pre-capture `2026-08-18T23-17-40Z` |
| **compare** | `restored files: 46   point files: 46` → **IDENTICAL, byte for byte** |
| boot | `Preparing level "RoundTrip"`, `Done (1.392s)!`, and the server itself re-read `ops.json` with CanaryOp at level 4 |

Two cluster facts the design rests on, both measured:

- the datastore pod can create and write `/datastore/game-worlds` (25.5 G free on
  the 30 Gi PVC);
- its ServiceAccount is `infraweaver-console` — the SAME one the console uses —
  and it can `create pods/exec`, `get pods` and `get`/`patch deployments` in
  `game-hub`. Capture and restore need nothing it does not already have. **No
  infra RBAC change is required.**

What is still unproven until a deploy: the console→datastore leg of the hop in
the cluster (`proxyToDatastore`'s fetch). It is the same call every WordPress
backup already makes in production, and the datastore leg — middleware bypass,
gate, wall, engine — is proven above over real HTTP.

## E.4 The config-sync ownership bug, fixed

The init container runs as root and left `server.properties` `root:root` 0644, so
`itzg/minecraft-server` — **this addon's own default Minecraft egg** — could not
rewrite it on boot and crash-looped before generating a world:

```
java.nio.file.AccessDeniedException: /data/server.properties
[init] [ERROR] Failed to update server.properties
```

Every throwaway in this session had to be repaired by hand with a one-off root
pod. It would have failed the update feature on its happy path, whose first step
is "create the new server and prove it boots". `install-wrapper.ts` already ends
its success branch with the same `chown -R 1000:1000`; the second writer to the
same volume now does too, after the templater and without masking its exit
status. Verified live: the next server created booted unaided.

## E.5 Next

1. **Task 4** (`upgrade/types.ts` + `store.ts`) — the run vocabulary. Not started.
2. `rehearsal/promote`'s pre-promote capture needs the same hop (E.2).
3. Then Task 6 (`seed.ts`), then Task 5 (`run.ts`), then 7-10 — with a live
   cross-server proof when Task 6 lands, since this run restored into the same
   server name, which is the one thing the update flow does differently.

---

# Part F — Task 4 and Task 6 are built; five things the plan got wrong about the code

> Written 2026-08-19. Commits in `/home/runner/InfraWeaver-platform` (local only,
> not pushed): `b4f65e84` the run state, `8e7aa287` the cross-server seed.
> Nothing was deployed and the live cluster was read only.

## F.1 What shipped

| Plan task | State | Commit |
|---|---|---|
| Task 4 — `upgrade/types.ts` + `store.ts` (+ `config.ts`) | **DONE** | `b4f65e84` |
| Task 6 — `upgrade/seed.ts`, the cross-server restore | **DONE** | `8e7aa287` |
| Task 5 (`run.ts`), 7, 8, 9, 10 | **NOT STARTED** | — |

59 new tests across three suites, each written red first. 134 gamehub suites /
2,987 tests green; `tsc --noEmit` exit 0; `eslint` exit 0.

Three deliberate mutations were run to prove the load-bearing assertions are not
decorative — each was reverted and the tree re-verified clean:

| Mutation | Tests that failed |
|---|---|
| `capturing` exits to BOTH `stopping-source` and `provisioning` regardless of mode | 4 |
| `restoreDepsFor(sourceServer)` — the world-destroying bug | 1 (`the restore's verbs are built from the TARGET name and from no other`) |
| retry depth lowered to rehearsal's 3 | 1 (`a lost write race retries deeply enough to win`) |

## F.2 THE PLAN'S TEST PATHS DO NOT EXIST, AND A TEST WRITTEN THERE NEVER RUNS

Every task in Part B names a test path of the form
`src/addons/gamehub/lib/<area>/__tests__/<name>.test.ts`, and Task 1 even says to
"follow the sibling test layout used by `curated-packs.test.ts`". Measured:

```
$ find src -type d -name "__tests__" | wc -l      → 0
$ find src -name "*.test.ts*"        | wc -l      → 0
$ grep testMatch jest.config.js
  testMatch: ["**/tests/unit/**/*.test.{ts,tsx}"],
```

There are no `__tests__` directories in this repo and no test files under `src`
at all. Every unit test lives in `tests/unit/**`, and jest's `testMatch` picks up
**nothing else**. A file written where the plan says would not fail — it would
silently never be collected, so `npm test` would stay green while the task's
entire test suite sat unexecuted. That is the worst available failure mode for a
plan whose whole safety argument is "there is a test for this", and it applies to
tasks 1, 2, 3, 4, 5, 6 and 8 as written.

The three suites added here are at `tests/unit/gamehub/upgrade-run-state.test.ts`,
`upgrade-store.test.ts` and `upgrade-seed.test.ts`, beside the existing
`upgrade-capacity.test.ts` that Task 5's capacity slice already used.

## F.3 There are no `rehearsal/store.ts` tests to mirror — and mirroring it would copy a measured bug

Task 4 says to "mirror `rehearsal/store.ts` tests — same CAS/409-retry cases".
`writeRun` has **zero** test coverage; `rehearsal-abort.test.ts` imports only the
pure helpers (`nextRunData`, `runsFromData`, `activeRun`, `isAbandoned`,
`newRunId`, `runKey`). There is no CAS test in the codebase to mirror.

Worse, the loop it would have been mirrored from is the shape
`@/lib/configmap-store` exists to replace, in three ways, each documented in that
module or its test:

- **three attempts, no delay.** `tests/unit/configmap-store-conflict-retry.test.ts`
  records the measured cost: *"It retried a 409 exactly ONCE, with no delay: both
  losers of a simultaneous write re-read the same resourceVersion on the same
  tick and collided again … four real alerts lost to `Operation cannot be
  fulfilled on configmaps`."* The answer is `CONFIGMAP_WRITE_ATTEMPTS = 6` with
  `configMapConflictBackoffMs`.
- **it retries every error, not just conflicts.** A 403 is attempted three times
  and then reported as an exhausted-attempts message rather than as a permission
  problem.
- **`readConfigMap` swallows every read failure into `null`.** For rehearsal that
  is a display concern. For an update it is a correctness one: `null` reads as
  "no runs stored", which answers "nothing is in flight" to the concurrency
  guard, and a second update would start beside the first — on a namespace where
  two GTNH-class servers do not fit.

`upgrade/store.ts` therefore imports the retry policy from `@/lib/configmap-store`
rather than restating it, keeps the game-hub convention of an injected `coreApi`
and the per-server ConfigMap shape, and treats **only** a 404 as emptiness.

**Recommendation, not done here (out of scope):** `rehearsal/store.ts` has the
same three properties and drives a feature that can promote an image onto a live
server. It should adopt the same primitives.

## F.4 Four smaller corrections to the interfaces Part B specifies

1. **`CapacityMode` must be imported, not declared.** Task 4's interface block
   declares `export type CapacityMode = "fits-together" | "requires-source-stopped"`.
   `upgrade/capacity.ts` (shipped in `f42ae312`) already exports exactly that
   union. Two declarations of one union in one directory is the trap this
   codebase keeps paying for. `types.ts` re-exports the one from `capacity.ts`.

2. **`nextAllowedPhases("planned")` is not `["capturing","aborted"]`.** The plan's
   example omits `failed`, and Task 8 in the same plan requires the sweep to
   *"fail it with `inconclusive: console-restarted`"*. A phase the sweep cannot
   fail is a phase where an abandoned run stays "active" forever and refuses
   every future update for that server. `failed` is reachable from every
   non-terminal phase.

3. **`seeding` is the one phase with no `aborted` exit.** A.9 says an Abort button
   is present "wherever abort is safe"; the plan never says where that is not.
   It is not safe mid-seed: bytes are landing in the new server's volume, and
   stopping halfway reports "aborted", which reads as "nothing happened".
   `isAbortablePhase` states it once for the UI and the state machine.

4. **`seedNewServer` cannot return `Promise<void>`.** C.6 established that
   `RestoreOutcome.restored` carries `warnings` and that *"the run's verdict
   assembly must read them, or a server whose `ops.json` did not land will be
   reported as a clean pass"*. A `void` return discards them along with the byte
   count and the pre-capture id. It returns a `SeedOutcome`, and `warnings` is
   always present and empty rather than optional — a caller that had to check for
   the field would eventually forget to.

## F.5 The exact mechanism of the never-write-the-source hazard (read this before Task 5)

The plan describes the invariant. This is the mechanism, and it is sharper than
the plan implies.

`restorePoint(ref, deps)` names the point by `ref.server` and takes **every
server-scoped verb as an injected closure**: `stopServer`, `resolveTarget`,
`startServer`, `preCapture`, `gamePodCount` and `egg`. Nothing in `restore.ts`
compares `ref.server` with the server those closures act on, and it should not —
for the timeline's own restore route they are the same by construction (the route
builds all of them from one `name`).

For an update they are deliberately different. A `seedNewServer` that built its
verbs from the source name would: stop the OLD server, wait for its pods to go,
bring a writable companion up on the OLD volume, and unpack the source's own
capture over the world it was taken from — with **every signature check
passing**, because the point really is that server's. There is no checksum, no
signature and no sentinel anywhere in the restore path that would notice.

So `seed.ts` takes `restoreDepsFor: (server: string) => Promise<RestoreDeps>` as
a **factory** rather than a ready-made deps object, specifically so that the name
each verb was built from is an observable fact a test can assert. The test
asserts the complete call log: `readPoint` called once with `{server: SOURCE}`,
`restoreDepsFor` called once with `TARGET`, and the deps object handed to the
restore carrying the target's tag. Task 5's `run.ts` must supply that factory and
must not build a `RestoreDeps` itself.

Two gates were added that the plan does not list, both because the target is a
NEW server rather than the same one:

- **`point-belongs-elsewhere`** — `seed.ts` compares `manifest.server` with the
  caller's `sourceServer`. `restore.ts` never does.
- **`identity-stream-missing`** — into the SAME server a world-only point is a
  complete restore, because the ops, whitelist and `server.properties` already on
  that volume are the right ones. Into a NEW server nothing is already there, so
  a world-only point yields no operators, no whitelist, no bans, and a
  `server.properties` whose `level-name` may not name the directory just
  unpacked — which boots a brand-new empty world beside the restored one and
  reports success. A.7's "copying half-right silently is worse than copying
  nothing loudly", made enforceable.

## F.6 Two ordering facts Task 5 must respect

1. **`seeding` cannot come before `fresh-boot-proof`.** `restorePoint`'s
   pre-restore capture is mandatory and *its failure aborts*, and `runCapture`
   refuses with `no-pod` when the server is scaled to zero with no pod. The
   target only has a pod once `fresh-boot-proof` has booted it. A run that
   reordered these — or that provisioned and seeded without booting first —
   would abort at the pre-capture with a message about the SOURCE's world that
   has nothing to do with what went wrong.

2. **Q5 is answered in the cross-server direction, by accident of ordering.**
   `restorePoint` restores the world first and the identity stream second, and
   the identity set carries `server.properties`. So the target's `level-name`
   ends up naming the directory that was just unpacked, because both came from
   the same point. This is *why* `identity-stream-missing` is a refusal and not a
   warning: without that stream the two can disagree and nothing notices.

## F.7 Still open

1. **`rehearsal/promote`'s pre-promote capture still needs the datastore hop**
   (E.2). It did not block this work and was left untouched.
2. **The console→datastore leg is still unproven in-cluster** (E.3) and the
   `game-hub` datastore mount question is closed but undeployed.
3. **The cross-server seed has no live proof.** `seed.ts` has 11 unit tests and
   zero cluster runs, and D.7's rule stands: *do not trust a green unit suite
   about anything that crosses a process boundary.* The live proof for this one
   is a second throwaway server — capture from A, seed into B, diff B against
   A's point, and check A's volume is byte-identical before and after.
4. Next in code: **Task 5 (`run.ts`)**, whose deps surface is now fully
   determined by `advancePhase` / `phaseIsAlreadyDone` / `seedNewServer`; then
   7, 8, 9.
