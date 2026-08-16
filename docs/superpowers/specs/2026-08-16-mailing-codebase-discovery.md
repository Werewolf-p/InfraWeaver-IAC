# Mailing addon — codebase discovery

**Date:** 2026-08-16 · **Status:** discovery only, no implementation · **Audience:** whoever designs the `mailing` addon

Every claim below carries a `file:line`. Paths are relative to
`/home/runner/InfraWeaver-platform/` unless absolute. The console tree is
`apps/infraweaver-console/`; the WordPress plugin is
`apps/infraweaver-wp-connector/`.

Read this once, then build. The five sections are: **the addon skeleton**, **the
gates**, **flags and RBAC**, **the WordPress mail surface that already exists**,
and **the signed site channel**. It ends with what to reuse, what to build, and
the open questions.

---

## 0. The one-paragraph summary

An addon is a directory under `apps/infraweaver-console/src/addons/<id>/` whose
only registration point is `addon.manifest.ts`. A build script
(`scripts/build-addon-registry.mjs`) parses that manifest, refuses the build on a
sandbox violation, and emits six generated modules plus two generated route trees
— so pages, nav rows, RBAC gates, permission registrations and API mounts all
derive from the one file and cannot drift. WordPress mail is **already deep**:
the connector ships a 16-provider mail-method registry with OAuth, a
deliverability doctor that resolves SPF/DKIM/DMARC, and a full newsletter suite
with a paced never-send-twice queue — but the console only speaks five of the
connector's seven `email.*` signed methods and has **no** surface for the
provider registry, the doctor, or the newsletter at all.

---

## 1. The addon skeleton

### 1.1 Where an addon lives

`apps/infraweaver-console/src/addons/<folder>/`. Three exist today:

| id | folder | manifest | shape |
|---|---|---|---|
| `wordpress-manager` | `wordpress-manager/` | `src/addons/wordpress-manager/addon.manifest.ts:1-132` | the worked example: 15 pages, 30 API handler modules, ~90 lib modules |
| `game-hub` | `gamehub/` | `src/addons/gamehub/addon.manifest.ts:1-114` | 17 pages, no `api[]`, one deliberately public page |
| `wiki` | `wiki/` | `src/addons/wiki/addon.manifest.ts:1-159` | the *small contrast*: 3 pages (2 of them parked), 4 `api[]` entries, `permissions: []` |

The folder name and the manifest `id` are independent — `gamehub/` declares
`id: "game-hub"` (`src/addons/gamehub/addon.manifest.ts:4`). The generator
tracks the folder as `_folderName` for import specifiers
(`scripts/build-addon-registry.mjs:123`) and the id for every key.

### 1.2 `addon.manifest.ts`, field by field

The schema is `src/lib/addon-sdk/types.ts:189-234` (zod). What each field does
and who consumes it:

| Field | Schema | Consumed by | Effect |
|---|---|---|---|
| `id` | `types.ts:191` (kebab-case regex) | everything | default permission namespace, default route prefix `/<id>/`, **always** the API prefix `/api/<id>/` |
| `name`, `description`, `icon`, `category`, `author` | `types.ts:192-203` | `/addons` marketplace, consent screen, `manifestToAddon` (`types.ts:277-297`) | display only. `category` is a closed enum of 5 (`types.ts:201`) |
| `apiVersion` | `types.ts:203` | `src/lib/addon-registry/compat.ts` | SDK major; a skew fails install/verify loudly. Current host major is `ADDON_SDK_API_VERSION = 1` (`types.ts:16`) |
| `defaultEnabled` | `types.ts:204` | `src/lib/addons-server.ts` via `isAddonEnabled` | whether an estate that never touched the addon ConfigMap sees it. `wordpress-manager` is `false` (`addon.manifest.ts:12`); `wiki` is `true` (`wiki/addon.manifest.ts:46`) |
| `requiresSetup` / `setupPath` | `types.ts:205-206` | **not** enforced by the host — see `addon-page-host.tsx:42-48`: the host cannot know whether an addon is set up, so it never redirects. `setupPath` is just a route the addon links to |
| `pages[]` | `addonPageSchema` `types.ts:45-79` | the generator: route shims, `ADDON_PAGE_LOADERS`, `ADDON_NAV_REQUIREMENTS`, `ADDON_NAV_ACCESS` | **the** declaration; see 1.3 |
| `navItems[]` | `addonNavItemSchema` `types.ts:81-95` | `mergeAddonNavItems` (`src/lib/nav-config.ts:166-210`), merged into `NAV_GROUPS` at `nav-config.ts:236` | one sidebar row. `group: "addons"` files it under the Addons rail group. `order` (default 100) then label decides sort (`nav-config.ts:192, 202-204`) |
| `redirects[]` | `types.ts:108-111` | ranked in the SAME specificity pass as pages (`addon-page-host.tsx:79-89`) | retired paths without a route stub. `to` may interpolate `[param]` captured by `from`, percent-encoded by the host |
| `podTabs[]` | `types.ts:132-140` | `ADDON_POD_TAB_LOADERS` (`build-addon-registry.mjs:829-833`) | injects a tab into the core pod detail page, gated on `matchLabels` + `permission`. WordPress Manager uses one (`addon.manifest.ts:25-27`) |
| `api[]` | `addonApiSchema` `types.ts:142-167` | `ADDON_API_HANDLERS` + the generated API shim | see 1.5 |
| `permissions[]` | `types.ts:169-172` | `src/generated/addon-permissions.ts` → folded into `ALL_PERMISSIONS` (`src/lib/rbac.ts:6-8`, `89`, `95`) | see §3 |
| `roles[]` | `addonRoleSchema` `types.ts:119-124` | `src/generated/addon-roles.ts`, folded into `resolveRoleDefinition` | ships assignable roles. Sandboxed three ways: `<addonId>-` prefix, subset of the addon's own permissions, no built-in collision (`sandbox.ts:472-500`) |
| `scopePrefix` | `types.ts:218` | `addonRoutePrefix` — the route prefix AND the RBAC scope root | `/wordpress/` for `wordpress-manager` (`addon.manifest.ts:124`), which is why the addon owns `/wordpress` rather than `/wordpress-manager` |
| `permissionPrefix` | `types.ts:226` | `allowedPermissionNamespaces` (`sandbox.ts:188-198`) | only when neither `id` nor the `scopePrefix` token is the namespace you want. It never *widens* |
| `k8s` | `types.ts:174-179` | uninstall sweep, `checkK8s` (`sandbox.ts:594`) | `namespace` + `ownsLabels`; a protected namespace or a reserved label prefix fails the build |
| `hooks`, `dependencies`, `homepage`, `license` | `types.ts:181-233` | display / install plan | not load-bearing for a first surface |

### 1.3 `pages[]` — the single source of route **and** gate

Each entry is `{ path, component, title, group, requiredPermissions? | public? }`
(`types.ts:45-79`).

- `path` — absolute URL, must sit under the addon's route prefix
  (`sandbox.ts:340-368`). Grammar is literal segments plus `[param]` segments
  only — **no catch-all, no optional segments** (`src/lib/addon-registry/page-match.ts:5-15`).
  Matching is exact-segment-count, then left-to-right literal-beats-param, so
  `/wordpress/rooms` beats `/wordpress/[site]` (`page-match.ts:11-15`; the
  consequence is stated in `gamehub/addon.manifest.ts:36-49`: a resource whose
  name equals a literal segment is unreachable at its own URL).
- `component` — path relative to the addon root, e.g. `pages/site-detail`. The
  generator emits `() => import("@/addons/<folder>/<component>")` keyed
  `"<addonId>::<path>"` (`build-addon-registry.mjs:823-827`). A specifier that
  does not resolve fails the build — which is why the wiki keeps a real module
  for a page it never mounts (`wiki/addon.manifest.ts:29-33`).
- `title` / `group` — page registry metadata; `group` is the page registry's
  axis, **not** the nav rail's (`wiki/addon.manifest.ts:60-62`).
- `requiredPermissions` — becomes `{ any: [...], scopePrefix }` in
  `ADDON_NAV_REQUIREMENTS` and `{ gate: [...], scopePrefix }` in
  `ADDON_NAV_ACCESS` (`build-addon-registry.mjs:965-981`). Requirements are
  **ANY-of** (see `/wordpress/rooms/[room]` accepting either
  `wordpress:client` or `wordpress:read`, `addon.manifest.ts:101`).
- `public: true` — `z.literal(true)`, deliberately not `z.boolean()`
  (`types.ts:72`), and mutually exclusive with `requiredPermissions`
  (`types.ts:74-79`, re-checked in the build gate at
  `build-addon-registry.mjs:199-208` because the generator reads the manifest
  through a regex mirror, not through zod).

**A page with neither answer fails the build**
(`build-addon-registry.mjs:181-192`). `canAccessNavHref` fails *closed*
(`src/lib/navigation-rbac.ts:403-409`), so an undeclared page would be
unreachable even by its author.

