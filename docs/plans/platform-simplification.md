# Platform Simplification Plan

**Status:** PLAN ONLY — nothing in this document has been executed. No code, manifest,
or cluster state was changed while producing it.
**Date:** 2026-08-18
**Scope:** `InfraWeaver-infra` (GitOps repo), `InfraWeaver-platform` (app source, incl.
the console), the build host (`/home/runner`), read-only live-cluster measurements.
**Goal (operator's words):** "simplify, change things to best practises, optimize and
most important clean code with removing code … less code and more simplified yet easier
to work with … prevent whatever happened today that broke all … more user proof and
easier to code and make things stable again."

**Method:** every claim below was measured on 2026-08-18 — grep reference counts,
`wc -l`, `diff`, `git log`, and read-only `kubectl --server=https://10.0.0.92:6443`.
Where something could not be verified it is marked as an open question in §9 with the
command that settles it. Items are ranked in §8 by (impact on stability × certainty) ÷ risk.

---

## 0. What happened today, and the principles this plan is built on

The failure chain (full detail in the two memory files
`project_cluster_scan_cleanup_2026-08-18.md` and
`project_cp1_phantom_cluster_cilium_deadlock_2026-08-18b.md`):

1. cp1's etcd WAL corrupted; the member dir was wiped; on reboot Talos **bootstrapped a
   second, empty cluster** on cp1 serving its own kube-apiserver.
2. Talos **KubePrism** kept cp1 in every node's apiserver pool (pool = discovery
   members, not the k8s Service), so a control-plane endpoint change restarted all
   kubelets straight onto the phantom.
