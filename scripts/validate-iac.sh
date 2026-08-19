#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-iac.sh — Pre-merge IaC validation (run locally AND in CI).
#
# Mirrors how larger orgs gate GitOps changes: every change is validated the
# same way on a developer laptop and in the PR pipeline (single source of truth
# for "is this safe to merge"). Complements the focused validators
# (validate-eso-refs.sh, validate-platform-yaml.sh, validate-users-yaml.sh).
#
# Checks:
#   1. kustomize build — every overlays/*/ renders without error
#   2. kubeconform     — rendered manifests pass Kubernetes schema validation
#   3. secret-leak gate — no raw `kind: Secret` carrying a value is added
#                         (declarative refs via ExternalSecret/OpenBao only).
#                         Existing known offenders are baselined (ratchet): the
#                         gate blocks new leaks while we migrate the old ones.
#                         A write-me placeholder ("change-me") FAILS like any
#                         other value — under GitOps ArgoCD applies it and
#                         selfHeal re-asserts it, so it is the live credential,
#                         not a TODO. Narrow per-secret exemptions only, via
#                         PLACEHOLDER_EXEMPT below.
#   4. cron-secret seed gate — a secret key a workload names has to survive TWO
#                         hops, and this gate checks both:
#                           catalog.yaml `secrets.keys` → the value exists in OpenBao
#                           ExternalSecret `spec.data`  → it reaches the k8s Secret
#                         Miss the first and seed-catalog-secrets.sh never seeds it
#                         on a fresh install. Miss the second and ESO never puts it
#                         in the Secret at all — creationPolicy: Owner means no
#                         other writer exists. Either way the CronJob (and any
#                         Deployment sharing the key) fails to start, silently and
#                         forever; `optional: true` converts that into starting
#                         with the value EMPTY, which is quieter still.
#   5. alerting rules  — promtool check/test, plus a scan for duplicate
#                         alertnames and identical expressions across
#                         PrometheusRules.
#   6. armed-blueprint gate — the Authentik IP-reputation lockout may not be
#                         mounted while its own arming procedure still marks the
#                         Cloudflare X-Forwarded-For prerequisite outstanding.
#                         Armed early it is not a weak control, it is a remote
#                         DoS on login: any caller can pick a victim address. The
#                         warning and the mount shipped in the same commit once
#                         already, which is why this is a gate and not a comment.
#   7. duplicate-script gate — a script basename may not exist in BOTH this repo's
#                         scripts/ tree and InfraWeaver-platform's. See the long
#                         note at DUP_SCRIPT_* below; this is the gate that stops
#                         a deleted duplicate from being resurrected by the next
#                         blanket restore commit.
#
# ── A SKIPPED GATE IS NOT A PASSED GATE ──────────────────────────────────────
# Gates 1, 2 and 5 depend on tools (kubeconform, promtool) that a laptop may not
# have. Until 2026-08-19 they printed "not installed — skipping" and left FAILED
# untouched, so the script ended with "IaC validation PASSED" and exit 0 while
# promtool `check rules` and FIVE alert unit-test files had not run at all. That
# is why CI stayed red for four commits while every local run reported PASSED.
# Every such skip is now recorded in SKIPPED[], reprinted in the summary, and
# ends the run as INCOMPLETE with exit 1. Accept a partial run explicitly with
# IAC_ALLOW_SKIPPED_GATES=1 — it still refuses to print "PASSED".
#
# Usage: scripts/validate-iac.sh [--repo-root <path>]
#        scripts/validate-iac.sh --duplicate-scripts-only     # gate 7 alone (fast)
#        scripts/validate-iac.sh --refresh-platform-inventory # re-snapshot gate 7's input
# Exit non-zero on any failure OR any skipped gate (CI-friendly).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUP_ONLY=false
REFRESH_INVENTORY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)                 REPO_ROOT="$2"; shift 2 ;;
    --duplicate-scripts-only)    DUP_ONLY=true; shift ;;
    --refresh-platform-inventory) REFRESH_INVENTORY=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$REPO_ROOT" || exit 1

KUSTOMIZE=(kubectl kustomize)
# `-ignore-filename-pattern '/\.'` skips hidden directories. kubeconform is handed a
# manifests DIRECTORY and recurses, so editor/tooling caches such as
# `.impeccable/hook.cache.json` were being parsed as manifests and failing the gate
# with "missing 'kind' key". Nothing under a dot-directory is a Kubernetes manifest.
KUBECONFORM_FLAGS=(-strict -ignore-missing-schemas -summary -ignore-filename-pattern '/\.')
FAILED=0

# Gates that did not run because a tool was missing. Recorded, printed inline as
# "⚠ SKIPPED", reprinted in the summary, and fatal by default — see the header.
SKIPPED=()
note_skip() {  # note_skip "<gate> — <what did not run>" "<how to fix>"
  SKIPPED+=("$1 → $2")
  echo "  ⚠ SKIPPED — $1"
  echo "            fix: $2"
}

# Known pre-existing raw Secrets pending migration to ExternalSecret/OpenBao.
# DO NOT add to this list — fix the secret instead. Remove entries as migrated.
# Format: "<path>::<secret-name>"  (see docs/gitops-operating-model.md §Secrets)
# Empty: all previously-committed raw Secrets have been migrated to ExternalSecret
# (OpenBao) or inlined as non-sensitive config. Keep it empty — fix leaks, don't
# baseline them.
SECRET_BASELINE=()

# Secrets allowed to ship a WRITE-ME placeholder value ("change-me" and friends).
# Format: "<path>::<secret-name>". Intended for scaffolding a human must edit
# before it is ever applied — a template under kubernetes/catalog/_template/, not
# a manifest ArgoCD syncs.
#
# WHY THIS LIST IS NARROW AND WAS ONCE THE WHOLE RULE. Until now the gate treated
# "change-me" as a non-value everywhere, and that is exactly how two of them
# reached a live cluster: vaultwarden's ADMIN_TOKEN and bookstack's APP_KEY +
# DB_PASSWORD sat at "change-me" on apps whose own catalog.yaml said
# `installed_at: 2026-05-17`. Under GitOps a placeholder in a manifest ArgoCD
# applies is not a placeholder — it is the live credential, re-asserted by
# selfHeal every time somebody rotates it in-cluster. So the gate now FAILS on a
# placeholder by default and only an entry here excuses one, per file and per
# secret name, with a comment saying why. An EMPTY value is still not a
# credential and needs no entry.
PLACEHOLDER_EXEMPT=()