Component props are `AddonPageProps` — `{ params, searchParams }`, both plain
decoded string records, **not** Next's `PageProps` (`types.ts:243-260`). The
host hands the component the params its own declared path captured.

### 1.4 `pages/` vs `components/` vs `lib/` vs `api/`

The convention is documented in `src/addons/wordpress-manager/README.md:9-27`
and holds in practice:

- **`pages/`** — thin `"use client"` shells, one per manifest page. Almost all
  are under 40 lines (`wc -l src/addons/wordpress-manager/pages/*.tsx`: 9-62
  lines, 458 total for 15 pages). They do routing and chrome only.
- **`components/`** — the views, grouped by feature subdirectory
  (`components/manage/email/`, `components/patch/`, `components/rooms/`, …).
  Every rendering decision lives here.
- **`lib/`** — server + isomorphic logic, also grouped by feature
  (`lib/manage/`, `lib/rpc/`, `lib/backup/`, `lib/ledger/`, …). Server-only
  modules declare `import "server-only"` (e.g.
  `lib/iwsl-managed-ops.ts:1`, `lib/iwsl-link-store.ts:1`, `lib/k8s-exec.ts` via
  its imports).
- **`api/`** — request handlers: auth + RBAC + validation + rate limit + audit,
  then delegate to `lib/`. Example: `api/email-handlers.ts:1-150`.
- **`k8s/`** — the addon's own Kubernetes manifests (10 CronJobs/NetworkPolicies
  for `wordpress-manager`).

### 1.5 API routes: two mechanisms, and which one WordPress uses

**Mechanism A — the generated addon API host** (what a third-party addon gets).
The manifest declares `api: [{ path, handler, methods, permission }]`. The
generator resolves each to `/api/<id>/<path>` and emits
`ADDON_API_HANDLERS` keyed by the resolved route
(`build-addon-registry.mjs:843-848`), plus one deliberately dumb route file per
addon (`apiShimSource`, `build-addon-registry.mjs:1335-1348`). All enforcement
lives in `src/lib/addon-registry/api-host.ts:118-164`, in this order:

1. path resolves to a declared handler → else 404 (`api-host.ts:124-125`);
2. addon **enabled** → else 404, checked before the permission gate so a
   disabled addon cannot be probed (`api-host.ts:127-129`);
3. method declared → else 405 **with `Allow`** (`api-host.ts:131-140`);
4. `withRoute(permission, handler, { scope: () => <addon root> })`
   (`api-host.ts:153-162`).

`permission` is **required and nullable** (`types.ts:166`). `null` means
authenticated-only; *omitting* it is refused with a 500
(`api-host.ts:142-151`, `addonApiPermission` at `api-host.ts:177-185`, and
`sandbox.ts:514-545`). Scope enforcement is at the addon **root**, not
per-resource — stated honestly at `api-host.ts:18-23`.

The handler module exports one function **per HTTP method name**, with the
four-arg signature `(req, session, access, ctx)` (`api-host.ts:69-74`) —
deliberately not Next's route signature, so an addon cannot skip the gate by
exporting a bare Next handler.

`addon-api-handlers.ts` is a **separate generated module** from
`addon-registry.ts` on purpose: the registry is imported by a client component,
and dragging server-only handlers into the client graph is a real bug that a
`import "server-only"` once caught (`build-addon-registry.mjs:881-902`).

**Mechanism B — the parking rule** (what WordPress Manager actually uses).
If a concrete `src/app/api/<id>/` directory exists, the generator stands down
with a loud warning and emits **no** API shim (`build-addon-registry.mjs:1180-1191`).
The same rule applies to pages: a concrete `src/app/(dashboard)/<prefix>/`
directory suppresses the page shim (`build-addon-registry.mjs:1162-1177`).
Deleting the concrete directory *is* the migration switch.

WordPress Manager parks its whole API family. Every route under
`src/app/api/wordpress/**` is a thin delegator:

```ts
// src/app/api/wordpress/sites/route.ts:1-13
// Thin delegator — all logic lives in the wordpress-manager addon.
import { listSitesHandler, createSiteHandler } from "@/addons/wordpress-manager/api/handlers";
export const dynamic = "force-dynamic";
export function GET() { return listSitesHandler(); }
export function POST(req: NextRequest) { return createSiteHandler(req); }
```

Per-site routes take the site from Next params and pass it in:
`src/app/api/wordpress/sites/[site]/email/route.ts:1-12`.

The wiki shows the hybrid: a hand-written host under the parking rule, because a
CronJob-driven route (`atlas-sweep`) needed the concrete directory
(`src/app/api/wiki/[...slug]/route.ts:1-27`).

### 1.6 The generated artefacts

`scripts/build-addon-registry.mjs` runs from `prebuild` **and** `predev`
(`package.json` scripts). It writes:

| Output | Line | Contents |
|---|---|---|
| `src/generated/addon-registry.ts` | `850-879` | `ADDON_MANIFESTS`, `ADDON_MANIFEST_LOADERS`, `ADDON_PAGE_LOADERS`, `ADDON_POD_TAB_LOADERS` |
| `src/generated/addon-api-handlers.ts` | `903-916` | server-only handler loaders keyed by resolved route |
| `src/generated/addon-permissions.ts` | `919-947` | `ADDON_PERMISSIONS`, `ADDON_PERMISSION_IDS` — the bridge into `src/lib/rbac.ts` |
| `src/generated/addon-nav.ts` | `949-1023` | `ADDON_NAV_REQUIREMENTS`, `ADDON_NAV_ACCESS`, `ADDON_SCOPES`, `ADDON_ROUTE_PREFIXES` |
| `src/generated/addon-roles.ts` | `1025-1052` | `ADDON_ROLES` |
| `src/app/(dashboard)/(addon-pages)/<prefix>/[[...slug]]/{page,loading}.tsx` | `1194-1206`, `1243-1332` | the page shim + one shared route-level skeleton |
| `src/app/api/(addon-api)/<id>/[...slug]/route.ts` | `1208-1215`, `1335-1348` | the API shim |

Both route trees are **owned wholesale** by the generator — deleted and rewritten
every run, built in a staging dir and swapped (`swapTree`,
`build-addon-registry.mjs:1218-1241`) — and both are gitignored
(`.gitignore:43-51`). That is what makes "uninstall = delete the directory"
actually remove routes.

### 1.7 `AddonPageHost` — the runtime mount

`src/components/addons/addon-page-host.tsx:64-154`. Gate order, with the reason
for each, is spelled out at `addon-page-host.tsx:32-55`:

1. unknown addon id → `notFound()` (`:99`);
2. slug does not match a declared page or redirect → `notFound()` (`:100`);
3. declared redirect → `router.replace` (`:91-94, 101`);
4. addon disabled → the shared `AddonDisabledPanel`, never a silent 404 (`:113`);
5. RBAC → access-denied panel, gated on the page's **declared path** so the page
   gate and the sidebar gate are literally the same entry (`:115-131`).

Gate 5 is explicitly **UX, not authorization** (`:50-55`) — the server-side
`withRoute` on every route the page calls is the real boundary.

Lazy components are cached module-level by `"<addonId>::<path>"`
(`LAZY_PAGES`, `:186-194`) so `/wordpress/a` → `/wordpress/b` re-renders instead
of remounting and dropping state.

### 1.8 The page shell convention

Back-link → title → tabs → client view. Canonical example
(`src/addons/wordpress-manager/pages/site-patches.tsx:15-32`):

```tsx
export default function WordpressSitePatchesPage({ params }: AddonPageProps) {
  const site = params.site ?? "";
  return (
    <div className="w-full px-4 py-8 sm:px-6 lg:px-8">
      <Link href="/wordpress" …><ArrowLeft … /> All sites</Link>
      <header className="mt-4 …"><h1 …>{site}</h1></header>
      <SiteTabs site={site} active="patches" />
      <PatchGateView site={site} />
    </div>
  );
}
```

`SiteTabs` (`src/addons/wordpress-manager/components/site-tabs.tsx:19-49`) is a
hand-maintained array of 10 tabs, each `{ id, label, path(site) }`, rendered via
the core `TabScroller` with `bleed` (the `-mx-4` reasoning is at `site-tabs.tsx:52-70`).
Two pages skip the chrome entirely and are one-liners
(`pages/site-connector.tsx:1-9`, `pages/site-manage.tsx`), because their view
component owns the whole page.

The design canon for page anatomy is
`apps/infraweaver-console/docs/design/INFRAWEAVER-STYLE.md` — §S5 page anatomy
(line 693), §S8 "unknown is not empty" (line 1043, mandatory on anything that
renders fetched data), §S12 destructive actions (1372), §S19 the new-feature
checklist (1821).

---

## 2. The gates a new surface must satisfy

These reject new code. Some loudly at build time, some in a jest suite. **Run
tests individually on this hardware** (`INFRAWEAVER-STYLE.md:1707`).

### 2.1 The route-scope census — `tests/unit/route-scope-manifest.test.ts`