3. **NodeRestriction** denied every real kubelet ("no relationship found between node
   … and this object"); ServiceAccount tokens minted in the window were signed by the
   phantom and permanently rejected (365-day expiry — kubelet never re-mints).
4. **Cilium deadlocked**: it reaches the apiserver through the ClusterIP whose datapath
   translation it itself programs. Every new pod cluster-wide failed to start.
5. `kubectl get nodes` said Ready throughout (the node-lifecycle controller was down
   too). The decisive evidence was frozen `kube-node-lease` renew times and kubelet logs.

Around it, the same repeated shapes, all measured this week:

- **Controls that report success while protecting nothing** — 3 Velero schedules
  `Completed` with 0 bytes copied (fs-backup silently skips hostPath); a backup
  verifier disabled 4 days by one empty record; a `-mtime +1` guard that needed 48h;
  a `BackupRepository` reporting `Ready` while its maintenance job failed every 5 min.
- **Storage that pins workloads to one node** — 15 PVCs on `local-path(-retain)`,
  node-affinity-pinned, invisible to Velero, several with suspended or absent backups.
- **True-but-useless health signals** — GTNH `Running 1/1` for 78 min while blocked on
  a Forge prompt; console `/api/ping` returns a hardcoded literal; ~30 catalog apps
  probe TCP only.
- **Alerting that can't fire or fires forever** — 8+ alert families keyed on metrics
  with zero series; name-based exclusion lists that rot (`falco` ×9 in Kyverno
  excludes, `n8n-prod` still listed after deletion).
- **Generators that betray their outputs** — `sync-groups.sh` `git add -A` auto-commits
  unrelated working-tree drift (it has committed a `generated/kubeconfig` and backup
  copies of `users.yaml`, and nearly disabled MinIO — the backend of every Velero
  backup); `sync-catalog.sh`, if run today, would rewrite 4 Applications to a bogus
  repoURL and delete 7 live bootstrap Applications.

**Principles** (each traced to a failure above):

- **P1 — A control that cannot fail visibly is not a control.** (velero-localpath,
  jellyfin kopia repo, backup verifier, suspended-and-excluded nextcloud backups)
- **P2 — Two mechanisms for one job means neither is trusted.** (two script trees, five
  data-fetch layers, two etcd snapshot scripts, six copies of one exclude list)
- **P3 — Generated files are generated, or they are lies.** (hand-edited
  "do-not-edit" bootstrap files that the generator would destroy)
- **P4 — Name-based lists rot. Derive from specs/labels, or give entries an expiry.**
  (falco/n8n-prod residue; `CronJobMissedSuccess` is the good counter-example — it
  derives its threshold from each CronJob's own schedule)
- **P5 — Node-pinned state is an outage and a data risk at once.** (the entire cp1
  evacuation problem; WordPress pods unschedulable off their node)
- **P6 — Dead code in an ops repo is not neutral: it is armed.** (`sync-catalog.sh`;
  the unreachable `scripts/init/init` tree that three scripts still "call")

### Corrections to prior session notes (verified live today)

- `ChangesetReviewPanel` is **alive** (imported by `staging-merge-lane.tsx:38`) — the
  08-16 "imported by nothing" memory is stale. Do not delete it.
- The Prometheus/Loki/Alertmanager PVCs are **live on `longhorn`** (measured
  `kubectl get pvc -n monitoring`); only comments in `audit-and-retention.yaml` still
  describe them as local-path — a doc fix, not a migration.
- cp1 **rejoined the real etcd** (member `28056bf6d090d2eb`, same RAFT INDEX as
  cp3/cp4, 3/3 voting) and its apiserver serves the real cluster; the
  `phantom-cluster-do-not-serve` flag is gone. cp1 remains **suspect hardware**
  (deterministic container-image corruption, twice, on fresh stores) and cp3 is the
  smallest node (98 GiB ephemeral) with a DiskPressure history.
- The "unpushed deploy-safe branch" scare is **false**: remote `main` == local HEAD
  (`7e766ce`, verified via `git ls-remote`). The local `origin/main` tracking ref was
  simply stale. The lesson (H10) is real; the emergency is not.

---

## 1. The measured estate (the denominator)

| Surface | Size |
|---|---|
| `kubernetes/` manifests | 514 files, **54,203 lines** (catalog 19.5k, core 13.1k, platform 13.1k, monitoring 5.2k, bootstrap 3.2k) |
| `InfraWeaver-infra/scripts` | 82 files, **19,691 lines** |
| `InfraWeaver-platform/scripts` | 60 files, **15,311 lines** (≈15,575 lines duplicate infra's) |
| Console source (`src/`, excl. generated) | 3,132 files, **570,040 lines** TS/TSX |
| Console tests | 1,199 files, 276,071 lines (with anti-vacuity ratchets — see §2.4) |
| Build host `/home/runner` | 54 near-identical `*-build.sh` + ~20 loose plan/notes files + 21 kubeconfig variants in `~/.kube` |
| Live cluster | 70 ArgoCD apps (**8 manage zero resources**), 42 CronJobs, 27 Longhorn volumes, 15 PVCs on local-path classes |

---

## 2. DELETE inventory (evidence-backed)

Grand total identified for deletion: **≈24,000 lines of code and manifests** plus
**≈7,200 lines of finished plan documents** and ~390 MB of build/tool residue.
Everything here is delete-only — no rewrites hiding inside.

### 2.1 Tier A — zero risk (zero callers, zero cluster interaction)

Verify for every row: the grep evidence cited. Rollback for every row: `git revert`
(single commit per numbered group), or restore from `/home/runner` backups where noted.

| # | Item | Evidence | Lines |
|---|---|---|---|
| A1 | `/home/runner`: 53 of 54 `*-build.sh` (keep `consoleup-build.sh` — the only one referenced, by iwdash/iwrun and 4 docs; the 53 collapse to 12 template bodies differing only by slug) + `finish-forward-auth-deploy.sh`, `gamewan-livetest.sh` (0 refs) | slug-normalized md5 collapses 54→12 bodies; grep: only consoleup is cited anywhere | ~1,100 |
| A2 | infra `scripts/dev-start.sh` + `scripts/health-check.sh` — target `docker compose … console api mock` and `localhost:3000/3001/4010`; **infra has no docker-compose.yml and no apps/** (platform's identical copies are the live pair) | grep: 0 real callers in infra | 49 |
| A3 | infra 6 zero-ref `scripts/deploy/*`: `check-argocd-health.sh`, `generate-recovery-links.sh`, `notify-discord.sh`, `sync-argocd-app.sh`, `seed-user-secrets.sh`, `smoke-test-url.sh` — their GitHub Actions callers no longer exist in either repo | `deploy-local.sh`'s full invocation list (15 call sites) contains none of them | 441 |
| A4 | infra user-lifecycle orphans: `create-new-users.py`, `list-recovery-users.py`, `sync-authentik-users.py`, `sync-authentik-users-api.py`, `extract_kubeconfig.py`, `etcd-heal.py`, `generate-homepage-config.py` — superseded by inline Python in `deploy/generate-recovery-links.sh:28` and `deploy/send-welcome-emails.sh:17` | 0 invocations repo-wide (only comments) | 875 |
| A5 | `platform.yaml:149-153,164-166` — `homepage` and `wazuh` entries: **no such directories exist** under `kubernetes/platform/`; flipping them to `true` deploys nothing and errors nothing | `ls kubernetes/platform/` | 8 |
| A6 | `scripts/sync-groups.sh:402` — COMPANIONS entry `app-external-dns-helm.yaml`: the file has never existed; prints a warning every run, training operators to ignore warnings | grep: 1 hit (the map itself) | 1 |
| A7 | `kubernetes/apps/_template/`, `kubernetes/catalog/_template/`, `kubernetes/catalog/n8n/` (0 yaml, 545 lines of workflow JSON/README for the deleted n8n) | 0 references / no catalog.yaml install path | ~570 |
| A8 | `kubernetes/n8n-blueprints/` + `kubernetes/development/` — both render **zero resources** live (measured), both dormant-marked, cited only by a 67-day-old doc; delete together with their two tier Applications via C1 | `kubectl … get application n8n-blueprints development` → 0 resources | 137 |
| A9 | `kubernetes/monitoring/victoria-metrics/` — the only `.disabled` app with **zero** inbound references (absent from platform.yaml AND COMPANIONS; untouched since the initial commit 81 days ago) | grep: 0 hits | 172 |
| A10 | `kubernetes/bootstrap/catalog-game-hub-networks.yaml` + `kubernetes/catalog/game-hub/networks/` — a 45-line Application whose source directory contains one README; `prune: true` over an empty source becomes a mass-delete trigger the day anything lands there | `ls` = README.md only; live app manages 0 resources | ~50 |
| A11 | Stale names in lists: `falco` ×9 (`cluster-policies.yaml:113,238,309,375,449,519,587`, `no-latest-tag-policy.yaml:44,118`, `seccomp-policy.yaml:49,139`, `resource-governance-policies.yaml:389`), `n8n-prod` ×2 (`resource-governance-policies.yaml:317,342`), `stirling-pdf` ×2 | policy excludes naming namespaces that don't exist are inert but rot the lists | ~15 |
| A12 | Console: 14 confirmed-dead source files (0 importers, verified 3 ways): `src/lib/update-manager.ts` (194), `src/lib/addon-pod-tabs.ts` (58) + `src/components/addons/addon-pod-tab-renderer.tsx` (81), `src/components/security/audit-log-table.tsx` (172), `…/network/firewall/_components/pod-firewall-panel.tsx` (17), `…/wordpress-manager/components/demo/site-manage-ext-data.ts` (628), `src/lib/internal-url-allowlist.ts` (23), `src/lib/insecure-fetch.ts` (33 — also removes a documented SSRF footgun), `src/lib/ux/use-url-state.ts` (132), `src/lib/storage/reclaim/deleters.ts` (165), `…/manage/security-breakdown.ts` (193), `…/demo/DummyBadge.tsx` (45), `src/components/layout/nav-favorites-config.tsx` (45), `…/security/_components/tabs.tsx` (84) | full-tree import-suffix scan; residual mentions are comments only | ~1,870 |
| A13 | Console/platform repo-root plan docs: `NEXT-FEATURES-PLAN.md` self-declares "**this whole wave is BUILT … do not re-implement from it**"; archive (git mv to `docs/archive/plans/`) the 6 other shipped `*-PLAN.md` and the 6 `WAVE-*-PLAN.md` inside `src/addons/wordpress-manager/components/manage/media/` | shipped artifacts they specify all exist | ~7,200 (moved/deleted) |
| A14 | Untracked residue: infra `.ruff_cache/` (244K) + 6 `.impeccable/` dirs (140K, two inside CMP-rendered manifest paths); console 7 orphaned `*.tsbuildinfo` (3.3 MB, 6 reference deleted tsconfigs) + 24 `.impeccable/` caches; add `.gitignore` entries | `git ls-files` returns 0 for each | ~390 MB disk |
| A15 | `~/.kube`: 21 kubeconfig variants incl. `.corrupt.bak.*` — keep the active one (see H3), archive the rest to a tarball outside `~/.kube` | only `~/.bashrc:125` selects one | — |
| A16 | platform `scripts/setup-onedev.sh` (OneDev is retired per `git-hooks/README.md`) + `scripts/init/out/` (35 tracked files, 1.3 MB of committed Next.js build output → delete + gitignore; confirm `build-ui.sh` runs in the deploy path first) | grep + git ls-files | 447 + 1.3 MB |

**Tier A total: ≈5,700 lines code/manifests + ~7,200 lines plan docs + ~392 MB residue.**

### 2.2 Tier B — low risk, needs one paired edit in the same commit

| # | Item | Paired edit | Lines |
|---|---|---|---|
| B1 | Console `…/storage/_components/reclaim-view.tsx` (383, 0 importers) | `tests/unit/bottom-bar-clearance.test.ts:177` pins its literal path — update in the same commit | 383 |
| B2 | Console 25 one-line re-export shims: 18 in `src/components/game-hub/` + 7 `src/lib/game-*.ts` — 236 imports flow through them to files that live next door in the addon | mechanical repoint of 236 imports; proof is `npx tsc --noEmit` | ~30 (but −1 concept) |
| B3 | Move the 8 real files in `src/components/game-hub/` (modded-wizard, wizard-chrome, server-actions — 1,745 lines) into `src/addons/gamehub/components/` — they are gamehub-only and are why the shims exist | same repoint pass as B2 | 0 (moved) |
| B4 | Rename `…/wordpress-manager/lib/backup/capture-v2.ts` → `capture.ts` (no v1 exists) + the 3 `-v2` test names | rename only | 0 |
| B5 | infra: merge `validate-eso-refs.sh` (105, currently advisory `\|\| true` in CI), `validate-platform-yaml.sh` (235, 0 callers), `validate-users-yaml.sh` (72, 0 callers) into `validate-iac.sh` as three additional gates; delete the three files + the two dangling platform `Makefile` targets (`:225`, `:228`) that call scripts that don't exist there | CI workflow drops 1 step; `validate-iac.sh` header already claims these as siblings | net ~350 |
| B6 | infra: `validate-cluster.sh` (286, 0 callers) — port its node-Ready block (`:252-259`, duplicated verbatim in `test-post-deploy.sh:95-100`) if wanted, delete the rest | it is the only SSH/datastore preflight; confirm nothing manual uses it (§9 OQ2) | 286 |
| B7 | Console `src/lib/service-fetch.ts` — 1 call site of its only factory; fold into `api-client` | one import | ~60 |
| B8 | Console `src/components/features/` — 11 files / 2,023 lines reached through **3** import statements; fold into its consumer | repoint 3 imports | 0 (moved), −1 dir |
| B9 | Drop unused devDependency `dependency-cruiser` **or** configure it as the permanent dead-code gate (recommended: configure — see H9) | package.json | — |

**Tier B total: ≈1,100 net lines, minus one whole concept (shim layer).**

### 2.3 Tier C — real deletions that need a decision or a live check first

| # | Item | Evidence | Decision needed | Lines |
|---|---|---|---|---|
| C1 | **Narrow the terraform tier generator** `terraform/modules/platform-bootstrap/main.tf:224-290` from `kubernetes/*` to `{bootstrap,crds}` — it currently mints **7 Applications that render exactly nothing** (`apps`, `catalog`, `core`, `development`, `monitoring`, `platform`, `n8n-blueprints`; measured live: 0 resources each) plus a namespace per directory | live `.status.resources \| length` = 0 for all 7; `validate-gitops-coverage.py:33-35` documents the trap | The minted `bootstrap`/`crds` namespaces are load-bearing (`baseline-namespaces.yaml:306,334`, `psa/namespace-labels.yaml:278,288`); `preserveResourcesOnDeletion=false` means removal cascades — do this via terraform plan/apply in a window, never by deleting Applications by hand | ~66 tf + 7 live apps |
| C2 | **`scripts/sync-catalog.sh` (356) + `redeploy-local.sh` (270) + `update.sh` (239)**: sync-catalog's orchestrating workflow (`apply-changes.yml`) no longer exists; running it today would rewrite 4 bootstrap Applications to `repoURL: https://github.com/your-org/your-repo.git` and **delete 7 live `catalog-*.yaml` bootstrap files** (its cleanup loop vs. `platform.yaml catalog.enabled`); redeploy-local/update are dependents of the dead `init/init` tree | measured: generator output vs. committed files; 7-file delete list enumerated | Either fix its templates to match the 4 hand-tuned files and re-wire a caller, or delete all three. **Recommended: delete**; the four `catalog-infraweaver-*.yaml` become hand-maintained (they already are — remove their "do not edit" headers, which are lies per P3) | 865 |
| C3 | **infra `scripts/init/init/**` (6,898 lines)** — tracked at a nested path since the repo split; unreachable: every caller points at `scripts/init/…` which does not exist in infra. Platform's `scripts/init/` is the live, newer copy | `ls scripts/init/server.py` → No such file; `git ls-files` confirms nesting | Delete from infra (the wizard lives in platform), OR `git mv` up one level if infra should own it — not both. Recommended: delete from infra, consistent with S1 | 6,898 |
| C4 | **platform duplicated scripts (~9,290 lines)**: 27 top-level pairs + 19 `deploy/` pairs. 10 byte-identical/cosmetic → delete now; 4 severe-drift (`deploy-local.sh` diff=453 — **platform's is NEWER**, `configure-platform.sh` diff=132, `generate-from-env.sh` diff=121, `sync-groups.sh` diff=115) → diff-merge into infra first, then delete | pair-by-pair diff table exists; precedent: the duplicate `bootstrap-openbao.sh` caused a 12-hour outage on 2026-08-06 and the fix committed in platform `deploy-local.sh:772-786` is exactly "delete the copy, call infra's" | Merge direction per file; platform wins on `deploy-local.sh` | 9,290 |
| C5 | Born-dead platform apps: `apps/infraweaver-cli` (1 commit ever, 0 external refs), `apps/terraform-provider-infraweaver` (28 KB, **no .go source at all**, 1 ref from `…/api/v1/workspaces/route.ts` — check it), `apps/wordpress-proof-runner` (1 commit, has a doc) | all three share the single commit `d54e95a3` 2026-08-01 and were never independently touched | Ask the operator: delete cli + terraform-provider; keep proof-runner if `docs/wordpress-proof-run.md` is a real runbook | ~200 files |
| C6 | `kubernetes/apps/example-app/` — a Bitnami nginx demo running in production as the **sole product** of the 161-line `applicationset-root.yaml` | `find kubernetes/{catalog,apps} -name application.yaml` → 1 match | Delete the demo AND `applicationset-root.yaml` together (an appset with a zero-match glob is another cascade trap), or keep both deliberately. Removal deletes a live nginx + namespace `apps-example` — window item | ~190 |
| C7 | `docs/plans/mc-server-update.md` (60 KB, untracked) + `/home/runner` loose `NEXT-SESSION-*.md` / one-shot prompt files | untracked | archive to one `~/archive/` dir | — |

**Tier C total: ≈17,300 lines, of which ~16,200 are script duplication (C2–C4).**

### 2.4 What makes the console deletions safe

The console has real machinery for this — use it, don't fight it:

- `tests/unit/route-scope-manifest.test.ts` (AST census, `MAX_UNTRIAGED_ROUTE_HANDLERS=479`,
  anti-vacuity floors `EXPECTED_ROUTE_FILES_AT_LEAST=380`), `dashboard-route-sprawl.test.ts`,
  `proxy-credential-census.test.ts`, and ~6 more ratchets. **Every delete PR must lower
  the relevant baselines in the same commit** — the floors exist precisely so a deletion
  fails loudly instead of silently ratifying itself.
- ~58 tests hardcode literal file paths (two collisions with this plan are called out in
  B1 and A12). Run the full suite sharded (`--maxWorkers=1`; it OOMs otherwise) after
  each delete group.
- **Do NOT delete** (verified alive or dark-launched, listed to prevent an over-eager
  cleanup): `ChangesetReviewPanel`; the 12 `src/lib/objects/*.manifest.ts` files (read
  textually by `scripts/build-addon-registry.mjs:50`); `src/addons/*/pages/index.tsx`
  (dynamic-imported via the generated registry); the ~9,400 lines behind the 8
  `NEVER_DEFAULTED` flags in `src/lib/feature-defaults.ts:128` (dark-launched,
  operator-flippable via `/api/platform/features/[flag]`); the 32 catalog directories
  with `catalog.yaml` (the on-demand app store, not dead code); the 5 recent zero-caller
  operator runbook scripts (`agent-session.sh`, `authentik-restore-identity.sh`,
  `pvc-migrate-to-longhorn.sh`, `wp-trust-cloudflare-ips.sh`, `hypatia-host-setup.sh`).

---

## 3. SIMPLIFICATIONS — reduce concept count, name the survivor

| # | Two (or more) mechanisms | Survivor | What dies |
|---|---|---|---|
| S1 | **Two whole script trees** (infra/scripts vs platform/scripts, 15.5k duplicated lines, drifting both directions) | `InfraWeaver-infra/scripts` — ArgoCD watches infra; the 2026-08-06 OpenBao outage already established "delete the copy, call infra's" (platform `deploy-local.sh:785`) | platform's 46 duplicate scripts (C4), after merging the 4 newer-in-platform files back |
| S2 | **Two bootstrap generators** (`sync-groups.sh` — live, and `sync-catalog.sh` — orphaned and dangerous) | `sync-groups.sh`, with the H1 commit fix; the four `catalog-infraweaver-*.yaml` become honestly hand-maintained | `sync-catalog.sh` and its false "do not edit" headers (C2) |
| S3 | **Five console data-fetch layers** (`useApiQuery`/`useApiMutation` 384+192 refs; raw `useQuery`/`useMutation` 129+97; raw `fetch()` 381 sites, 117 in client components; `fetchJson` 196; direct `apiClient` 59) | `useApiQuery`/`useApiMutation` — it already composes react-query + apiClient + the error taxonomy | The other four, hub-by-hub (§5 Stage 2); `fetch-json.ts`'s second error class merges into `api-client` |
| S4 | **Three homes for a console component** (`src/components/<domain>/`, `app/(dashboard)/<domain>/_components/`, `src/addons/*/components/`) | Rule: addon-owned → in the addon; page-private → `_components`; genuinely shared → `src/components`. Write it in `AGENTS.md` | The `game-hub` shim layer (B2/B3); `features/` (B8); merge the duplicate `posture-panel` and `drift-panel` pairs |
| S5 | **Six storage concepts** (`local-path`, `local-path-retain`, `longhorn`, `longhorn-retain`, `longhorn-game`, `""`/NAS) | `longhorn`(+`-retain`) for anything that must survive a node; `local-path-retain` only for explicitly-annotated node-cache data with its own dump/archive CronJob | New local-path claims (H7 gate); the remaining 13 pinned PVCs migrate per §5 Stage 3 |
| S6 | **Six hand-copied Kyverno exclude lists** (three policies are missing 5 namespaces the others have — `cluster-policies.yaml:310-319` vs `:112-134`) | One canonical list (YAML anchor in one file, or a CI byte-identity check across policies) | Five divergent copies |
| S7 | **21 kubeconfigs** in `~/.kube` + per-command `--server` overrides | ONE kubeconfig with all three control-plane endpoints in a cluster entry (the serving cert covers all CP IPs — verified during the incident), selected by `~/.bashrc` | 20 stale variants (A15) |
| S8 | **Twelve validate/preflight scripts with overlapping checks** | `validate-iac.sh` as the single pre-merge gate (absorbs B5); `test-post-deploy.sh` as the single post-deploy gate (absorbs B6's one useful block); `fabric-preflight.sh` stays as the one node-ops preflight | 4 scripts, 2 dangling Makefile targets |
| S9 | **Five copies of the same 6-name alert regex** in `cronjob-health.yaml:257-338` (and the same list 4 more times elsewhere in the file) | One Prometheus **recording rule** (`platform:backup_cronjobs:matched`) that the alert rules reference | 8 copies of the alternation |
| S10 | **Two etcd snapshot mechanisms** (designed-but-uninstalled `/usr/local/sbin` + shadow `/home/runner/bin/etcd-snapshot.sh` with a 1 MiB "integrity check" and a typo'd node IP) | ONE, in git, with real verification (H5) | the shadow script's silent weaknesses |

---

## 4. MAKE IT HARD TO BREAK — each item names the failure it would have prevented

Each item: change → prevents → verify → rollback.

**H1. `sync-groups.sh` stages only what it generated.**
Replace `git add -A` (`scripts/sync-groups.sh:494`) with `git add -- "${changed_files[@]}"`
(the Python block already accumulates the exact list in `.sync-groups-changed`), and drop
`[skip ci]` from the commit message so the generated commit is validated like any other.
*Prevents:* the measured near-miss where a run would have pruned `minio-velero` (the S3
backend of every Velero backup) from unrelated `platform.yaml` drift; the 2026-06
commits that swept `generated/kubeconfig` and `.redeploy-backup-*/users.yaml` into git
(7 such commits exist).
*Verify:* run `--dry-run`, then a real run with a deliberately dirty unrelated file;
the commit must contain only generator outputs.
*Rollback:* revert the one-line change.

**H2. KubePrism for every self-hosting apiserver client.**
Cilium is done (`kubernetes/core/cilium/values.yaml:44-45`, deployed and verified live
as `localhost 7445`). Two remaining instances of the same cycle:
(a) `kubernetes/core/kyverno/manifests/metallb-speaker-wait-policy.yaml:62-63` — an
**unbounded** `until nc -z "${KUBERNETES_SERVICE_HOST}" …` init loop on the ClusterIP
Cilium programs. Point it at `localhost:7445` (the agent manifests at
`platform/agent/manifests/rbac.yaml:137` already model the needed egress) or give the
loop a deadline and non-zero exit.
(b) `docs/CILIUM-HUBBLE-MIGRATION-RUNBOOK.md:91-92` still instructs
`k8sServiceHost: 10.0.0.90` (cp1's IP — the suspect node). Correct to
`localhost`/`7445` in the same commit.
*Prevents:* the exact deadlock class that made every new pod cluster-wide fail to start
on 2026-08-18 — next time via MetalLB instead of Cilium, or reintroduced by an operator
following the stale runbook.
*Verify:* delete one metallb-speaker pod; it must start with the apiserver briefly
unreachable via ClusterIP (or at minimum: the rendered policy shows the new host, and
the NetworkPolicy allows 7445).
*Rollback:* revert; the old behavior is the status quo.

**H3. Operator access that survives one node.**
One kubeconfig listing all three CP endpoints (S7); `~/.bashrc` points at it; the
**fallback** kubeconfig (`~/.kube/config-fallback:5` → `10.0.0.90`, cp1, the suspect
node) is replaced by the same multi-endpoint file. Fix the copy-paste onboarding
command in `kubernetes/core/rbac/README.md:78` and re-order
`docs/BACKUP-AND-RESTORE-RUNBOOK.md` so no recovery sequence starts with
`talosctl -n 10.0.0.90` (8 occurrences; the DR runbook's first restore command
currently targets the node whose WAL corrupted).
*Prevents:* the measured "rebooting cp1 blinds every kubectl call in this session";
an operator reaching for the fallback mid-incident and landing on the broken node.
*Verify:* `kubectl config view` shows 3 endpoints; with cp3 temporarily unreachable
(next maintenance window) kubectl still answers.
*Rollback:* keep the archived tarball of old kubeconfigs (A15) for 90 days.

**H4. A detached-kubelet / phantom-apiserver alarm.**
Two new alert rules in `kubernetes/monitoring/alerts/`:
(a) node-lease freshness — page when any `kube-node-lease` renewTime is stale
> 2 min while the node object still reports Ready (`kube_lease_renew_time` via
kube-state-metrics; if the metric is absent, add it to the self-check per H6's
pattern first);
(b) an etcd RAFT-divergence check in the host-side snapshot script (H5): compare
`talosctl -n <each> etcd status` RAFT INDEX across members; two matching and one tiny
divergent one is the phantom signature — alert via the existing dispatch path.
*Prevents:* the two-hour window where the phantom looked harmless; `kubectl get nodes`
lied Ready throughout, and the decisive evidence (frozen leases) had to be found by
hand.
*Verify:* promtool test for (a); for (b) run the script against the healthy cluster
(3 matching indexes) and confirm silence.
*Rollback:* remove the rules; `app-monitoring-alerts.yaml` has `prune: false`, so
delete the live PrometheusRule explicitly on rollback (the repo's known gotcha).

**H5. One real etcd + machine-config backup chain.**
Adopt the snapshot job into git (`kubernetes/core/etcd-maintenance/` already documents
the designed version): gzip + sha256 + **`etcdutl snapshot status`** verification +
off-box push (the NFS export `10.1.0.135:/mnt/pool/k8s-longhorn-backups` is writable
and needs no CSI — proven during the restore) + `talosctl get mc -o yaml` for all
three nodes in the same run. Delete the shadow `/home/runner/bin/etcd-snapshot.sh`
(1 MiB size gate, typo'd node `10.0.0.93`, plaintext secrets in a home dir) once the
replacement has produced 3 verified snapshots. Ship the `etcd-snapshot-verifier`
CronJob whose name is already wired into **10** alert selectors matching nothing.
Keep it host-side (`talosctl` needs os:admin; mounting that into a pod recreates the
2026-08-15 escalation) — "in git" means the script and its cron line are committed and
the verifier CronJob checks artifact freshness from inside the cluster.
*Prevents:* the existential edge of 2026-08-18 — cp1's etcd was wiped with **no
snapshot of any kind existing**; and a restore that would have failed anyway for want
of machine configs (`params/` is gitignored; configs existed only on this host).
*Verify:* `etcdutl snapshot status` on the produced artifact; verifier goes green;
delete one snapshot and confirm the verifier notices.
*Rollback:* the shadow script stays until 3 verified runs; re-enable its crontab line.

**H6. Alerts must prove their inputs exist — finish the self-check.**
`alert-pipeline-selfcheck.yaml` already guards most dead families; add the one it
misses: `ExternalSecretNotSynced` (`externalsecret_status_condition` has zero series —
every credential path runs through ESO and its alert can never fire). Fix
`LonghornVolumesDegraded` (`manifests/prometheus-rules.yaml:103`) which references a
`robustness` **label that does not exist** on a numeric gauge — the sibling at `:220`
does it right; delete the broken one. Fix the `for:`/annotation mismatch left by
commit `d857698`: `ConsoleAutomationCronJobNeverSucceeded` still at 26h
(`manifests/prometheus-rules.yaml:464`) while its cronjob-health twins moved to 8d —
and both files' annotations now describe the wrong number. Add promtool test files for
the 6 untested rule files (CI already runs promtool; it just has nothing to chew on
for them).
*Prevents:* the "documented compensating control is itself dead" pattern measured
today (etcd alerts, cert-manager alerts, ArgoCD alerts all keyed on absent metrics).
*Verify:* promtool tests pass; deliberately scale ESO down in a window and watch the
new absent-input alert fire.
*Rollback:* revert; rules are additive.

**H7. Name-lists get expiry dates; storage gets a gate.**
(a) Every namespace/name exclusion added to alerts or Velero schedules carries a
comment line `# excluded: <reason> — review-by: <date>`, and `validate-iac.sh` gains a
gate that fails when a review-by date is past. Seed it with today's known ones:
`nextcloud|jellyfin` in `cronjob-health.yaml:169,177` and the suspended backup
CronJobs (`catalog/nextcloud/manifests/pg-backup.yaml:94`, `data-archive.yaml:117`) —
**nextcloud's 110Gi currently has zero backup and zero alert, by design, forever**.
(b) `validate-iac.sh` gains a second gate: any *new* PVC with
`storageClassName: local-path*` fails CI unless annotated
`infraweaver.io/pinned-storage-accepted: "<reason>"`.
*Prevents:* (a) the rot that put `falco` in 9 lists and nearly hid nextcloud's
unprotected state permanently; (b) quiet growth of the node-pinned estate that made
cp1's failure a data-risk event.
*Verify:* CI fails on a fixture with an expired date / an unannotated local-path PVC.
*Rollback:* remove the gates from `validate-iac.sh`.

**H8. Backup truth: delete what lies, verify per volume, watch the target.**
(a) Delete the `weekly-localpath` Velero schedule and strip
`defaultVolumesToFsBackup: true` from `daily-wordpress`/`daily-gamehub`
(`platform/velero/values.yaml:279-370`) — measured: **0 PodVolumeBackups, 0 bytes,
phase Completed**; the values file itself documents that fs-backup cannot see hostPath.
Keep `daily-objects` (the one schedule that does what it claims). Honest coverage for
local-path data is the existing dump/archive CronJob pattern (§4 H7 unsuspends
nextcloud's or accepts the gap with an expiry).
(b) Make `longhorn-backup-verifier` (`core/longhorn/manifests/automation-jobs.yaml:117-145`)
report **per-volume**: verify all 41, exit non-zero listing the failures, instead of
`SystemExit(1)` on the first empty record — one stale `BackupVolume` disabled the
entire nightly verification for 4 days (measured).
(c) Add a backup-target reachability probe (the 2026-08-16 MinIO fill and the earlier
54-day NFS-blocked-by-netpol outage were both invisible until a human looked); fix the
five stale "20Gi" references in `velero/README.md` vs the real 50Gi PVC.
*Prevents:* every member of today's "reports success, protects nothing" list.
*Verify:* (a) next scheduled run produces no PVBs *and no schedule claims it does*;
(b) seed a fake empty BackupVolume in a window — verifier must report exactly one
failure and still verify the other 40; (c) block the NFS route in a window — alert
fires.
*Rollback:* all three are additive or delete-of-dead; revert restores the status quo.

**H9. A permanent dead-code gate for the console.**
Configure the already-installed `dependency-cruiser` (or add `knip`) with the §2.4
exceptions (codegen-read manifests, registry dynamic imports, Next.js entrypoints) and
wire it into `console-quality.yml`. Codify the 800-line file rule in `AGENTS.md` with
a ratchet test seeded at the current count (68 violators), in the house style of
`route-scope-manifest.test.ts` — floor + only-ever-lower.
*Prevents:* re-accumulation; this plan's A12 list took a full-tree scan to find
because no tool was watching.
*Verify:* CI fails on a deliberately-orphaned fixture file.
*Rollback:* remove the CI step.

**H10. Git state legibility.**
Add to `validate-iac.sh` (local mode only): warn when `HEAD` is not an ancestor of the
remote branch ArgoCD tracks, **after a fresh `git fetch`**; and warn when the working
tree is dirty at the end of a session. Rename the working branch back to `main`
tracking — a local branch named `deploy-safe` with a stale `origin/main` ref cost this
very audit an hour of false "the fixes are not deployed", and the 2026-08-12 session
shipped nothing while every gate passed because 45 files sat uncommitted.
*Prevents:* both measured shapes of "git says one thing, cluster runs another".
*Verify:* run with a stale ref — the check must fetch and then pass.
*Rollback:* remove the check.

**H11. Per-workload truth probes on the `world-health.yaml` model.**
The GTNH probe (`kubernetes/catalog/game-hub/manifests/world-health.yaml`) is the
house pattern: real service request + newest-artifact integrity + disk headroom, all
read-only, riding the existing `CronJobLastRunFailed` alert. Clone it for, in order of
irreplaceability: **vaultwarden** (a password store whose only health signal is "port
open"), the **WordPress site fleet** (probes are `tcpSocket:80` by design — the
authoritative check is `wp --allow-root option get siteurl` in-pod, already known),
**nextcloud** (110Gi), **zot** (20Gi registry, no backup), the **infraweaver-backup
datastore** (prove the newest artifact per site is readable, not that Node listens).
*Prevents:* "Running 1/1 while serving nobody for 78 minutes" — measured on GTNH,
structurally possible today on every workload listed.
*Verify:* each probe must fail when pointed at a deliberately-broken fixture (e.g.,
truncated artifact) and pass live.
*Rollback:* delete the CronJob; nothing depends on it.

**H12. WordPress pods must survive a restart without github.com.**
Every site's init container downloads `wp-cli-2.11.0.phar` from github.com while
`airgap-baseline` denies that egress — every WordPress pod is one restart away from
`Init:0/1` (measured during the incident). Bake the phar into the WordPress image (it
is version-pinned already) or mirror it in zot.
*Prevents:* the measured stuck-on-restart trap that turned a node reboot into a
WordPress outage.
*Verify:* delete one site pod in a window; it must reach Ready with no github.com
egress attempt in Hubble/cilium flow logs.
*Rollback:* the image change is additive; previous images remain in zot.

---

## 5. STAGING ORDER

### Stage 0 — this week, zero cluster risk (repo/host only, individually revertible)

Order within the stage is free except where noted. One commit (or PR) per lettered
group; never combine groups in one commit.

1. **H1** (sync-groups staged-commit fix) — do this FIRST; it de-fangs the tool every
   later platform.yaml edit will trigger.
2. **C2** decision + disarm: delete `sync-catalog.sh` (or at minimum
   `chmod -x` + a header refusing to run) before any other bootstrap work; remove the
   false "do not edit" headers from the four `catalog-infraweaver-*.yaml`.
3. A1, A2, A3, A4, A16 (dead scripts, host cruft) · A5, A6 (phantom entries) ·
   A7–A11 (dead manifest dirs + stale list names) · A14, A15 (untracked residue,
   kubeconfig archive) · C7 (loose docs).
4. H10 (git legibility check), H3's doc fixes (runbook endpoint corrections — text
   only), H2(b) (runbook correction).
5. A12/A13 + B1–B4, B7, B8 (console deletions; each group runs the sharded jest suite
   + `tsc --noEmit`; lower ratchet baselines in the same commit).
6. B5, B6 (validator merge), H7's gate additions to `validate-iac.sh`.

Gate for the whole stage: `validate-iac.sh` green, pre-push hook green, console
`tsc --noEmit` + sharded jest green, `kubectl get applications` diff shows **no app
changed sync state** (Stage 0 must be invisible to ArgoCD except deletions of
never-rendered files).

### Stage 1 — repo-only but ArgoCD-visible (CI-gated, watch the sync wave)

1. H6 (alert-rule fixes + tests), H4(a) (lease alert), S9 (recording rule) — alerts
   are additive; `prune: false` on the alerts app means deletions must be mirrored
   with an explicit live delete, noted per commit.
2. H8(a) (delete lying Velero schedules), H8(c) (target probe + doc fix).
3. H5 (etcd chain in git; shadow script retired after 3 verified runs).
4. S6 (Kyverno exclude-list unification — content-identical result; verify with a
   rendered diff that the effective policy is unchanged), A11 already removed the rot.
5. C4/S1 (platform script-tree deletion, after the 4 diff-merges; platform CI must
   stay green — its own callers are `Makefile` and docs, both updated in the PR).
6. C3 (infra `init/init` tree).

### Stage 2 — cluster-affecting, maintenance window each

- C1 (terraform tier-generator narrowing; `tofu plan` must show exactly the 7 app
  deletions + no namespace deletions — the minted `bootstrap`/`crds` namespaces must
  be adopted by explicit manifests first).
- C6 (example-app + root appset decision).
- H2(a) (metallb wait-policy change; roll one speaker to prove it).
- H8(b) (verifier per-volume rewrite; run a manual verification pass same-day).
- H11 probes (one workload per day, not per window — they are read-only, but each
  needs its fixture test).
- H12 (WordPress image change; one site first, then fleet).
- H4(b) (RAFT-divergence check added to the H5 script).

### Stage 3 — data migrations (one per window, NEVER two)

Per-workload local-path → Longhorn migration for the remaining pinned estate
(13 PVCs: nextcloud 110Gi, GTNH 30Gi, zot 20Gi, jellyfin 5Gi, 8 WordPress volumes),
using the repaired `pvc-migrate-to-longhorn.sh` — its ArgoCD-suspension bug
(selfHeal re-scaling the workload mid-migration, deadlocking the PVC in Terminating)
was fixed in commit `4736859` but has NOT been re-tested since the failure; rehearse
on the smallest volume (jellyfin 5Gi) first. The recovery pattern for a half-migrated
PVC is documented in the 08-18 memory (claimRef removal on the retained PV).
Decision inputs: cp1 is suspect hardware (do not migrate *onto* it), cp3 has 98 GiB
ephemeral total (watch DiskPressure), zot may be acceptable as rebuild-from-source
(then it needs the H7 annotation instead of a migration).

### Never batch together

- Any two of: appset regeneration (`sync-groups.sh`), `platform.yaml` flag flips,
  bootstrap file renames. (The tool auto-commits; the near-miss that almost deleted
  MinIO was exactly this combination.)
- A storage migration with anything else in the same window.
- A Kyverno selector widening with its exclude-list edit in separate commits — they
  must land atomically or not at all (the three narrow policies are missing 5
  namespaces the wide ones have; widening first = instant enforcement gap).
- `next build` with any parallel agent fan-out on this host (6 GB RAM; the 08-16 crash
  was exactly this).
- An `ignoreDifferences` experiment with anything time-sensitive: it can only be
  tested through git — the appset controller reverts live patches in ~20s.

---

## 6. Verification & rollback — global notes

Per-item verify/rollback is embedded above. Cross-cutting:

- **Everything in Stages 0–1 is a git revert away.** Single-concern commits are the
  rollback mechanism; that is why the batching rules exist.
- **ArgoCD caveats that bite rollbacks:** `app-monitoring-alerts.yaml` and
  `core-psa-manifests` have `prune: false` (deleting a rule file does NOT delete the
  live object — every alert-file deletion needs a paired explicit live delete, listed
  in the commit message); selfHeal reverts any live experiment in ~20s (test through
  git only); `resources-finalizer` on appsets means deleting an ApplicationSet
  cascades (C1/C6 are windowed for this reason).
- **The console ratchets are the safety net, not an obstacle:** every delete commit
  lowers its baselines; a delete that *raises* pressure on any ratchet is wrong by
  definition.
- **Shortname trap when verifying backups:** `kubectl get backup` resolves to
  `backups.longhorn.io`. Always write `backups.velero.io` in verification commands.

---

## 7. ANTI-GOALS — what this plan deliberately does NOT propose

1. **No console rewrite.** 570k lines with 5 fetch layers invites "rebuild it on X".
   Rejected: the failure evidence is in infra, not the console's architecture; S3 is a
   convergence, executed hub-by-hub, deletable at any point.
2. **No merging the two repos.** The private-infra / platform split is load-bearing
   (ArgoCD watches infra exclusively; the public sanitizer strips secrets). S1 removes
   the *duplication*, not the boundary.
3. **No replacement for `sync-groups.sh`.** Its logic is sound and battle-annotated
   (the 2026-06-30 outage comment). Only its commit behavior changes (H1). Writing a
   new generator is how the last two generators happened.
4. **No mass file-splitting project for the 68 over-800-line files.** Splitting
   `server-detail.tsx` (3,631 lines) is real work with real regression risk and zero
   stability payoff. The rule gets a ratchet (H9); files split opportunistically when
   touched.
5. **No deleting dark-launched features** (~9,400 lines behind `NEVER_DEFAULTED`
   flags) or the 32-app catalog registry — off-by-default is not dead; both are
   operator-facing capability.
6. **No storage-technology change.** Longhorn stays; the NAS stays; the plan
   consolidates *onto* the existing survivors (S5), it does not evaluate Ceph.
7. **No new CI system, no new tooling platform.** Every gate lands inside the existing
   `validate-iac.sh` / pre-push / promtool / jest-ratchet machinery.
8. **No touching compliance docs beyond stale-markers** — they are audit evidence;
   `asset-inventory.md` gets regenerated, not edited.
9. **No cluster-topology changes** (cp1 hardware replacement, VIP for the control
   plane, adding a worker) — flagged as context (cp1 corrupts images; the endpoint is
   a single IP inside machine configs) but they are hardware/ops decisions for the
   operator, not cleanup. The plan's H3 mitigates the operator-side blindness cheaply.
10. **No "fixing" the deliberately-parked** (tradesphere shape, nextcloud/jellyfin at
    0 replicas): parking is a valid state; H7 only makes its coverage-gap visible and
    dated instead of silent and eternal.

---

## 8. RANKING — (impact on stability × certainty) ÷ risk

Impact 1–5, certainty 0–1 (how sure the evidence is), risk 1–5 (blast radius of doing
it). Score = I×C/R. Top 15:

| Rank | Item | I | C | R | Score |
|---|---|---|---|---|---|
| 1 | H1 sync-groups stages only its own outputs | 5 | 1.0 | 1 | 5.0 |
| 2 | C2 disarm/delete `sync-catalog.sh` (armed to delete 7 live apps) | 5 | 0.9 | 1 | 4.5 |
| 3 | H6+H4a alert-input self-checks + lease alert + **Kyverno availability alert** (failurePolicy:Ignore means one deleted Deployment silently disarms all 9 Enforce policies today) | 4 | 1.0 | 1 | 4.0 |
| 4 | C3 delete the unreachable 6,898-line `scripts/init/init` tree | 3 | 1.0 | 1 | 3.0 |
| 5 | S7/H3 one multi-endpoint kubeconfig + runbook endpoint fixes | 3 | 1.0 | 1 | 3.0 |
| 6 | H8 backup truth (delete lying schedules, per-volume verifier, target probe) | 5 | 1.0 | 2 | 2.5 |
| 7 | H5 one verified etcd+machine-config chain | 5 | 0.9 | 2 | 2.25 |
| 8 | A1–A16 the zero-risk delete sweep (~5.7k lines + 392 MB) | 2 | 1.0 | 1 | 2.0 |
| 9 | A12/B1–B4 console dead files + shim layer (−1 concept) | 2 | 0.95 | 1 | 1.9 |
| 10 | C4/S1 platform script-tree deletion (~9.3k lines, ends bidirectional drift) | 4 | 0.9 | 2 | 1.8 |
| 11 | H2 metallb/runbook KubePrism (same deadlock class as the incident) | 4 | 0.9 | 2 | 1.8 |
| 12 | H11 truth probes (vaultwarden → WordPress → nextcloud → zot) | 4 | 0.8 | 2 | 1.6 |
| 13 | C1 narrow the terraform tier generator (7 zero-resource apps) | 3 | 0.9 | 2 | 1.35 |
| 14 | H12 WordPress wp-cli baked into image (removes the Init:0/1 restart trap) | 3 | 0.9 | 2 | 1.35 |
| 15 | Stage 3 local-path exit (13 pinned PVCs) | 5 | 0.9 | 4 | 1.13 |

(S3 fetch-layer convergence scores 0.8 — high effort, medium certainty of payoff — and
is therefore Stage 2+, hub-by-hub, abandonable.)

---

## 9. OPEN QUESTIONS — honest unknowns, with the command that settles each

- **OQ1** Do the minted `bootstrap`/`crds` namespaces carry anything beyond the
  policy-list references found? Settle before C1:
  `kubectl --server=https://10.0.0.92:6443 get all,cm,secret -n bootstrap; kubectl … -n crds`
- **OQ2** Does any human workflow still run `validate-cluster.sh` or `bootstrap-local.sh`
  before `tofu apply`? (0 grep callers, but manual use is invisible to grep.) Settle:
  ask the operator; `grep -rn "validate-cluster\|bootstrap-local" ~/.bash_history`
- **OQ3** What is `private-apps/` really (1.1 GB, 605 tracked files, **23,410 untracked**,
  tradesphere OutOfSync/Degraded)? Settle:
  `git -C /home/runner/InfraWeaver-infra status private-apps --short | head; du -sh private-apps/*/src`
  — likely candidate for git-ignoring the `src/` trees, not deleting.
- **OQ4** Does anything consume `apps/infraweaver-node` (1 commit in 60 days, and that
  was a sweep)? Settle: `grep -rn "infraweaver-node" kubernetes/bootstrap/` (a
  `catalog-infraweaver-node-manifests.yaml` exists — so YES it deploys; the question is
  whether the deployed service has traffic:
  `kubectl … logs -n <ns> deploy/infraweaver-node --since=168h | head`).
- **OQ5** After stripping fs-backup from `daily-wordpress`/`daily-gamehub` (H8a), do
  those schedules still add value over `daily-objects`? Settle:
  `kubectl … get podvolumebackups.velero.io -n velero | grep -c daily-wordpress` (today: 0)
  and diff the schedules' `includedResources`.
- **OQ6** Is the single `terraform-provider-infraweaver` reference in
  `src/app/api/v1/workspaces/route.ts` load-bearing or a doc-string? Settle:
  `grep -n "terraform-provider" apps/infraweaver-console/src/app/api/v1/workspaces/route.ts`
- **OQ7** The four "severe-drift" script pairs (C4): which side wins per hunk? Settle:
  `diff scripts/deploy-local.sh ../InfraWeaver-platform/scripts/deploy-local.sh` reviewed
  hunk-by-hunk (platform is newer on this one file; infra on the other three).
- **OQ8** Can Prometheus actually see `kube_lease_renew_time` for H4(a)? Settle:
  query the live Prometheus: `count(kube_lease_renew_time{namespace="kube-node-lease"})`
  — if 0, ship the kube-state-metrics `--metric-allowlist` addition first.
- **OQ9** `wordpress-proof-runner`: is `docs/wordpress-proof-run.md` an active runbook?
  Settle: ask the operator (write-once proof harnesses are legitimately quiet).

---

## Appendix: what today's incident would have looked like with this plan executed

- The phantom window (2h) → **minutes**: H4's lease alert fires at +2 min; the
  RAFT-divergence check names cp1 as a one-member cluster.
- The cluster-wide new-pod outage → **not cluster-wide**: Cilium already fixed (done);
  MetalLB no longer joins the deadlock (H2).
- The operator blindness during cp1's reboot → **none**: multi-endpoint kubeconfig (H3).
- The "restore from what?" question → **answered**: verified etcd snapshots +
  machine configs off-box (H5).
- The 19-workload restart sweep and the WordPress `Init:0/1` trap → **smaller**: H12
  removes the github.com dependency; H11's probes distinguish wedged from booting.
- The a-priori risk that a routine `sync-groups.sh` run deletes the backup backend →
  **gone** (H1), and the tool that would delete 7 live apps → **gone** (C2).