# ── Gate 7 configuration: duplicate ops scripts across the two repos ─────────
#
# WHY THIS GATE EXISTS. `scripts/sync-groups.sh` existed in BOTH this repo and
# InfraWeaver-platform. Platform's was a frozen 2026-06-14 snapshot and it was the
# copy on the LIVE deploy path (platform deploy-local.sh:704 →
# configure-platform.sh:435), running AFTER deploy-local.sh:210 rsyncs this repo's
# kubernetes/ tree into the platform checkout, with step 6 then applying
# kubernetes/bootstrap/*.yaml to the cluster. So the stale generator's output
# reached the live cluster on every local deploy: it emitted
# `repoURL: https://github.com/your-org/your-repo.git` — the trigger of the
# 2026-06-30 self-inflicted cascade-delete outage — and 0 of 11 Kyverno
# ignoreDifferences, and its `git add -A` swept unrelated files into an unreviewed
# auto-commit. The same duplication class cost 12 hours of OpenBao downtime on
# 2026-08-06 (two copies of bootstrap-openbao.sh holding different halves of one
# ACL, and `bao policy write` is a full REPLACE).
#
# Both were consolidated (infra d0064e5 / platform 2debaff8). Neither deletion
# stays deleted on its own: platform's copy of sync-groups.sh had ALREADY been
# resurrected once, by the blanket restore commit 3728d3f6. A comment cannot stop
# the next blanket restore. This gate can.
#
# HOW IT SEES A REPO CI DOES NOT CHECK OUT. CI runs `actions/checkout@v4` on this
# repo only, so a gate that compares against a live platform checkout would find
# none and skip — which is the exact bug this whole change is fixing. Instead the
# gate's input is a COMMITTED snapshot, scripts/platform-scripts.inventory, which
# is always present and always compared. When a platform checkout IS resolvable
# the gate additionally recomputes the list live and FAILS if the snapshot has
# drifted, so the snapshot cannot rot unnoticed on any machine that has both.
#
# RATCHET, like SECRET_BASELINE above. A pair listed in DUP_SCRIPT_BASELINE is
# tolerated; anything else FAILS. And an entry that is NO LONGER duplicated also
# FAILS ("stale entry — delete this line"), so the list can only shrink, and a
# basename removed from it can never come back quietly.

# Pairs that MUST exist in both repos. Each needs a reason. Keep this tiny.
DUP_SCRIPT_DELIBERATE=(
  # lib.sh — the shared bash shim (72 lines, no dependencies of its own). Every
  # script in both repos starts with `source "$(dirname "$0")/lib.sh"`, and
  # platform's deploy-local.sh:51 sources it as the CWD-relative "scripts/lib.sh".
  # Pointing those at a foreign checkout would make every platform script
  # unrunnable without an infra clone — strictly worse than one 72-line copy. The
  # two are kept BYTE-IDENTICAL (converged 2026-08-19); if they ever differ, that
  # is drift and this entry should be revisited, not widened.
  "lib.sh"
  # update.sh — each repo's own self-updater. It fetches THIS repo's remote and
  # rebuilds from `$(dirname "$0")/..`, so infra's copy updates infra and
  # platform's updates platform; they hardcode different GitHub URLs on purpose.
  # A single shared copy could not update the repo it does not live in.
  "update.sh"
)

# Known-outstanding duplicates that predate this gate. DO NOT ADD — de-duplicate
# instead. Format: "<basename>  # <why it is still here / what closes it>"
DUP_SCRIPT_BASELINE=(
  # ── The 3 severe-drift pairs. Merge direction decided per file first.
  #    NO DIFF SIZES ARE WRITTEN HERE ANY MORE. They used to be, and they rotted:
  #    this list said "diff 453" for deploy-local.sh and "~132" for
  #    configure-platform.sh while the measured values were 510 and 193. A number
  #    a human types beside a comment is a number nothing checks. The measured
  #    values now live in $PLATFORM_INVENTORY, are regenerated by
  #    --refresh-platform-inventory, and are ENFORCED by the divergence ratchet
  #    below.
  "deploy-local.sh"          # platform's is NEWER — the merge reverses; needs its own session (plan C4)
  "configure-platform.sh"    # itself a fork of infra's (plan C4)
  "generate-from-env.sh"     # infra's is NEWER (105-line Talos-fallback block) (plan C4)
  # ── setup.sh: CLOSED 2026-08-19 by renaming, which is what the entry always
  #    said the resolution had to be. infra's copy is now scripts/setup-env.sh
  #    (the .env first-run wizard named by the public README quick-start);
  #    platform's scripts/init/setup.sh is the unrelated init-VM installer entry
  #    point and keeps its name. They were never two copies of one script — they
  #    collided on a basename, which is all this gate can see.
  # ── get-kubeconfig.sh: CLOSED 2026-08-19 exactly as this entry specified.
  #    infra's copy gained a --repo-root override (fatal on a bad path) and
  #    platform's Makefile `kubeconfig` target now calls it through
  #    scripts/infra-repo.sh with --repo-root "$(CURDIR)" — because the tofu state
  #    and envs/<env>/generated/talosconfig live in the PLATFORM tree at deploy
  #    time, not in infra's.
  # ── restore-from-truenas.sh: CLOSED 2026-08-19. Platform's copy restored an
  #    extra `onedev-data` volume; "nothing runs it" is not "nothing needs
  #    restoring from it", so this was settled by measurement before deleting:
  #    no onedev namespace, no onedev PVC, no onedev Longhorn volume, and none of
  #    the 46 Longhorn BackupVolumes on the NAS resolves to onedev-data.
)

# Snapshot of InfraWeaver-platform's script inventory. Regenerate with
#   scripts/validate-iac.sh --refresh-platform-inventory
# on a machine that has both checkouts.
PLATFORM_INVENTORY="scripts/platform-scripts.inventory"

# Files counted as "a script" in either tree. Build output, caches and vendored
# trees are excluded by path so committed Next.js chunks under
# platform/scripts/init/out/ are not mistaken for ops scripts.
DUP_SCRIPT_EXT_RE='\.(sh|bash|py|mjs|cjs|js|ts|pl|rb)$'
DUP_SCRIPT_SKIP_RE='(^|/)(out|dist|build|node_modules|__pycache__|\.ruff_cache|\.impeccable|\.next|\.venv)/'