**What it does.** Walks every `src/app/api/**/route.ts` with the TypeScript AST,
resolves aliases/destructuring/cross-module re-exports, and classifies each
exported handler into 11 kinds (`route-scope-manifest.test.ts:283-303`). Only
`scoped` (`withRoute(perm, h, { scope: resolver })`) and `root`
(`{ rootScope: true }`) count as **triaged** (`:305`).

**The ratchet.** `MAX_UNTRIAGED_ROUTE_HANDLERS = 479`
(`route-scope-manifest.test.ts:218`), asserted at `:809-822`.

**Measured today (verified by running the suite):**

```
family      total  triaged  untriaged  scoped root undeclared auth-only with-auth wrapper raw
wordpress     177       69        108      53   16          0         0         0       0 108
game-hub      148       71         77      64    7          0         0        15      43  19
wiki            3        0          3       0    0          0         0         0       2   1
TOTAL         844      365        479     165  200         19        21       163      57 219
```

**⚠️ The number that will bite: slack is exactly zero.** 479 measured against a
479 baseline. The suite *also* asserts the baseline is not slack —
`MAX_UNTRIAGED - untriaged <= 25` (`:829-830`) — so it cannot be pre-raised. Any
**one** new un-triaged handler turns this red immediately.

Three specific traps for a mailing addon:

- A thin delegator in the WordPress style (`export async function POST(req, ctx)`
  calling into the addon) classifies as **`raw`** → un-triaged. All 108
  un-triaged wordpress handlers are exactly this.
- **The generated addon-API shim is also un-triaged.** `export const GET =
  addonApiRoute("wiki")` classifies as `wrapper` — that is 2 of the wiki's 3
  un-triaged handlers (`src/app/api/wiki/[...slug]/route.ts:26-27`).
  So *even the "correct" manifest-declared API path* costs ratchet budget.
- Adding `mailing` as a **new family** does not put it in `FULLY_TRIAGED_FAMILIES`
  (`:225-246`), so it escapes the hard gate — but it still counts toward the
  total, which has no headroom.

**What to do.** Route mailing handlers through `withRoute(permission, handler,
{ scope: <resolver> })` (resolvers live in `@/lib/tenancy/resolve-scope`, cited
at `:816`) or `{ rootScope: true }` where genuinely fleet-wide. Do **not** raise
the baseline — the file forbids it in four separate places and itemises every
past raise (`:114-215`). A resolver-scoped handler is *free*; a raw delegator
costs one and there is nothing left to spend.

Note the file's own honesty rule: wrapping a handler in a function whose only
purpose is to hold `{ rootScope: true }` is "the flattering fiction this file's
header warns about" (`:180-184`, `:209-212`). Don't.

### 2.2 `scripts/check-route-exports.mjs`

Runs in `prebuild` with `--quiet` (`package.json`). It checks the three
`next build` rules that `tsc` and jest cannot see
(`check-route-exports.mjs:6-33`):

1. a route module may export **only** the HTTP verbs and the route-segment
   config fields — any other runtime export is a build error. Type-only exports
   are erased and therefore allowed; `export enum` is **not** type-only and is
   flagged (`:49-53`);
2. an exported handler whose **second parameter is optional** (`ctx?: X`) fails
   Next's generated validator (`:18-21`);
3. a route-segment config field must be a literal-initialised `export const` in
   the module's own source — `export { POST, dynamic } from "./impl"` fails the
   build (`:23-31`).

Exit 0 clean, 1 violations, 2 could-not-run (`:69`). This is why
`feature-defaults.ts` re-states three route constants as string literals rather
than importing them (`src/lib/feature-defaults.ts:36-41`) — importing a const
from a route module is how a build-time route-export failure gets introduced by a
file that has nothing to do with routing.

### 2.3 `scripts/check-route-size.mjs` + `scripts/route-size-budget.json`

A **per-route JavaScript ceiling**, seeded from a measured build + 2 %
(`check-route-size.mjs:66`), ratchet-only-down
(`route-size-budget.json._contract`). It measures three numbers per route —
`own` (the entry chunk), `shared` (layout chain + `rootMainFiles`), `total` —
and **gates on the components, not the sum**, so a page shrink cannot pay for a
shell that grew (`check-route-size.mjs:35-38`).

`--seed` refuses to raise a committed number without `--allow-raise`
(`:228-296`). It reads `.next/static/chunks/app` (not
`app-build-manifest.json`, which does not exist at Next 16.2.12 — `:19-27`).

**For a mailing addon this is nearly free**, and that is worth knowing: an addon
page shim is 189 bytes because the real components arrive as lazy chunks the
gate does not measure. Both existing shims are budgeted at 189
(`scripts/route-size-budget.json` → `"/(dashboard)/(addon-pages)/game-hub/[[...slug]]": 189`,
`".../wordpress/[[...slug]]": 189`). A brand-new route is reported as
`unbudgeted` and printed, but **does not fail** — exit code depends only on
`over` (`check-route-size.mjs:345-375`). What *would* bite: a static import that
grows the `/(dashboard)` layout (budget 101781) or `rootMainFiles` (457665).

The gate needs a real `.next/` to run, so it cannot be run in this session
without a build.

### 2.4 The design ratchets

All six scan `src/**` including `src/addons/**` (each declares
`const SRC = join(__dirname, "..", "..", "src")`), so **an addon is inside every
one of them**. Comment-only mentions of a banned pattern are excluded by every
scanner.

| Ratchet | File | Baseline | What it enforces | How to pass |
|---|---|---|---|---|
| `status-dot` | `tests/unit/status-dot-ratchet.test.ts:112` | `MAX_BARE_STATUS_DOTS = 46` (plus `MAX_STRICT_DOT_SITES = 20`, `MAX_STRICT_DOT_FILES = 15` at `:156-157`, `MAX_UNATTACHED_DOT_CLASS_LISTS = 1` at `:165`) | an element with `rounded-full` + matched `h-N w-N` for N ∈ {1,1.5,2,2.5,3} is a *dot*; it is **bare** if its open tag declares no `aria-label`/`aria-labelledby`/`role`/`title`/`aria-hidden`/`sr-only` (`:189-197`) | add `aria-hidden` when adjacent text carries the meaning, or use the shared `StatusDot` |
| `hex` | `tests/unit/hex-ratchet.test.ts:124,141` | `MAX_HEX_COLOUR_SITES = 2776`, `MAX_HEX_SIX_DIGIT_SITES = 2412` | raw hex colours in `.ts`/`.tsx`, counted per **site**. Shorthand `#111` counts too, so `#111111 → #111` is not an escape (`:41-48`) | use theme tokens. **Zero hex in new code** — §S19 checklist |
| `px-type` | `tests/unit/px-type-ratchet.test.ts:99,107` | `MAX_ARBITRARY_TYPE_SIZES = 1115`, `MAX_UNREADABLE_TYPE_SIZES = 18` (≤ 9px) | `text-[Npx]` arbitrary font sizes | use the density type scale (§S4) |
| `icon-button-name` | `tests/unit/icon-button-name-ratchet.test.ts:100` | `MAX_UNNAMED_ICON_BUTTONS = 30` | icon-only `<button>` with no accessible name. There is **also a per-file guard**: a file that held no offender at branch time may not acquire one (`:405-412`) | use `IconButton`, whose *type* requires `label` (`INFRAWEAVER-STYLE.md:1722`) |
| `z-index-adoption` | `tests/unit/z-index-adoption.test.ts:273` | `MAX_RAW_Z_BOTTOM_BARS = 5` | (a) **no arbitrary `z-[NNN]` anywhere in `.tsx` raw text, comments included**; (b) hand-rolled overlays must adopt `useDialogA11y` + the overlay/modal tokens; (c) a `fixed`/`sticky` bottom-anchored bar may not pick a raw `z-10\|20\|30\|40` rung (`:252-271`) — the mobile nav is `z-nav` (30) | token rungs only: `z-nav` for chrome, `z-overlay`+ above it. NB `wordpress-manager/.../panels-people.tsx` is one of the 5 offenders |
| `layout-animation` | `tests/unit/layout-animation-ratchet.test.ts:79` | `MAX_ANIMATED_LAYOUT_PROPS = 30` | JS-animated layout properties (`animate={{ height }}` etc.) that force layout instead of compositing | animate transform/opacity, or use the `components/motion/**` primitives |

Plus one more that is not a count but a hard rule:

| `confirm-standard` | `tests/unit/confirm-standard.test.ts` | **zero tolerance** | exactly one confirmation mechanism: hold the real button (`src/components/ui/hold-to-confirm.tsx`). Banned: `window.confirm`, `window.prompt`, and **hand-rolled typed gates** detected by three shapes — the instruction ("Type X to confirm", `:113`), the "Type the &lt;thing&gt; name" variant (`:124`, which was added *because* a `src/addons` file evaded a per-directory scan), and the state slot (`setTyped`/`setConfirm*`, `:129-132`) |

Two ratchets whose numbers a nav row moves:

- `tests/unit/nav-ia.test.ts:98` asserts `{ rows: 47, visible: 31 }` for the rail
  and `:107-111` asserts rail + topbar = **59**. `NAV_GROUPS` statically merges
  addon nav rows (`src/lib/nav-config.ts:236`), so **one `navItems` entry breaks
  both assertions** and the numbers must be moved with a written reason — the
  file's own precedent is the wiki row at `nav-ia.test.ts:75-83`.
- `MAX_CORE_NAV_ROWS = 57` in the build gate
  (`build-addon-registry.mjs:699`) counts only the two hand-written core
  declarations — "the two addon-contributed rows are deliberately NOT counted"
  (`:673-675`). Slack is 6 (`:701`).
- `MAX_DASHBOARD_ROUTES = 59` (`tests/unit/dashboard-route-sprawl.test.ts:122`)
  **excludes** `(addon-pages)` as build output (`:45`) and also excludes parked
  addon dirs (`:216-220`). An addon's pages therefore cost nothing here.

### 2.5 The build gate inside `build-addon-registry.mjs`

Beyond the manifest sandbox (§3.3), it will refuse the build for:

- a page with no `requiredPermissions` and no `public: true` and no vendored
  justification (`:181-192`);
- a page declaring both (`:199-208`);
- a stale `VENDORED_PUBLIC_ADDON_PAGES` entry naming a page its addon no longer
  has (`:215-226`);
- a nav row pointing at a retired or non-existent destination, or naming a hub
  tab that does not exist (`:630-666`);
- a composed permission set containing an escalation-tier permission
  (`:798-808`).

---

## 3. Feature flags and RBAC

### 3.1 `src/lib/feature-defaults.ts`

**Purity is load-bearing.** The module has **no imports** (`feature-defaults.ts:70-84`),
because ~15 gate readers import it and some are reachable from client
components. It restates each gate's accepted vocabulary as data instead of
calling the readers; `feature-defaults.test.ts` cross-checks the restatement.

**The precedence table** (`:42-51`, implemented once at `resolveSwitch`,
`:450-468`):

| Rung | Source | Wins over |
|---|---|---|
| 1 | an **explicit** env var value | everything, in **both** directions |
| 2 | a **runtime override** (stored outside the process, `@/lib/features/overrides`) | the master default |
| 3 | `PLATFORM_ENABLE_ALL` (`:86`) | off |
| 4 | off | — |

Rung 1 is decided on **acceptance of the raw value**, so an explicit `nonsense`
is an explicit OFF rather than a fall-through (`:457-460`).

**`GATES`** (`:334-440`) is the closed list of every gate the console has: 13
game-hub, 8 wordpress, 4 platform. Each `GateSpec` (`:296-322`) carries:

- `accepts` — one of three vocabularies: `PLATFORM_TRUTHY_WORDS`
  (`1|true|on|yes`, trimmed+lowercased, `:92`), `ON_TRUE_ONE_WORDS`
  (`on|true|1`, `:95`), or `LITERAL_TRUE_ONLY` (the literal `true`, **untrimmed
  and case-sensitive**, `:98`). ⚠️ On a literal gate, `=1` silently does nothing
  (`:302-305`);
- `dependsOn` — other switches this one ANDs with, folded into `effective`
  (`:307-313`); `GATES` must stay ordered so dependencies resolve in one pass
  (`:482-484`);
- `blockedBy` — external configuration (a secret, a digest-pinned image, a
  registry host) folded into `available`, **not** `effective`, because
  "switched on but unusable" is a state an operator must be able to see
  (`:314-321`, and `FeatureFlagState.available` at `:268-275`).

**`NEVER_DEFAULTED`** (`:122-130`) is the mechanism, not a policy note:
`platformDefaultFor` returns `false` for these names no matter what the master
says (`:156-159`). The seven are `DR_CHAOS_INJECTION_ENABLED`,
`SECRET_REMEDIATION_WRITE_ENABLED`, `FLEET_PROVISION_ENABLED`,
`WORDPRESS_PATCH_AUTO_REMEDIATION_ENABLED`, `WORDPRESS_AGENT_GATE_ACT_TIER`,
`WORDPRESS_CLIENT_ROOMS_ENABLED`, `AGENT_BROWSER_SESSION_ENABLED`. The stated
criterion: *takes unattended destructive action, writes credentials, or hands out
authority* (`:32-34`).

Note the deliberate asymmetry: the **runtime override tier does reach most
`NEVER_DEFAULTED` names** (`:62-68`, `:462-465`). That list bounds the *blanket*
switch, not a per-flag decision an operator took on purpose.

**Env pinning.** `isEnvPinned` (`:192-194`) is true for **any** explicit value in
either direction. `envPinReason` (`:205-215`) produces the exact sentence to
render next to a disabled toggle, because env vars in a running Deployment are
immutable and a toggle that silently does nothing is worse than no toggle.
`applyFeatureOverrides` (`:232-241`) applies an override only where the real
variable is unset **and** only for a name in `PLATFORM_FEATURE_FLAGS`
(`:443`) — without that second bound, a key named `NEXTAUTH_SECRET` in the
override ConfigMap would be merged into the environment handed to every reader
(`:226-229`).

**⚠️ `PLATFORM_ENABLE_ALL=1` IS LIVE IN PRODUCTION**
(`/home/runner/InfraWeaver-infra/kubernetes/catalog/infraweaver-console/base/deployment.yaml:138-139`).
So **any new mailing gate defaults ON the moment the image rolls**, unless it is
in `NEVER_DEFAULTED`. The manifest also sets the five remaining never-defaulted
gates explicitly (`deployment.yaml:243-250`) and `WORDPRESS_CLIENT_ROOMS_ENABLED=1`
(`:216-231`) — and one gate (`/infrastructure`) is deliberately read straight
from `process.env` and never defaulted, with a unit test pinning that the master
cannot arm it (`deployment.yaml:140-151`).

### 3.2 The permission model

**Core registry.** `ALL_PERMISSIONS` (`src/lib/rbac.ts:10-41`) is the runtime
list from which the `Permission` union is *derived* (`:43`). Addon permissions
are folded in at build time via `ADDON_PERMISSION_IDS` (`rbac.ts:6-8`, composed
at `:89` and `:95`) — which is why installing an addon is a commit that triggers
a build, not a runtime registration (`build-addon-registry.mjs:924-931`).

**The WordPress family** (`rbac.ts:32-39`):

- `wordpress:read` / `wordpress:write` / `wordpress:admin`;
- `wordpress:client` — the delegated Client Rooms tier, **deliberately not
  implied by `wordpress:read`**, because every existing `/api/wordpress/*` read
  route gates on `wordpress:read` and several of them exec into pods. It is
  accepted by the room read routes and by nothing else, "which makes that bound
  structural rather than an allow-list somebody has to remember to maintain"
  (`rbac.ts:33-39`). **This is the pattern to copy for a delegated mail tier.**

Built-in roles: `wordpress-viewer` / `-editor` / `-admin` / the client role
(`rbac.ts:559-598`).

**Per-instance scoping.** `src/addons/wordpress-manager/lib/wordpress-rbac.ts`:

- `wordpressScope(site)` → `/wordpress/sites/<site>` (`:30-32`);
- `WORDPRESS_ALL_SITES_SCOPES = { "/", "/wordpress", "/wordpress/sites" }` — a
  grant at any of these cascades to every site (`:13`);
- `hasWordpressPermission(groups, username, assignments, permission, site)`
  (`:37-47`) — platform admin (`*`) always passes, then the core engine
  evaluates at the site scope;
- `getScopedWordpressSites` (`:57-77`) enumerates a principal's per-site grants,
  skipping expired ones, subtracting explicit `Deny`, and — critically —
  **checking that the assignment's ROLE is WordPress-shaped**, because a
  Jellyfin role parked at `/wordpress/sites/x` was previously enumerating site x
  (`:68-73`);
- `hasAllWordpressAccess` (`:86-102`) for the blanket tier.

**The two-check idiom every handler uses** — namespace-wide OR per-site
(`api/email-handlers.ts:58-70`, `api/handlers.ts:64-70`):

```ts
const namespaceWide = hasWordpressPermission(ctx.groups, ctx.username, ctx.roleAssignments, permission, "");
const scoped        = hasWordpressPermission(ctx.groups, ctx.username, ctx.roleAssignments, permission, site);
if (!namespaceWide && !scoped) return fail("Forbidden", 403);
```

Fleet reads use the namespace-wide check only (`api/fleet-guard.ts:24-27`).

Note this idiom is **why** the WordPress family cannot simply be wrapped in
`withRoute`: `withRoute(permission, …)` evaluates at the ROOT scope, which is a
*stricter, different* gate than the addon was specified against
(`route-scope-manifest.test.ts:146-159`).