# ── DIVERGENCE RATCHET (added 2026-08-19) ────────────────────────────────────
# Until today this gate measured EXISTENCE only: a baselined pair could drift
# arbitrarily far and still pass. Both big pairs already had — the comment on
# deploy-local.sh said "diff 453" while the measured value was 512, and
# configure-platform.sh said "~132" against a measured 193. The numbers rotted in
# place precisely because nothing compared them to reality.
#
# Recorded values live in $PLATFORM_INVENTORY, not in this file, so the fix for a
# legitimate change is the SAME one-command workflow the path list already has:
#     scripts/validate-iac.sh --refresh-platform-inventory   (then commit)
# Hand-editing a number here would just recreate the rot.
#
# Contract, matching the baseline list's own ratchet: the recorded value must
# EQUAL the measured one. Growth is the defect this catches; a shrink that is not
# re-recorded is how growth later hides under a stale-high number. Either way the
# gate names the file and the command.
#
# DUP_SCRIPT_DELIBERATE pairs are recorded too, which is a new bite: lib.sh is
# documented as kept BYTE-IDENTICAL, and now a single drifting line fails.
# Measured on the COMMITTED content of both sides (git show HEAD:<path>), never on
# whatever happens to be in someone's working tree. Otherwise the recorded number
# would bake in one machine's uncommitted edits and drift for everyone else.
measure_pair_diff() {  # measure_pair_diff <infra-root> <platform-root> <basename>
  local a b
  a="$(git -C "$1" ls-files scripts 2>/dev/null | awk -F/ -v b="$3" '$NF==b{print; exit}')"
  b="$(git -C "$2" ls-files scripts 2>/dev/null | awk -F/ -v b="$3" '$NF==b{print; exit}')"
  [[ -n "$a" && -n "$b" ]] || return 1
  # `|| true` is load-bearing: diff exits 1 whenever the files DIFFER, and this
  # script runs under `set -o pipefail`, so without it every non-zero diff would
  # be reported as "not a pair" — the gate would then only ever measure the pairs
  # that are already identical, i.e. exactly the ones that need no ratchet.
  { diff <(git -C "$1" show "HEAD:$a" 2>/dev/null) \
         <(git -C "$2" show "HEAD:$b" 2>/dev/null) || true; } | wc -l | tr -d ' '
}

# Emit the script inventory of a repo checkout, one relative path per line, sorted.
# Uses `git ls-files`: a duplicate only "comes back" by being committed, and the
# snapshot must be comparable to the same thing on the other side.
dup_script_list() {  # dup_script_list <repo-root>
  git -C "$1" ls-files scripts 2>/dev/null \
    | grep -Ev "$DUP_SCRIPT_SKIP_RE" \
    | grep -E "$DUP_SCRIPT_EXT_RE" \
    | LC_ALL=C sort
}

# First resolvable InfraWeaver-platform checkout, or empty. Same resolver chain as
# platform's configure-platform.sh uses for this repo, inverted.
resolve_platform_repo() {
  local c
  for c in "${INFRAWEAVER_PLATFORM_REPO:-}" "${PLATFORM_DIR:-}" \
           "$REPO_ROOT/../InfraWeaver-platform" "$HOME/InfraWeaver-platform" \
           "/opt/InfraWeaver-platform"; do
    [[ -n "$c" && -d "$c/.git" && -d "$c/scripts" ]] || continue
    (cd "$c" && pwd); return 0
  done
  return 1
}

write_platform_inventory() {  # write_platform_inventory <platform-root>
  local p="$1"
  {
    echo "# InfraWeaver-platform script inventory — INPUT TO scripts/validate-iac.sh GATE 7."
    echo "#"
    echo "# One git-tracked script path per line, relative to the platform repo root."
    echo "# This file exists because CI checks out THIS repo only: without it the"
    echo "# duplicate-script gate would find no platform tree and skip, which is the"
    echo "# failure mode it was written to prevent. Do not hand-edit — regenerate with"
    echo "#     scripts/validate-iac.sh --refresh-platform-inventory"
    echo "# on a machine that has both checkouts. The gate FAILS if a live platform"
    echo "# checkout is present and disagrees with this snapshot."
    echo "#"
    echo "# source:    InfraWeaver-platform $(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo '<unknown>')"
    echo "# committed: $(git -C "$p" log -1 --format=%cI 2>/dev/null || echo '<unknown>')"
    echo "# snapshot:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "#"
    echo "# ── RECORDED DIVERGENCE, 'diff <infra copy> <platform copy> | wc -l' ────────"
    echo "# One line per allowlisted pair. The gate FAILS when the measured value"
    echo "# differs from the value recorded here, so a pair cannot quietly drift"
    echo "# further apart (and a shrink cannot go unrecorded, which is how a"
    echo "# stale-high number would later hide a regrowth). Regenerate with"
    echo "#     scripts/validate-iac.sh --refresh-platform-inventory"
    local _b _d
    for _b in "${DUP_SCRIPT_DELIBERATE[@]}" "${DUP_SCRIPT_BASELINE[@]}"; do
      if _d="$(measure_pair_diff "$REPO_ROOT" "$p" "$_b")"; then
        echo "# diff: $_b $_d"
      else
        echo "# diff: $_b none   # not a pair in this checkout"
      fi
    done
    echo "#"
    dup_script_list "$p"
  } > "$PLATFORM_INVENTORY"
}