**The escalation tier.** `GROUP_DENIED_PERMISSIONS` (`rbac.ts:140-174`) — `*`,
`users:write`, `users:invite`, `rbac:admin`, `platform:update`, `cluster:admin`,
`cluster:drain`, `cluster:scale`, `security:write`, `audit:export`,
`compliance:export`, `alerts:admin`. An addon may **never** register one
(`sandbox.ts:293-297`, plus the composed-set check at
`build-addon-registry.mjs:800-808`). The `alerts:admin` entry is the closest
precedent to a mail addon: it is deny-listed precisely because it confers "every
webhook URL, SMTP password and SMS provider token the alert manager can deliver
through" (`rbac.ts:167-174`).

### 3.3 What a `mailing:*` family would have to do

**It is a clean namespace.** `mailing` is not in `ALL_PERMISSIONS`, so it is not
a `CORE_PERMISSION_NAMESPACE` (`sandbox.ts:228-233`), and `/mailing` is not in
`RESERVED_ROUTE_PREFIXES` — which is derived, not hand-listed
(`sandbox.ts:248-256`): the base list (`:84-99`) plus `/<namespace>` for every
core permission namespace except the addon-owned ones (`:105-110`).

Requirements, each enforced:

| Requirement | Enforced at |
|---|---|
| every permission id sits in an allowed namespace — the addon `id`, the `scopePrefix` token, or a declared `permissionPrefix` | `allowedPermissionNamespaces` `sandbox.ts:188-198`; `checkPermissions` `sandbox.ts:280-...` |
| no permission in the escalation tier | `sandbox.ts:293-297`, `build-addon-registry.mjs:800-808` |
| every page/nav/redirect/setupPath path under the addon's own route prefix | `checkRoutes` `sandbox.ts:340-368` |
| every `api[].path` resolves inside `/api/<id>/` — note **`id`, not `scopePrefix`** | `resolveAddonApiPath`, `checkApi` `sandbox.ts:514-529` |
| every `api[]` entry declares `permission` (`null` allowed, omission refused) | `sandbox.ts:539-545`, `api-host.ts:142-151` |
| shipped roles are `<addonId>-` prefixed, carry only the addon's own permissions, and shadow no built-in | `checkRoles` `sandbox.ts:472-500` |
| `k8s.namespace` is not protected; `ownsLabels` uses no reserved prefix/key and collides with no other addon | `checkK8s` `sandbox.ts:594-...`, `PROTECTED_NAMESPACES` `:30-48`, `RESERVED_LABEL_*` `:50-71` |

**Tiering the operations.** A mail addon can send as a domain and read
mailboxes. Mapping the codebase's own reasoning onto that:

| Tier | Operations | Why, in this codebase's terms |
|---|---|---|
| `mailing:read` | list mailboxes/domains, read delivery logs (redacted), read SPF/DKIM/DMARC verdicts, read queue/campaign state, read a per-site mail posture | the Patch Gate precedent: a per-site list of findings is a target list, so it stays behind the same grant as the resource itself (`wordpress-manager/addon.manifest.ts:54-58`) |
| `mailing:write` | send a **test** message, pause/resume a queue, edit a campaign draft, change non-credential routing (from-name, reply-to), request a DNS record | matches `email.test` and `email.log.clear` at `wordpress:write` today (`api/email-handlers.ts:45-49`) |
| `mailing:admin` | write or rotate a provider **credential**, connect an OAuth mailbox, create/delete a mailbox or domain, change the SPF/DKIM records, delete a delivery log | matches `email.config.set` at `wordpress:admin`, "config.set writes a credential ⇒ admin" (`api/email-handlers.ts:45-49`) |
| `mailing:client` (optional) | read one tenant's own delivery report | copy `wordpress:client` exactly: a tier no other route accepts, so the bound is structural (`rbac.ts:33-39`) |

**Structurally excluded from the master switch** — i.e. candidates for
`NEVER_DEFAULTED` (`feature-defaults.ts:122-130`), applying the stated criterion
"takes unattended destructive action, writes credentials, or hands out authority"
(`:32-34`), and remembering `PLATFORM_ENABLE_ALL=1` is live:

1. **Actually sending a campaign to a real list** — unattended, irreversible,
   and a bad default gets the platform's sending domain blocklisted. This is the
   direct analogue of `WORDPRESS_PATCH_AUTO_REMEDIATION_ENABLED`.
2. **Mailbox / credential provisioning** (creating a mailbox, minting or storing
   an SMTP or API credential, completing an OAuth handshake) — "writes
   credentials", the same reason `SECRET_REMEDIATION_WRITE_ENABLED` is excluded.
3. **Writing DNS records** (SPF/DKIM/DMARC) — this mutates real infrastructure
   outside the cluster, the same class as `FLEET_PROVISION_ENABLED`.
4. **Reading mailbox contents** (if the addon ever does) — that is authority
   over a person's correspondence, not a feature; nothing in `GATES` currently
   has this shape, which is itself a reason to force a per-flag decision.

Everything read-only — posture, verdicts, redacted logs, queue state — can ride
the master switch, and probably should, so the surface is not dark on arrival.

⚠️ If a gate uses `LITERAL_TRUE_ONLY`, say so in the manifest comment: the
production Deployment already records that `"1"` on those gates is a no-op
(`deployment.yaml:249-250`).

---

## 4. How WordPress mail works today

This is the section that decides how much of a mailing addon is *integration*
rather than *invention*. The answer: most of the engine already exists, on the
site side, and the console sees almost none of it.

### 4.1 The connector's mail stack (site side)

**Three layers, all gated on the single `email_delivery` entitlement:**

**Layer 1 — the legacy SMTP engine.** `includes/class-iwsl-email-delivery.php`
(1228 lines). Owns SMTP settings, the capped redacted delivery log, and the test
send (`:1-60` is the whole trust/credential model). Credential policy:
`IWSL_SMTP_PASS` in `wp-config` **wins** and is preferred; database storage is an
explicit opt-in and is AES-256-GCM encrypted under an HKDF-derived per-site key
from WordPress's own salts, failing **closed** if no authenticated cipher exists;
the secret is never echoed, never logged, and a PHPMailer error quoting it is
redacted to `****` (`:29-45`). Log accuracy: `wp_mail` fires *before* the send,
so an optimistic "sent" is **retracted** on failure rather than leaving a
sent+failed pair (`:53-60`).

**Layer 2 — the multi-method engine.** `includes/class-iwsl-mail-methods.php`
(939 lines), `final class IWSL_Mail_Methods` at `:47`. Owns which method is
active, that method's validated + encrypted config, the OAuth handshake state,
tokens and refresh timing, and the send for every HTTPS-delivered provider.
Store keys: `email_method` (`:53`), `email_method_config` (`:55`),
`email_method_tokens` (`:57`), `email_oauth_state` (`:59`). Default method
`smtp` (`:62`). Per-field wp-config constant escape hatch
`IWSL_MAIL_<METHOD>_<FIELD>` always wins over the database (`:68`, and `:27-31`).
Secrets encrypted unconditionally, save fails closed (`:22-26`). Key methods:
`set_method` (`:193`), `save_config` (`:313`), `snapshot` (`:707`).

**The provider registry is one line per provider** — `IWSL_Mail_Registry::all()`
(`includes/class-iwsl-mail-registry.php:102-121`) returns **16 methods**:
Gmail, Outlook/M365, SendGrid, Mailgun, SES, Postmark, Brevo, Resend, Mailjet,
SparkPost, SMTP2GO, ElasticEmail, MailerSend, ZeptoMail, Mandrill, Mailtrap, and
plain SMTP last. The ordering is a deliberate recommendation
(`class-iwsl-mail-registry.php:11-16`). Each implements `IWSL_Mail_Method`
(`class-iwsl-mail-method.php`) declaring `id/label/kind/icon/blurb/docs_url/
availability/fields/steps/is_configured` — the picker, the wizards, the save
validator, the signed snapshot and the send path **all** read from `all()`, so
adding a provider is one line and no switch statements
(`class-iwsl-mail-registry.php:6-10`). OAuth methods live in
`class-iwsl-mail-oauth-methods.php` (465 lines); keyed/token/API method families
in `class-iwsl-mail-methods-keyed.php` (386), `-token.php` (552), `-extra.php`
(405), `-api-method.php` (326); SES separately (`class-iwsl-mail-ses.php`, 243).

**Layer 3 — the Deliverability Doctor.**
`includes/class-iwsl-deliverability.php` (590 lines), gated on the same
`email_delivery` flag rather than a new one (`:38-42`). It resolves the sending
domain's records and answers **whether the transport that is actually configured
is authorised by the SPF record that actually exists** — not "is SPF set up"
(`:53-58`). It carries a per-transport `SPF_INCLUDES` map for all 15 HTTPS
providers (`:59-75`) and a `DKIM_SELECTORS` probe list (`:82`), checks DMARC
policy and translates it into what receiving servers will *do* (`check_dmarc`
`:300`), and flags a From on a domain whose own DMARC will reject the message no
matter what. `check_spf` `:208`, `check_dkim` `:269`. Severities
`fail/warn/unknown/info/ok` (`:45-51`), and the verdict is **the weakest link,
never an average** (`verdict` `:575`). Critically: a check that cannot be
performed reports **UNKNOWN, not pass** (`:21-24`) — the same S8 discipline the
console's design canon requires. DNS is injectable and there is no caching of a
negative result, because DNS changes are exactly what the operator is about to
make (`:26-30`).

**White-label.** `class-iwsl-email-brand-surface.php` prepends an operator-branded
header (logo + brand name) to outgoing HTML mail, gated on `white_label` with
`apply_to_email` (`:1-20`). Pure function of settings, so a live preview needs
no endpoint.

### 4.2 The newsletter suite (site side)

`newsletter` is its own entitlement (`class-iwsl-newsletter.php:38`). 21 classes,
~11 000 lines:

| Class | Lines | Owns |
|---|---|---|
| `class-iwsl-newsletter.php` | 1087 | the subscriber list and consent lifecycle. Table `iwsl_newsletter_subscribers` (`:41`), schema v4, **additive only** because the table holds consent evidence (`:50-56`) |
| `class-iwsl-newsletter-campaigns.php` | 1575 | composition; a classic rich-text composer, *not* the block editor, because block markup is web-page markup and a newsletter must survive Outlook's Word renderer and Gmail stripping `<style>` (`-queue.php:23-27`). Holds the pre-send `IWSL_Deliverability` linter (`:80, :97-104`) |
| `class-iwsl-newsletter-queue.php` | 1070 | the paced send queue. **Never-send-twice is structural**: a UNIQUE key on `(campaign_id, subscriber_id)` (`:41-50`), and a row is claimed by a single conditional UPDATE whose affected-row count decides ownership. Crash-resume via a reclaimable claim timestamp (`:9-20`) |
| `-subscribers` / `-segments` / `-segment-studio` / `-audience` | 932/536/406/270 | who a campaign reaches, resolved at **send** time not save time (`-queue.php:28-30`) |
| `-hygiene` / `-insights` / `-abtest` / `-automations` / `-schedule` | 891/553/784/403/405 | list health, campaign analytics, A/B subject tests, welcome/drip automations, scheduling |
| `-form` / `-template` / `-merge` / `-fields` | 441/300/252/382 | signup form (block/Elementor/shortcode), templates, merge tags, operator-defined fields |
| `-console.php` | 655 | **a wp-admin screen**, not the InfraWeaver console (`:1-27`) |

Three design decisions worth carrying into any console surface
(`class-iwsl-newsletter.php:9-30`): confirm tokens and unsubscribe tokens are
different animals (random/single-use/hashed/expiring vs. an HMAC that never
expires); **the public confirm/unsubscribe paths are deliberately not
entitlement-gated**, because a mail already in an inbox must keep working after
a plan lapses; and subscribing never reveals whether an address is already on the
list.

### 4.3 The signed `email.*` surface — and the gap

The connector allow-lists **84** signed methods
(`includes/class-iwsl-plugin.php`, `command_handlers()` at `:240`,
`allowed_methods()` at `:228`). Seven are `email.*`:

| Method | Connector | Console `RPC_REGISTRY` | Console caller |
|---|---|---|---|
| `email.config.get` | ✅ | ✅ `lib/rpc/registry.ts:755` | `getEmailConfig` `lib/iwsl-managed-ops.ts:2681` |
| `email.config.set` | ✅ strict validator `class-iwsl-plugin.php:255-300` | ✅ `registry.ts:756` | `setEmailConfig` `iwsl-managed-ops.ts:2687` |
| `email.test` | ✅ validator `:302-310` | ✅ `registry.ts:757` | `sendTestEmail` `iwsl-managed-ops.ts:2693` |
| `email.log.get` | ✅ | ✅ `registry.ts:758` | `getEmailLog` `iwsl-managed-ops.ts:2698` |
| `email.log.clear` | ✅ | ✅ `registry.ts:759` | `clearEmailLog` `iwsl-managed-ops.ts:2705` |
| **`email.methods.get`** | ✅ `class-iwsl-plugin.php:1771-1772` | ❌ **absent** | ❌ none |
| **`email.method.set`** | ✅ `class-iwsl-plugin.php:1780-1820` | ❌ **absent** | ❌ none |

**This is the single biggest reuse opportunity in the tree.** The connector
already exposes the whole 16-provider engine over the signed channel, with the
security properties already designed:

> "The read is SECRET-FREE by construction — `snapshot()` is built from
> `config_for_render()`, which replaces every credential with a boolean, so
> neither a key nor its ciphertext can cross the wire. The write accepts a
> credential ONE WAY only (into the site, inside this signed envelope) and never
> echoes it back. Per §6.4 this is a signed method, not an endpoint: there is no
> REST/AJAX surface for any of it."
> — `includes/class-iwsl-plugin.php:1762-1770`

`email.method.set` takes `{ method, config?, activate? }`, saves config through
`IWSL_Mail_Methods::save_config` and activates via `set_method`, carrying back
the machine reason and the offending **field name** on failure — never the value
(`:1781-1820`). `activate` defaults to `true` (`:1803-1805`).

Also absent from the console: **any** signed surface for the Deliverability
Doctor (`grep -rn "deliverability" src/` finds only the console's own static
`email-presets.ts` guidance and a demo fixture) and **any** signed surface for
the newsletter (`grep -rni newsletter src/` = 23 hits, all incidental strings in
tier/entitlement descriptions, ledger/staging/sandbox exclusion lists, and demo
data). The doctor is reachable only from wp-admin, via the campaign screen
(`class-iwsl-newsletter-campaigns.php:104`) and the newsletter list screen
(`class-iwsl-newsletter.php:997-1045`).

### 4.4 What the console has today

**Write API.** `src/app/api/wordpress/sites/[site]/email/route.ts:1-12` → 
`src/addons/wordpress-manager/api/email-handlers.ts:96-150`. Three verbs
(`config` / `test` / `clear-log`, `:41`), each with: per-verb permission
(`config` ⇒ `wordpress:admin`, the rest `wordpress:write`, `:44-49`),
same-origin CSRF check that fails closed (`:104`), per-verb rate limit
(30/min, `:41`, `:68-75`), a typed error funnel (`:78-93`), and a **redacted**
audit line — "host + whether a secret was touched — NEVER the password itself"
(`:120-121`). The module header states the invariant explicitly: no
unsigned/public endpoint; every verb delegates to a signed `email.*` op
(`:22-35`).

**Read model.** There is no email read endpoint — reads ride the merged panel
probe: `src/addons/wordpress-manager/lib/manage/probes/email.ts:1-18`. Primary
source is the connector's own signed `email.config.get` + `email.log.get`; the
**fallback and conflict detector** is a third-party SMTP-plugin posture read
(`wp-mail-smtp`, `post-smtp`) one non-secret field at a time via
`wp option pluck`, so a sibling secret in the same option is never read into
console memory (`:62-70`). It explicitly replaced a probe that recommended
installing a competitor to our own gated feature (`:9-12`).

**Types + validators.** `src/addons/wordpress-manager/lib/manage/email.ts`
(333 lines) — isomorphic, no `server-only`, so the API route, the probe and the
panel component share one shape. Every bound mirrors the connector
(`:1-15`). The security invariant is typed in: **there is no field that could
carry a password back to the browser** (`:11-14`); `EmailSettings` is the eight
stripped engine-owned fields (`:47-57`).

**UI.** `components/manage/email/` — `email-config-form.tsx` (323 lines),
`email-log.tsx` (237), `email-deliverability.tsx` (60, static
provider-aware SPF/DKIM/DMARC *guidance*, not a live verdict),
`use-email-actions.ts`. Presets in `lib/manage/email-presets.ts` — three
(`office365`, `google`, `custom`) with `fromMustMatchAuth` and `spfInclude`
(`:15-64`). The console's provider knowledge is therefore **3 presets against the
connector's 16 live methods**.

**Capability gate.** `lib/manage/capabilities.ts:163-164` — the email panel opens
for connector sites (built-in SMTP) **or** a site with a third-party SMTP plugin.

**The entitlement.** `email_delivery` (`lib/entitlements.ts:35`, described at
`:112-117`) and `newsletter` (`:62`, described at `:250-256`). ⚠️
`ENTITLEMENT_FLAGS` is **exactly at `MAX_ENTITLEMENT_FLAGS = 32`**
(`entitlements.ts:57-64`, `:298`). The whole flag list is the payload of every
`entitlements.set`, so a 33rd flag is rejected wholesale by every connector still
on the 32-flag cap, freezing entitlements fleet-wide. The stated sequence to
raise it: bump `MAX_FLAGS` in the plugin, ship it to every channel, confirm the
fleet took it, *then* raise the console constant (`:286-297`).

### 4.5 The console's own mail transport