# ── Gate 7 body (also runnable alone via --duplicate-scripts-only) ───────────
gate_duplicate_scripts() {
  echo "── 7/7 duplicate-script gate (infra scripts/ vs InfraWeaver-platform scripts/) ─"

  if [[ ! -f "$PLATFORM_INVENTORY" ]]; then
    echo "  ✗ $PLATFORM_INVENTORY is missing — this gate is not guarding anything."
    echo "      Regenerate it:  scripts/validate-iac.sh --refresh-platform-inventory"
    FAILED=1; return
  fi

  local plat_repo="" mode
  plat_repo="$(resolve_platform_repo || true)"

  local snap_list live_list
  snap_list="$(grep -v '^[[:space:]]*#' "$PLATFORM_INVENTORY" | grep -v '^[[:space:]]*$' | LC_ALL=C sort)"
  if [[ -z "$snap_list" ]]; then
    echo "  ✗ $PLATFORM_INVENTORY contains no entries — an empty inventory cannot fail,"
    echo "      which makes this gate a no-op. Regenerate it:"
    echo "      scripts/validate-iac.sh --refresh-platform-inventory"
    FAILED=1; return
  fi

  # Staleness is recorded, NOT returned on. A resurrected duplicate makes the
  # snapshot stale too, and "refresh the inventory" would be the wrong headline
  # for "you just re-added sync-groups.sh". Duplicates are reported first, below.
  local stale_inventory=false
  if [[ -n "$plat_repo" ]]; then
    mode="live checkout $plat_repo @ $(git -C "$plat_repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
    live_list="$(dup_script_list "$plat_repo")"
    [[ "$live_list" != "$snap_list" ]] && stale_inventory=true
  else
    mode="committed snapshot ($(grep -m1 '^# source:' "$PLATFORM_INVENTORY" | sed 's/^# source:[[:space:]]*//'), taken $(grep -m1 '^# snapshot:' "$PLATFORM_INVENTORY" | sed 's/^# snapshot:[[:space:]]*//'))"
    echo "  · no InfraWeaver-platform checkout found (tried \$INFRAWEAVER_PLATFORM_REPO,"
    echo "    \$PLATFORM_DIR, ../InfraWeaver-platform, \$HOME/InfraWeaver-platform,"
    echo "    /opt/InfraWeaver-platform) — this gate still RUNS, against the snapshot."
    live_list="$snap_list"
  fi
  echo "  · comparing against: $mode"

  local infra_list
  infra_list="$(dup_script_list "$REPO_ROOT")"
  if [[ -z "$infra_list" ]]; then
    echo "  ✗ no scripts found in this repo's scripts/ tree — the comparison is empty,"
    echo "      so this gate cannot fail. Is git available and is $REPO_ROOT a checkout?"
    FAILED=1; return
  fi

  # basename → path, for both sides (first path wins; the message names one).
  local dupes
  dupes="$(LC_ALL=C comm -12 \
    <(echo "$infra_list" | sed 's#.*/##' | LC_ALL=C sort -u) \
    <(echo "$live_list"  | sed 's#.*/##' | LC_ALL=C sort -u))"

  local allowed=() b p_infra p_plat new_dupes=() stale=()
  allowed=("${DUP_SCRIPT_DELIBERATE[@]}" "${DUP_SCRIPT_BASELINE[@]}")

  while read -r b; do
    [[ -n "$b" ]] || continue
    printf '%s\n' "${allowed[@]}" | grep -qxF "$b" || new_dupes+=("$b")
  done <<< "$dupes"

  # Ratchet: an allowlisted pair that is no longer a pair must leave the list,
  # otherwise deleting a duplicate silently re-authorises its resurrection.
  for b in "${allowed[@]}"; do
    grep -qxF "$b" <<< "$dupes" || stale+=("$b")
  done

  if (( ${#new_dupes[@]} > 0 )); then
    echo ""
    echo "  ✗✗✗ DUPLICATED OPS SCRIPT — ${#new_dupes[@]} basename(s) exist in BOTH repos ✗✗✗"
    echo ""
    for b in "${new_dupes[@]}"; do
      p_infra="$(echo "$infra_list" | grep -m1 "/$b\$")"
      p_plat="$(echo "$live_list"  | grep -m1 "/$b\$")"
      echo "      $b"
      echo "        infra:    $p_infra"
      echo "        platform: $p_plat"
    done
    echo ""
    echo "      Two copies of an ops script is this platform's most expensive recurring"
    echo "      defect. sync-groups.sh: platform's frozen 2026-06-14 fork sat on the LIVE"
    echo "      deploy path and applied 'repoURL: https://github.com/your-org/your-repo.git'"
    echo "      to the cluster — the 2026-06-30 cascade-delete outage — plus 0 of 11 Kyverno"
    echo "      ignoreDifferences. bootstrap-openbao.sh: two copies held different halves of"
    echo "      one OpenBao ACL and 'bao policy write' is a full REPLACE → 12 hours of"
    echo "      Degraded apps on 2026-08-06. Both copies looked fine in isolation."
    echo ""
    echo "      WHAT TO DO — pick ONE surviving copy, delete the other, and point the"
    echo "      caller at the survivor. The established pattern is platform"
    echo "      configure-platform.sh:435 and deploy-local.sh:774-790: resolve an infra"
    echo "      checkout, die loudly with a 'do NOT copy it back' message if absent, and"
    echo "      invoke the one real script. Do NOT re-add the copy."
    echo ""
    echo "      If a pair genuinely must exist twice, add it to DUP_SCRIPT_DELIBERATE in"
    echo "      $(basename "${BASH_SOURCE[0]}") WITH the reason. DUP_SCRIPT_BASELINE is"
    echo "      closed — it may only shrink."
    FAILED=1
  fi

  if (( ${#stale[@]} > 0 )); then
    echo ""
    echo "  ✗ ${#stale[@]} allowlist entr(y|ies) name a pair that is NO LONGER duplicated:"
    printf '      %s\n' "${stale[@]}"
    echo "      Delete those lines from DUP_SCRIPT_DELIBERATE / DUP_SCRIPT_BASELINE in"
    echo "      $(basename "${BASH_SOURCE[0]}"). Leaving them there would silently"
    echo "      re-authorise the duplicate the moment someone restores it."
    FAILED=1
  fi

  if $stale_inventory; then
    echo ""
    echo "  ✗ $PLATFORM_INVENTORY is STALE — the live platform checkout disagrees with it."
    echo "      The snapshot is this gate's ONLY input in CI, which checks out no platform"
    echo "      tree; letting it rot is how the gate would go blind. Refresh and commit:"
    echo "        scripts/validate-iac.sh --refresh-platform-inventory"
    echo "      Drift ( -snapshot / +live ):"
    diff <(echo "$snap_list") <(echo "$live_list") | grep -E '^[<>]' | sed 's/^</      -/; s/^>/      +/'
    FAILED=1
  fi

  # ── Divergence ratchet ─────────────────────────────────────────────────────
  local _b recorded measured drift=() unrecorded=()
  for _b in "${DUP_SCRIPT_DELIBERATE[@]}" "${DUP_SCRIPT_BASELINE[@]}"; do
    recorded="$(awk -v b="$_b" '$1=="#" && $2=="diff:" && $3==b {print $4; exit}' "$PLATFORM_INVENTORY")"
    if [[ -z "$recorded" ]]; then
      unrecorded+=("$_b")
      continue
    fi
    [[ -n "$plat_repo" ]] || continue
    measured="$(measure_pair_diff "$REPO_ROOT" "$plat_repo" "$_b")" || measured="none"
    [[ "$measured" == "$recorded" ]] || drift+=("$_b — recorded $recorded, measured $measured")
  done

  # This half runs EVERYWHERE, CI included: an allowlisted pair with no recorded
  # divergence is an unmeasured pair, and an unmeasured pair is what this whole
  # ratchet exists to stop.
  if (( ${#unrecorded[@]} > 0 )); then
    echo ""
    echo "  ✗ ${#unrecorded[@]} allowlisted pair(s) have NO recorded divergence in $PLATFORM_INVENTORY:"
    printf '      %s\n' "${unrecorded[@]}"
    echo "      Without a recorded number this pair can drift arbitrarily far and still"
    echo "      pass — which is exactly what happened to deploy-local.sh (comment said"
    echo "      453, measured 512) and configure-platform.sh (~132 vs 193). Record it:"
    echo "        scripts/validate-iac.sh --refresh-platform-inventory   # then commit"
    FAILED=1
  fi

  if (( ${#drift[@]} > 0 )); then
    echo ""
    echo "  ✗ ${#drift[@]} allowlisted pair(s) DIVERGED from the recorded measurement:"
    printf '      %s\n' "${drift[@]}"
    echo ""
    echo "      Two copies of an ops script drifting apart is the shape of every"
    echo "      duplication outage here: the frozen sync-groups.sh fork put"
    echo "      'repoURL: https://github.com/your-org/your-repo.git' on the live cluster"
    echo "      (2026-06-30), and two halves of bootstrap-openbao.sh cost 12h of OpenBao"
    echo "      downtime (2026-08-06). Neither copy looked wrong on its own."
    echo ""
    echo "      If the change is deliberate, RE-RECORD it in the same commit:"
    echo "        scripts/validate-iac.sh --refresh-platform-inventory   # then commit"
    echo "      If it is not, converge the copies — or better, close the pair."
    FAILED=1
  fi

  if [[ -z "$plat_repo" ]]; then
    echo "  · divergence sizes NOT re-measured here: that needs both checkouts, and this"
    echo "    machine has one. The recorded numbers were still checked for presence"
    echo "    above, and the measurement is enforced at the only point that can BLOCK a"
    echo "    change — the pre-push hook on the build host, which has both trees."
  fi

  if (( ${#new_dupes[@]} == 0 && ${#stale[@]} == 0 && ${#unrecorded[@]} == 0 && ${#drift[@]} == 0 )) && ! $stale_inventory; then
    echo "  ✓ no undeclared duplicate script basenames" \
         "(deliberate: ${#DUP_SCRIPT_DELIBERATE[@]}, baseline: ${#DUP_SCRIPT_BASELINE[@]}," \
         "infra: $(echo "$infra_list" | wc -l), platform: $(echo "$live_list" | wc -l))"
    if [[ -n "$plat_repo" ]]; then
      echo "  ✓ no divergence growth: all ${#DUP_SCRIPT_DELIBERATE[@]}+${#DUP_SCRIPT_BASELINE[@]} allowlisted pairs match their recorded diff sizes"
    fi
  fi
}

if $REFRESH_INVENTORY; then
  PLAT="$(resolve_platform_repo || true)"
  if [[ -z "$PLAT" ]]; then
    echo "✗ --refresh-platform-inventory needs an InfraWeaver-platform checkout." >&2
    echo "  Tried \$INFRAWEAVER_PLATFORM_REPO, \$PLATFORM_DIR, $REPO_ROOT/../InfraWeaver-platform," >&2
    echo "  \$HOME/InfraWeaver-platform, /opt/InfraWeaver-platform." >&2
    exit 1
  fi
  write_platform_inventory "$PLAT"
  echo "✓ wrote $PLATFORM_INVENTORY from $PLAT" \
       "($(grep -cv '^#' "$PLATFORM_INVENTORY") script(s)) — commit it."
  exit 0
fi

if $DUP_ONLY; then
  gate_duplicate_scripts
  echo "──────────────────────────────────────────────────────────────────────────"
  [[ $FAILED -eq 0 ]] && echo "duplicate-script gate PASSED" || echo "duplicate-script gate FAILED"
  exit $FAILED
fi

echo "── 1/7 kustomize build (overlays) ───────────────────────────────────────"
# Resolved ONCE, and its absence is recorded rather than silently skipped in two
# separate places (it used to vanish entirely from gate 1's output).
HAVE_KUBECONFORM=false
command -v kubeconform >/dev/null 2>&1 && HAVE_KUBECONFORM=true
KUBECONFORM_FIX="install kubeconform (CI does: see .github/workflows/validate-iac.yml)"

mapfile -t OVERLAYS < <(find kubernetes -type f -path '*/overlays/*/kustomization.yaml' -printf '%h\n' | sort -u)
if [[ ${#OVERLAYS[@]} -eq 0 ]]; then
  # Not a tooling skip: there is genuinely nothing to render. Still worth saying
  # out loud, because "0 overlays" and "all overlays passed" look identical.
  echo "  (no overlays found under kubernetes/**/overlays/ — nothing to render)"
fi
for d in "${OVERLAYS[@]}"; do
  if "${KUSTOMIZE[@]}" "$d" >/tmp/iac-render.yaml 2>/tmp/iac-err.txt; then
    echo "  ✓ $d"
    if $HAVE_KUBECONFORM; then
      kubeconform "${KUBECONFORM_FLAGS[@]}" /tmp/iac-render.yaml >/tmp/kc.txt 2>&1 \
        && echo "    ✓ kubeconform" \
        || { echo "    ✗ kubeconform:"; sed 's/^/      /' /tmp/kc.txt; FAILED=1; }
    fi
  else
    echo "  ✗ $d"; sed 's/^/    /' /tmp/iac-err.txt; FAILED=1
  fi
done
$HAVE_KUBECONFORM || note_skip \
  "1/7 — schema validation of ${#OVERLAYS[@]} rendered overlay(s): kubeconform not installed" \
  "$KUBECONFORM_FIX"

echo "── 2/7 kubeconform (flat manifest dirs without overlays) ─────────────────"
if $HAVE_KUBECONFORM; then
  mapfile -t FLAT < <(find kubernetes -type d -name manifests | sort)
  for d in "${FLAT[@]}"; do
    kubeconform "${KUBECONFORM_FLAGS[@]}" "$d" >/tmp/kc.txt 2>&1 \
      && echo "  ✓ $d" \
      || { echo "  ✗ $d:"; sed 's/^/    /' /tmp/kc.txt; FAILED=1; }
  done
else
  note_skip "2/7 — kubeconform not installed, no flat manifest dir was schema-checked" \
            "$KUBECONFORM_FIX"
fi

echo "── 3/7 secret-leak gate ──────────────────────────────────────────────────"
LEAKS="$(BASELINE="${SECRET_BASELINE[*]}" EXEMPT="${PLACEHOLDER_EXEMPT[*]}" python3 - << 'PY'
import glob, yaml, os
baseline = set(os.environ.get("BASELINE","").split())
exempt = set(os.environ.get("EXEMPT","").split())
# Write-me placeholders. NOT treated as "no value": under GitOps ArgoCD applies
# them verbatim and selfHeal re-applies them over any in-cluster rotation, so a
# committed "change-me" IS the live credential. They are reported separately
# from a real leak only so the message can say which mistake was made; both fail.
placeholders = {"change-me", "changeme", "change_me", "placeholder", "changethis",
                "change-this", "tbd", "todo", "secret", "password", "hunter2"}
leaks, weak = [], []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get('kind') != 'Secret':
            continue
        name = (d.get('metadata') or {}).get('name')
        ref = f"{f}::{name}"
        vals = list((d.get('stringData') or {}).values()) + list((d.get('data') or {}).values())
        # An empty value carries no credential and is how a template declares a
        # key it does not own; everything else is a value this repo would apply.
        present = [v.strip() for v in vals if isinstance(v, str) and v.strip()]
        if not present:
            continue
        if all(v.lower() in placeholders for v in present):
            if ref not in exempt:
                weak.append(ref)
        elif ref not in baseline:
            leaks.append(ref)
for v in sorted(set(leaks)):
    print(f"leak {v}")
for v in sorted(set(weak)):
    print(f"placeholder {v}")
PY
)"
if [[ -n "$LEAKS" ]]; then
  echo "  ✗ raw Secret(s) committed to git — use ExternalSecret + OpenBao:"
  echo "$LEAKS" | sed 's/^/      /'
  echo "      (a 'placeholder' hit is a credential too: ArgoCD applies it and selfHeal"
  echo "       re-asserts it over any in-cluster rotation. Exempt only a template a"
  echo "       human edits before apply, via PLACEHOLDER_EXEMPT in this script.)"
  FAILED=1
else
  echo "  ✓ no committed secrets or write-me placeholders (baseline: ${#SECRET_BASELINE[@]}, exempt: ${#PLACEHOLDER_EXEMPT[@]})"
fi

echo "── 4/7 cron-secret seed gate ─────────────────────────────────────────────"
CRON_GAPS="$(python3 - << 'PY'
import glob, yaml

def load(f):
    try:
        return list(yaml.safe_load_all(open(f)))
    except Exception:
        return []

# 1. ExternalSecret map: k8s Secret name -> { secretKey: (openbao_key, property) }
#
# `es_opaque` records the targets whose final key set this file cannot enumerate,
# so §3 must not claim a key is missing from them:
#   - `spec.target.template.data` RENAMES the fetched values. bookstack fetches
#     `secretKey: appKey` and the template emits a key literally called `value`
#     (`base64:{{ .appKey | trunc 32 | b64enc }}`), which deployment.yaml is what
#     reads. Judging that target by spec.data alone reports a live, working app as
#     unable to start.
#   - `spec.dataFrom` (extract/find) pulls an entire OpenBao path, so the produced
#     keys are whatever the store holds and are not knowable from the manifest.
es = {}
es_opaque = set()
es_retain_refs = []  # (target, openbao_key, property) for every Retain-policy ES data entry
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') not in ('ExternalSecret', 'ClusterExternalSecret'):
            continue
        spec = d.get('spec', {})
        if d.get('kind') == 'ClusterExternalSecret':
            spec = (spec.get('externalSecretSpec') or spec)
        target = (spec.get('target') or {}).get('name') or (d.get('metadata') or {}).get('name')
        deletion_policy = (spec.get('target') or {}).get('deletionPolicy')
        template = ((spec.get('target') or {}).get('template') or {})
        mapping = {}
        for item in (spec.get('data') or []):
            rr = item.get('remoteRef', {}) or {}
            sk = item.get('secretKey')
            mapping[sk] = (rr.get('key'), rr.get('property') or sk)
            if target and deletion_policy == 'Retain' and rr.get('key'):
                es_retain_refs.append((target, rr.get('key'), rr.get('property') or sk))
        if target:
            es[target] = mapping
            if template.get('data') or template.get('templateFrom') or spec.get('dataFrom'):
                es_opaque.add(target)

# 2. Catalog apps that own an OpenBao path via their declared secrets: section.
#    Normalise: catalog `path: platform/x` == ExternalSecret `key: secret/platform/x`.
def norm(p):
    if not p:
        return p
    p = p[len('secret/'):] if p.startswith('secret/') else p
    p = p[len('data/'):] if p.startswith('data/') else p
    return p.rstrip('/')

owned = {}  # normalised path -> (app_name, set(declared keys))
for f in glob.glob('kubernetes/catalog/*/catalog.yaml'):
    d = (load(f) or [None])[0]
    if not isinstance(d, dict):
        continue
    s = d.get('secrets')
    if not s:
        continue
    p = norm(s.get('path'))
    if p:
        owned[p] = (d.get('name', f.split('/')[-2]), set((s.get('keys') or {}).keys()))

# 3. Every workload secretKeyRef whose backing key comes from an owned path must be
#    a declared key (else bootstrap never seeds it and the job can't start).
#
#    TWO chains have to hold, and this gate used to check only the second half of
#    the first one:
#      catalog.yaml secrets.keys  →  the value exists in OpenBao
#      ExternalSecret spec.data   →  the value reaches the k8s Secret
#    `placement-rebalance-cron-token` was declared in catalog.yaml and named by the
#    CronJob and the Deployment — and by no ExternalSecret entry. The lookup below
#    returned None, the old code read that as "raw/generated Secret, out of scope"
#    and skipped it, and the gate reported PASSED while the CronJob sat in
#    CreateContainerConfigError on every schedule for as long as it existed.
#    A Secret produced by an ExternalSecret with creationPolicy: Owner has no other
#    writer, so a key missing from spec.data can never appear: that is a MISSING
#    ENTRY, not an out-of-scope one. Only a Secret name no ExternalSecret produces
#    at all is genuinely out of scope.
#
#    `optional: true` does not excuse it either — that flag is what let the console
#    Deployment start with an EMPTY token and hid the same defect on its other half.
#    An env var that can never be populated is dead config, so it is reported too,
#    with its own wording.
WORKLOAD_PODSPEC = {
    'CronJob': lambda d: d['spec']['jobTemplate']['spec']['template']['spec'],
    'Deployment': lambda d: d['spec']['template']['spec'],
    'StatefulSet': lambda d: d['spec']['template']['spec'],
    'DaemonSet': lambda d: d['spec']['template']['spec'],
    'Job': lambda d: d['spec']['template']['spec'],
}
violations = []
for f in glob.glob('kubernetes/**/*.yaml', recursive=True):
    for d in load(f):
        if not isinstance(d, dict) or d.get('kind') not in WORKLOAD_PODSPEC:
            continue
        kind = d['kind']
        job = f"{kind}/{(d.get('metadata') or {}).get('name', '?')}"
        try:
            pod = WORKLOAD_PODSPEC[kind](d)
        except Exception:
            continue
        containers = (pod.get('containers') or []) + (pod.get('initContainers') or [])
        for c in containers:
            for e in (c.get('env') or []):
                skr = (e.get('valueFrom') or {}).get('secretKeyRef')
                if not skr:
                    continue
                sec, key = skr.get('name'), skr.get('key')
                if sec not in es:
                    continue  # no ExternalSecret produces this Secret — raw/generated, out of scope
                if sec in es_opaque:
                    continue  # a template/dataFrom decides the final key set — not enumerable here
                src = es[sec].get(key)
                if not src:
                    how = ("declared optional, so the workload starts with the value EMPTY"
                           if skr.get('optional')
                           else "not optional, so the pod cannot start at all")
                    violations.append(
                        f"{job}: needs {sec}[{key}], but no ExternalSecret data entry produces "
                        f"that key and creationPolicy: Owner leaves the Secret no other writer "
                        f"({how})")
                    continue
                path, prop = norm(src[0]), src[1]
                if path in owned:
                    app, keys = owned[path]
                    if prop not in keys:
                        violations.append(
                            f"{job}: needs {sec}[{key}] = {path}::{prop}, "
                            f"but '{prop}' is not declared in catalog/{app}/catalog.yaml secrets.keys")

# 4. deletionPolicy: Retain ExternalSecrets fail the WHOLE secret sync if ANY
#    referenced property is missing in OpenBao (ESO only skips a missing key when
#    deletionPolicy != Retain). So every property such an ES reads from an owned
#    catalog path must be declared, else a fresh install can't materialise the
#    secret at all — every consumer (the app pod AND its CronJobs) stays stuck.
for target, key, prop in es_retain_refs:
    path = norm(key)
    if path in owned:
        app, keys = owned[path]
        if prop not in keys:
            violations.append(
                f"ExternalSecret {target} (deletionPolicy: Retain): needs {path}::{prop}, "
                f"but '{prop}' is not declared in catalog/{app}/catalog.yaml secrets.keys "
                f"(Retain aborts the entire secret on any one missing key)")
for v in sorted(set(violations)):
    print(v)
PY
)"
if [[ -n "$CRON_GAPS" ]]; then
  echo "  ✗ a CronJob or Retain-policy ExternalSecret needs a secret key no bootstrap seeds (declare it in the app's catalog.yaml secrets.keys):"
  echo "$CRON_GAPS" | sed 's/^/      /'
  FAILED=1
else
  echo "  ✓ every workload secret key is declared in its catalog.yaml AND produced by an ExternalSecret"
fi

echo "── 5/7 alerting rules (promtool + duplicate scan) ────────────────────────"
# Alerting rules used to have no gate at all. Two real defects shipped through
# that gap: a >85% node-memory alert existed twice under different alertnames in
# two files (one condition, two Discord pages, un-inhibitable because
# Alertmanager keys inhibition on alertname), and a console CronJob alert was
# added that duplicated one already in alerts/openbao-token.yaml.
#
# promtool cannot read a PrometheusRule custom resource, so `.spec` is extracted
# from every one of them into a temp dir first. Group names are prefixed with
# their source file because group names must be unique within a rules file.
RULES_TMP="$(mktemp -d)"
trap 'rm -rf "$RULES_TMP"' EXIT

RULE_EXTRACT="$(python3 - "$RULES_TMP" <<'PY'
import sys, glob, yaml, os
out_dir = sys.argv[1]
groups, files = [], 0
for f in sorted(glob.glob('kubernetes/**/*.yaml', recursive=True)):
    try:
        docs = [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
    except Exception:
        continue                      # not our file; other gates cover parse errors
    for d in docs:
        if d.get('kind') != 'PrometheusRule':
            continue
        files += 1
        stem = os.path.basename(f).rsplit('.', 1)[0]
        for g in d.get('spec', {}).get('groups', []):
            g = dict(g)
            g['name'] = f"{stem}::{g['name']}"
            groups.append(g)
if not groups:
    # A scan that finds nothing must not read as success.
    print("ERROR: no PrometheusRule groups found — the extractor is broken or the rules moved")
    sys.exit(1)
with open(os.path.join(out_dir, 'rules.yaml'), 'w') as fh:
    yaml.safe_dump({'groups': groups}, fh, sort_keys=False, width=10**6)
print(f"{files} PrometheusRule doc(s), {len(groups)} group(s), "
      f"{sum(len(g.get('rules', [])) for g in groups)} rule(s)")
PY
)" || { echo "  ✗ rule extraction failed:"; echo "$RULE_EXTRACT" | sed 's/^/      /'; FAILED=1; }
[[ -n "$RULE_EXTRACT" ]] && echo "  · extracted $RULE_EXTRACT"

# Duplicate scan. Pure Python, so it runs everywhere — including where promtool
# is absent. This is the check that would have caught both defects above.
DUPES="$(python3 - <<'PY'
import glob, yaml, collections
names, exprs = collections.defaultdict(list), collections.defaultdict(list)
for f in sorted(glob.glob('kubernetes/**/*.yaml', recursive=True)):
    try:
        docs = [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
    except Exception:
        continue
    for d in docs:
        if d.get('kind') != 'PrometheusRule':
            continue
        for g in d.get('spec', {}).get('groups', []):
            for r in g.get('rules', []):
                if 'alert' not in r:
                    continue
                names[r['alert']].append(f)
                exprs[' '.join(r['expr'].split())].append(f"{r['alert']} ({f})")
for n, fs in sorted(names.items()):
    if len(fs) > 1:
        print(f"duplicate alertname '{n}' in: {', '.join(sorted(set(fs)))}")
for e, rs in sorted(exprs.items()):
    if len(rs) > 1:
        print(f"identical expression shared by: {', '.join(sorted(set(rs)))}")
        print(f"    expr: {e[:110]}")
PY
)"
if [[ -n "$DUPES" ]]; then
  echo "  ✗ duplicate alerts — one condition would page twice and Alertmanager cannot inhibit across alertnames:"
  echo "$DUPES" | sed 's/^/      /'
  FAILED=1
else
  echo "  ✓ no duplicate alertnames or identical expressions across PrometheusRules"
fi

if command -v promtool >/dev/null 2>&1; then
  if [[ -f "$RULES_TMP/rules.yaml" ]]; then
    promtool check rules "$RULES_TMP/rules.yaml" >/tmp/pt.txt 2>&1 \
      && echo "  ✓ promtool check rules" \
      || { echo "  ✗ promtool check rules:"; sed 's/^/      /' /tmp/pt.txt; FAILED=1; }

    # Unit tests live beside the rules they cover. Each is copied next to the
    # extracted rules.yaml because promtool resolves rule_files relative to the
    # test file.
    shopt -s nullglob
    TESTS=(kubernetes/monitoring/alerts/tests/*.test.yaml)
    shopt -u nullglob
    if (( ${#TESTS[@]} == 0 )); then
      echo "  ✗ no *.test.yaml found under kubernetes/monitoring/alerts/tests/ — alert unit tests are expected to exist"
      FAILED=1
    else
      for t in "${TESTS[@]}"; do
        cp "$t" "$RULES_TMP/$(basename "$t")"
        if (cd "$RULES_TMP" && promtool test rules "$(basename "$t")") >/tmp/pt.txt 2>&1; then
          echo "  ✓ promtool test rules — $(basename "$t")"
        else
          echo "  ✗ promtool test rules — $(basename "$t"):"; sed 's/^/      /' /tmp/pt.txt; FAILED=1
        fi
      done
    fi
  fi
else
  # THE SKIP THAT COST FOUR RED COMMITS. This branch used to print one line and
  # leave FAILED at 0, so a laptop with no promtool ended the whole run with
  # "IaC validation PASSED" while `promtool check rules` and every *.test.yaml
  # under kubernetes/monitoring/alerts/tests/ had not executed. CI, which does
  # install promtool, disagreed — four times.
  shopt -s nullglob; _NTESTS=(kubernetes/monitoring/alerts/tests/*.test.yaml); shopt -u nullglob
  note_skip "5/7 — promtool not installed: 'check rules' and ${#_NTESTS[@]} alert unit-test file(s) did NOT run" \
            "install promtool 3.13.2 (it is in ~/bin here; CI installs it in .github/workflows/validate-iac.yml)"
fi

echo "── 6/7 armed-blueprint gate ──────────────────────────────────────────────"
# A security control that is WRONG is worse than one that is absent, and this
# repo has already written the proof of it: manifests/blueprints/
# 70-brute-force-reputation.yaml documents, in its own §3c, that arming the
# Authentik IP-reputation lockout while Cloudflare still appends to a
# caller-supplied X-Forwarded-For turns the control into a remote DoS — 21 failed
# logins carrying `X-Forwarded-For: <victim>` deny that address login for 24h,
# and any unauthenticated caller picks the victim.
#
# The mount and the warning shipped in the SAME commit on
# fix/traefik-cloudflare-xff-arm-brute-force, so the warning could not stop it:
# whoever merged the branch would have armed the policy and read the reason
# afterwards. A comment is not a gate. This is.
#
# The rule: the blueprint may be listed in values.yaml `blueprints.configMaps`
# only once its own arming procedure no longer marks step 0b OUTSTANDING.
# Closing 0b means editing the blueprint, so the two cannot drift apart.
BF_BLUEPRINT="kubernetes/platform/authentik/manifests/blueprints/70-brute-force-reputation.yaml"
BF_VALUES="kubernetes/platform/authentik/values.yaml"
if [[ -f "$BF_BLUEPRINT" && -f "$BF_VALUES" ]]; then
  # An uncommented list entry only — the disarmed form is commented out.
  if grep -qE '^[[:space:]]*-[[:space:]]*authentik-blueprint-brute-force[[:space:]]*$' "$BF_VALUES"; then
    if grep -qE '0b\.[[:space:]]*\[OUTSTANDING\]' "$BF_BLUEPRINT"; then
      echo "  ✗ authentik-blueprint-brute-force is MOUNTED while its own §4 step 0b is still [OUTSTANDING]."
      echo "      Arming the IP-reputation lockout before the Cloudflare Transform Rule exists makes"
      echo "      login remotely deniable for any address an attacker names. Close 0b in"
      echo "      $BF_BLUEPRINT (and prove it: a request with a bogus X-Forwarded-For must be"
      echo "      recorded under the real caller) before listing it in $BF_VALUES."
      FAILED=1
    else
      echo "  ✓ brute-force blueprint is mounted and its §3c prerequisite is marked closed"
    fi
  else
    echo "  ✓ brute-force blueprint is not mounted (§3c still open — see values.yaml)"
  fi
else
  echo "  ✗ expected blueprint/values pair not found — this gate is not guarding anything"
  FAILED=1
fi

gate_duplicate_scripts

echo "──────────────────────────────────────────────────────────────────────────"
if (( ${#SKIPPED[@]} > 0 )); then
  echo ""
  echo "  ⚠⚠ ${#SKIPPED[@]} GATE(S) DID NOT RUN. This is not a pass — it is an unknown:"
  printf '      · %s\n' "${SKIPPED[@]}"
  echo ""
fi

if [[ $FAILED -ne 0 ]]; then
  echo "IaC validation FAILED"
  exit 1
fi
if (( ${#SKIPPED[@]} > 0 )); then
  if [[ "${IAC_ALLOW_SKIPPED_GATES:-0}" == "1" ]]; then
    echo "IaC validation INCOMPLETE — ${#SKIPPED[@]} gate(s) skipped, everything that ran passed."
    echo "  (IAC_ALLOW_SKIPPED_GATES=1 — exiting 0 anyway. CI must never set this.)"
    exit 0
  fi
  echo "IaC validation INCOMPLETE — ${#SKIPPED[@]} gate(s) skipped, everything that ran passed."
  echo "  Install the tool(s) listed above, or accept a partial run explicitly with"
  echo "  IAC_ALLOW_SKIPPED_GATES=1. A silently-skipped gate is why CI stayed red for"
  echo "  four commits while every local run reported PASSED."
  exit 1
fi
echo "IaC validation PASSED"
exit 0