Separate and much simpler: `src/lib/mailer.ts` (258 lines), a nodemailer wrapper
configured from `SMTP_HOST`/`SMTP_USERNAME`/`SMTP_PASSWORD`/`SMTP_PORT`/`SMTP_FROM`
(`resolveSmtpConfig` `:44-56`). It returns `null` rather than throwing when
unconfigured, so an invite still mints its link (`:38-43`). The From-address rule
is documented and must not be relaxed: O365 rejects a From that differs from the
authenticated mailbox with `550 5.7.60` unless SendAs is granted (`:10-16`), and a
`${…}`-shaped value is treated as unset so an unrendered manifest placeholder can
never become the sender (`:33-36`). `src/lib/email-logo.ts` supplies
`brandedEmailHtml` / `ctaButton` / `logoAttachment`.

There is also an **overlapping** mail surface: the alert manager's contact points.
Their credentials live in OpenBao at one shared path
(`src/lib/alerts/contact-secrets.ts:36`, `CONTACT_SECRET_PATH = "platform/alerts"`),
because the console's OpenBao policy grants exactly that one alerting path with
no wildcard (`:9-18`) — and KV v2 replaces the whole secret object on write, so
every write is read-merge-CAS (`:19-22`). Delivery/render live in
`src/lib/alerts/delivery/`.

---

## 5. The signed site channel

A mailing addon that provisions a mailbox *for a site* has to reach the site.
There is exactly one way, and it has sharp edges.

### 5.1 The shape

```
console handler
  → lib/iwsl-managed-ops.ts   (requireManagedRecord → requireCommandable → requireRunningPod)
  → rpcTransport(record, execDelivery(pod), "exec")
  → lib/rpc/registry.ts  callRpc(transport, method, params)   ← typed catalog + validator
  → dispatchSignedCommand   (allocateSeq → createSignedCommand → deliver → verify)
  → k8s exec into the site's WordPress container, signed JSON on stdin
  → plugin verifier → handler → signed response
  → verifySignedResponse against the PINNED WP public key
```

### 5.2 The RPC registry

`src/addons/wordpress-manager/lib/rpc/registry.ts` (837 lines). Deliberately
isomorphic — it holds the method catalog and a pass-through, never a transport;
the server-only transport is injected by `iwsl-managed-ops` (`:14-17`).

- `RpcMethod` union (`:216`), `RpcParams` map (`:429+`), `RpcResults` map
  (`:602+`), `RPC_REGISTRY` with a per-method `validate` (`:635-762`),
  `RPC_METHODS` (`:763`), `callRpc` (`:827-832`).
- The validators **mirror the plugin's own** rule for rule, so *the console
  refuses to SIGN what the plugin would refuse to EXECUTE* — because a malformed
  push otherwise burns a sequence number on the far side
  (`registry.ts:657-662`, `:648-651`).
- `CommandReply` is `{ ok, kid, result, roundtripMs, rejectedReason? }`
  (`:766-775`).

### 5.3 The per-site link record

`src/addons/wordpress-manager/lib/iwsl-link-store.ts` (513 lines). Non-secret
link state lives in **one ConfigMap** in the console namespace
(`infraweaver-iwsl-sites`, `:20-21`) with optimistic concurrency; single-use
enrollment secrets live apart in a k8s Secret and are burned on verify (`:10-18`).

`ExternalSiteRecord` (`:53-…`) carries `siteId`, `url`, `state`,
`fingerprintConfirmed`, the **pinned `wpPk`**, `kid`/`epochFloor`/`iwKid`,
`iwAlg` (the SLH-DSA parameter set this link pinned — per-link so the fleet
migrates with no flag day, `:78-86`), `lastSeq` (`:93-94`), `pendingRotation`,
`lastReroll`, `rejections`, and restore/identity guards.

`ExternalSiteState` is `pending | active | quarantined | repair-needed` (`:41`),
and the distinction between the last two is load-bearing: **quarantined is an
accusation** (a response failed verification against the pinned key — the tamper
signal), **repair-needed is a diagnosis** (a restore rolled the plugin's half of
the link back). Both cut the signing path; they differ in what the operator is
told and what fixes it (`:24-39`).

### 5.4 The contract, and the traps

**Preconditions, in order** (`iwsl-managed-ops.ts`):

1. `requireManagedRecord(site)` — 404 "no connector link" (`:288-291`);
2. `requireCommandable(record)` — 409 on quarantined (`:303-305`),
   409 on repair-needed with the named cause (`:306-315`), 409 if not `active`
   / fingerprint unconfirmed / no pinned key (`:316-318`);
3. **writes only** — `requireIdentityConfirmed(record)`: 409 while the link is
   in clone/identity safe mode, i.e. the site self-reported a changed canonical
   URL (`:349-357`). Read-only diagnostics are deliberately *not* gated, because
   the operator needs them to investigate a clone;
4. **writes only** — `requireNoRestoreInProgress(record, what)`: 409 while a
   restore is rewriting the site, because the restore's write-back silently
   undoes the change (`:321-341`);
5. `requireRunningPod(site)` — 503 if the WordPress pod is not running
   (`:382-386`).

The email family shows the exact split: `emailReadTransport` does 1+2+5
(`:2663-2669`), `emailWriteTransport` adds `requireIdentityConfirmed`
(`:2671-2678`).

**Sequence numbers.** `allocateSeq` increments `record.lastSeq` inside
`mutateExternalSites` (`:389-397`); the plugin rejects `seq <= last_seq`
(`iwsl-link-store.ts:93-94`). The known failure is a **lost-persist race**
between `allocateSeq` and its retry-tolerant persist, which leaves the console
behind the plugin and turns every subsequent command into `seq-rollback` —
soft-bricking the link (`rpc/registry.ts:781-793`).

⚠️ **`recoverFromSeqDrift` is opt-in and must stay opt-in.** A modern plugin's
`seq-rollback` reply carries a `last_seq` hint; opt-in callers reconcile and
retry **once**, capped by a `reconciled` flag so a broken plugin cannot spin
(`iwsl-managed-ops.ts:479-486`, `:521-543`). Only **operator-initiated** ops
enable it. The **scheduled sweeps must not** — they exist to *surface* drift as a
health signal, and a silent recovery there hides a fleet-wide condition
(`rpc/registry.ts:786-792`).

**Signing and verification.** `createSignedCommand`
(`src/lib/iwsl/envelope.ts:74-…`) builds a JCS-canonicalised envelope
(`v, typ, site_id, nonce, seq, kid, ts, exp, method, params, aud`) and dual-signs
it. `aud` is the **§6.4 channel binding** — `{ site, chan }`, plus an `spki` pin
set on HTTPS (`envelope.ts:41-64`) — so a captured valid command is
non-redirectable to another channel or endpoint. The command is signed with the
SLH-DSA set **this link** pinned (`record.iwAlg ?? ALG_SLHDSA`,
`iwsl-managed-ops.ts:544-551`).

Responses are verified against the pinned `wpPk` (and optionally an `altWpPk`
during a rotation) before anything is trusted
(`iwsl-managed-ops.ts:543-560`). A verification failure normally quarantines the
link — but **not** during a restore window (recorded as `repair-needed` with a
named cause, `rejections` deliberately not incremented, `:412-444`) and **not**
during a rotation guard (`:445-456`). The check never changes; only the verdict
does.

**Transports.** Two, one verifier:

- `execDelivery(pod)` — the managed §5.1 path: `execInWpPod` with the signed JSON
  on **stdin** (`iwsl-managed-ops.ts:231-245`). Stdin specifically so secrets
  never become a process argument and never land in the k8s exec audit log
  (`lib/k8s-exec.ts:12-14`). Output is capped at 1 MB because the WordPress
  container is a separate trust domain and could otherwise OOM the shared console
  process (`k8s-exec.ts:33-42`). Default container is `wordpress`; `mariadb` in
  the `<site>-db` pod is the other target (`k8s-exec.ts:17-30`).
- `httpDelivery(url, pinnedSpki)` — the external §5 path: SSRF-safe HTTPS POST
  with a 64 KB body cap and cert pinning as defence in depth
  (`iwsl-managed-ops.ts:254-280`). The §2 invariant holds: the site never dials
  the console.

A MITM on the external channel is caught exactly as an in-cluster tamper would be,
because the verifier is shared (`iwsl-managed-ops.ts:463-469`).

**Client-side.** `useSignedOp(site)` is the one wrapper
(`lib/manage/use-signed-op.ts:1-60`): POSTs `{ action, ...extra }` to
`/api/wordpress/sites/<site>/iwsl/ops`, toasts uniformly, and invalidates a
standard key set (`:52-60`). Its header states the invariant: it never introduces
a new public endpoint.

### 5.5 Enrollment (if a mailing addon ever needs a new link)

`lib/iwsl-managed.ts:27-36` — §5.1 automated enrollment for cluster sites is the
same crypto as manual enrollment (bundle, possession proof, WP-PK pinning); only
delivery changes, and the fingerprint compare is auto-confirmed because the
console controls both endpoints and the material never touches the network.
`readWpLinkState` returns `null` for "we could not find out", deliberately
distinct from a successful read of an unenrolled site, **because S8 forbids
rendering an unknown as an empty** (`iwsl-managed.ts:70-93`).
`findOrphanedConnectorLink` (`:100-105`) detects the state where WordPress still
believes it is enrolled and the console holds no record — which needs a *repair*,
not an enroll, because the plugin refuses a second bundle with
`already-enrolled` (`:53-64`).

---

## 6. What a mailing addon should reuse, and what it must build

### Reuse — do not rebuild

| Reuse | Where | Why |
|---|---|---|
| **The 16-provider mail-method engine, over the signed channel** | `email.methods.get` / `email.method.set`, `class-iwsl-plugin.php:1762-1820`; engine `class-iwsl-mail-methods.php:47` | **The single biggest win.** Two allow-listed signed methods already exist and the console calls neither. Adding them to `RPC_REGISTRY` (`lib/rpc/registry.ts:635`) + `RpcMethod` (`:216`) + two wrappers in `iwsl-managed-ops.ts` is a small change that unlocks a 16-provider picker with OAuth, per-provider field schemas (`fields()`), availability reasons, and `is_configured` — all secret-free by construction |
| **The Deliverability Doctor's verdicts** | `class-iwsl-deliverability.php:138-171`, `SPF_INCLUDES:59`, `check_spf:208`, `check_dkim:269`, `check_dmarc:300`, `verdict:575` | 590 lines of correct SPF/DKIM/DMARC logic with UNKNOWN-is-not-pass semantics that match §S8 exactly. It needs a signed method (see "must build") but **no new logic** |
| **The newsletter list + paced queue** | `class-iwsl-newsletter.php`, `-queue.php:41-50` | never-send-twice is a UNIQUE DB key, not procedure; crash-resume is already designed; consent evidence is already schema-additive. Rebuilding this in the console would be strictly worse |
| **The signed channel end to end** | `lib/rpc/registry.ts`, `lib/iwsl-managed-ops.ts`, `lib/iwsl-link-store.ts`, `src/lib/iwsl/**` | do not invent a second site transport. `callRpc` + a validator mirroring the plugin is the whole integration cost |
| **The write-handler shape** | `api/email-handlers.ts:1-150` | per-verb permission map, same-origin, rate limit, typed error funnel, redacted audit. Copy this file's structure verbatim for `mailing` verbs |
| **The isomorphic types + validator module** | `lib/manage/email.ts:1-15` | one module the API route, the probe and the component all import, with bounds mirroring the connector, and *structurally no field that can carry a secret to the browser* |
| **The merged read-model probe pattern** | `lib/manage/probes/email.ts:1-18, 62-70` | connector-first with a `wp option pluck` fallback that reads one non-secret leaf at a time — and doubles as conflict detection when a third-party plugin is active |
| **The console's own SMTP transport + branded HTML** | `src/lib/mailer.ts:44-56`, `src/lib/email-logo.ts` | if the addon sends *platform* mail (not site mail), this is the path, including the O365 From rule |
| **The `wordpress:client` delegation shape** | `src/lib/rbac.ts:33-39`, `addon.manifest.ts:96-101` | the template for a tenant-facing mail report tier whose bound is structural |
| **The page shell + `SiteTabs`** | `pages/site-patches.tsx:15-32`, `components/site-tabs.tsx:19-49` | if mailing gets a per-site tab, this is the chrome and the array to extend |
| **`HoldToConfirm`, `PageScaffold`, `StatusBadge`, `EmptyState`, `IconButton`** | `src/components/ui/**` (`INFRAWEAVER-STYLE.md:1785`) | the only way to pass `confirm-standard` and `icon-button-name` without spending ratchet budget |

### Must build

1. **Two console-side RPC bindings that already exist site-side.**
   `email.methods.get` / `email.method.set` — types, validators mirroring
   `class-iwsl-plugin.php`, registry entries, and `iwsl-managed-ops` wrappers.
2. **A signed method for the Deliverability Doctor.** Nothing named
   `deliverability.*` is in the connector's 84-method allow-list. This is a
   connector change (a new `IWSL_Command_Handler` + validator) plus the console
   binding. Read-only, so it should ride the `email_delivery` gate the doctor
   already uses (`class-iwsl-deliverability.php:38-42`) rather than mint a flag.
3. **A signed newsletter surface, if the addon is to drive campaigns.** Today the
   entire newsletter is wp-admin-only. Sending is the dangerous verb; see the
   `NEVER_DEFAULTED` recommendation in §3.3.
4. **The `mailing` manifest + permission family + roles**, per §3.3.
5. **Scope-triaged API handlers.** Because the census has zero slack (§2.1),
   every new handler must carry `{ scope: <resolver> }` or `{ rootScope: true }`
   — which also means the mailing family should be designed *around* a resolver
   from the start, unlike the WordPress family's 108 raw delegators.
6. **A fleet view.** Every existing mail surface is per-site (a panel inside
   `/wordpress/<site>/manage`). "Which of my 20 sites can actually deliver mail"
   has no answer today; `lib/fleet/aggregate.ts` and `api/fleet-guard.ts:17-42`
   are the pattern.
7. **Credential storage decision.** The connector stores site credentials
   site-side (encrypted, constant-preferred). If the console is to hold a
   provider credential centrally, the only precedent is the alert manager's
   single OpenBao path with read-merge-CAS
   (`src/lib/alerts/contact-secrets.ts:9-22, 36`), and the OpenBao policy grants
   no wildcard — a new path needs an infra-repo change.

---

## 7. Open questions for the design phase

1. **Where does the addon sit relative to `wordpress-manager`?** A separate
   `mailing` addon owning `/mailing/` and `/api/mailing/`, or a set of surfaces
   inside the WordPress addon? A separate addon gets a clean namespace and its
   own enable switch, but it needs the WordPress link record, the RPC registry
   and `execInWpPod` — all of which live under
   `src/addons/wordpress-manager/lib/` and are imported today only from inside
   that addon. Cross-addon imports have no precedent in this tree. Is the
   dependency declared (`dependencies[]`, `types.ts:183-187`) or is the shared
   channel lifted into `src/lib/`?

2. **Is "mailing" about *sites* or about the *platform*?** The two mail worlds
   here barely touch: site mail (connector, signed channel, per-site
   entitlement) and platform mail (`src/lib/mailer.ts` + the alert manager's
   contact points). A single addon spanning both would have to reconcile two
   credential stores and two permission stories.

3. **Does it provision mailboxes, and against what?** Nothing in this tree
   creates a mailbox anywhere. That means a new external integration (a mail
   provider API), which means a new credential, a new egress allowlist entry
   (the estate is default-deny; a console pod that cannot reach a host fails
   *server-side* and looks like an application bug), and probably a new
   `NEVER_DEFAULTED` gate.

4. **`MAX_ENTITLEMENT_FLAGS` is full at 32.** Any new site-side entitlement
   (`mailing`, `mail_provider`, …) needs the four-step fleet sequence at
   `lib/entitlements.ts:286-297` first. Can the design ride `email_delivery` and
   `newsletter` instead, the way the Deliverability Doctor rides
   `email_delivery`?

5. **What does the route-scope census cost?** With zero slack, does the design
   commit to a scope resolver for `/api/mailing/*` from day one — and if the
   addon uses the manifest `api[]` path, who triages the two `wrapper`-classified
   handlers the generated shim contributes?

6. **Which mailing operations belong in `NEVER_DEFAULTED`?** §3.3 proposes four
   (campaign send, credential/mailbox provisioning, DNS writes, mailbox reads).
   `PLATFORM_ENABLE_ALL=1` is live, so this list is the difference between
   "shipped dark" and "armed on the next image pull".

7. **Does the console ever read message *content*?** Delivery logs today store
   only `to` + `subject`, redacted (`lib/manage/email.ts:77-86`). Reading bodies
   is a materially different authority and would need its own tier, its own audit
   shape, and probably its own gate.

8. **Who owns SPF/DKIM DNS?** The doctor *diagnoses*; the console has a DNS
   surface (`src/app/api/dns`, `scripts/dns-purge.mjs`). Does the mailing addon
   propose records, or write them? Writing them is infrastructure mutation.

9. **What happens to `email-presets.ts`?** Three console presets vs. 16
   connector methods. Is the console's static preset table retired in favour of
   `email.methods.get`, and if so what does an un-enrolled or offline site show?
   (§S8: unknown is not empty.)

10. **Does mailing take a rail row?** It costs an edit to two `nav-ia.test.ts`
    assertions (47/31 and the 59 conservation law, `nav-ia.test.ts:98, 107-111`)
    with a written reason. Or it can be a tab inside the WordPress site chrome
    and cost nothing.

11. **Anti-abuse.** A console that can send as a customer's domain is a
    phishing tool if the RBAC is wrong. Is there a per-site sending quota, a
    from-address allow-list bound to the site's verified domain, and an
    unforgeable audit line? The connector clamps `email.test` to 1 send / 30 s
    on its own side (`api/email-handlers.ts:41`) — nothing bounds a campaign.
