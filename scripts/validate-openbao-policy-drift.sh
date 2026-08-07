#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-openbao-policy-drift.sh — is live OpenBao ACL still what git says?
#
# WHY THIS EXISTS
#   `bao policy write` is a full REPLACE. On 2026-08-06T20:21:18Z a second,
#   divergent copy of scripts/deploy/bootstrap-openbao.sh (in the platform repo)
#   rewrote the `platform-k8s` policy with its own half of the grants, silently
#   dropping secret/{data,metadata}/{iwsl,catalog}/*. Four ExternalSecrets lost
#   their reads and three ArgoCD Applications went Degraded — and stayed that way
#   for ~12 hours, because NOTHING in this platform compared live OpenBao policy
#   to the policy in git. The clobber was invisible until the apps were noticed.
#
#   This is that missing comparison. Read-only, always: it never writes a policy.
#
# SOURCE OF TRUTH
#   The policy heredocs inside scripts/deploy/bootstrap-openbao.sh. They are
#   parsed out of the script rather than duplicated into a .hcl file here — a
#   third copy of the policy text is the same bug this incident was about.
#
# MODES
#   (default)  offline/static gate. No cluster access. Verifies the heredocs are
#              extractable and well-formed, so the live check cannot silently
#              degrade into comparing nothing. Safe for CI and the pre-push hook.
#   --live     read each policy back from OpenBao and diff it against git.
#              Exit 1 on drift. Requires kubeconfig + cluster reachability.
#
# USAGE
#   scripts/validate-openbao-policy-drift.sh
#   scripts/validate-openbao-policy-drift.sh --live
#   scripts/validate-openbao-policy-drift.sh --live \
#     --prom-out /var/lib/node_exporter/textfile_collector/openbao_policy_drift.prom
#
# OPTIONS
#   --repo-root <path>   repo root (default: this script's parent directory)
#   --env <name>         platform env, picks ~/.kube/config-platform-<env>
#                        (default: $ENV_NAME, else "productie")
#   --prom-out <file>    write node-exporter textfile-collector metrics
#                        (openbao_policy_drift{policy=...}). Implies --live.
#
# EXIT CODES
#   0  no drift (or offline gate passed)
#   1  drift detected, or a malformed/unextractable policy heredoc
#   2  the check could not run (no kubeconfig, OpenBao unreachable, no token).
#      Deliberately distinct from 1: "I could not look" must never be reported
#      as "I looked and it was fine".
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME_ARG="${ENV_NAME:-productie}"
MODE="offline"
PROM_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --env)       ENV_NAME_ARG="$2"; shift 2 ;;
    --live)      MODE="live"; shift ;;
    --prom-out)  PROM_OUT="$2"; MODE="live"; shift 2 ;;
    -h|--help)   sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

BOOTSTRAP="$REPO_ROOT/scripts/deploy/bootstrap-openbao.sh"
# Policies this script REQUIRES to be present in the bootstrap script. If a
# rename or refactor drops one, the gate fails loudly instead of quietly
# checking a shorter list.
REQUIRED_POLICIES=(platform-k8s wordpress)

TMPDIR_WORK="$(mktemp -d)"
# shellcheck disable=SC2317  # invoked via trap
cleanup() { rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT

fail()  { echo "✖ $*" >&2; }
info()  { echo "  $*"; }

# ── Extract the policy heredocs from bootstrap-openbao.sh ────────────────────
# Matches:   'bao policy write <name> - <<EOF      ... up to a line that is EOF'
# Body lines are emitted verbatim; the heredoc is what OpenBao stores, comments
# and all, so a byte comparison against `bao policy read` is meaningful.
extract_policies() {
  awk -v outdir="$TMPDIR_WORK" '
    match($0, /bao policy write ([A-Za-z0-9_-]+) - <<EOF$/, m) {
      name = m[1]; file = outdir "/" name ".git.hcl"
      printf "" > file
      inblock = 1
      print name
      next
    }
    inblock && $0 == "EOF'"'"'" { inblock = 0; close(file); next }
    inblock { print $0 >> file }
    END { if (inblock) { print "UNTERMINATED" > "/dev/stderr"; exit 3 } }
  ' "$BOOTSTRAP"
}

if [[ ! -f "$BOOTSTRAP" ]]; then
  fail "bootstrap script not found: $BOOTSTRAP"
  exit 2
fi

mapfile -t FOUND < <(extract_policies)
if [[ ${#FOUND[@]} -eq 0 ]]; then
  fail "no 'bao policy write <name> - <<EOF' blocks found in $BOOTSTRAP"
  fail "  the extractor is broken or the script was restructured — this gate is blind, refusing to pass"
  exit 1
fi

RC=0
for want in "${REQUIRED_POLICIES[@]}"; do
  if [[ ! -f "$TMPDIR_WORK/$want.git.hcl" ]]; then
    fail "expected policy '$want' is not written by $BOOTSTRAP"
    RC=1
  fi
done
[[ $RC -ne 0 ]] && exit 1

# ── Static well-formedness gate (runs in both modes) ─────────────────────────
# These are the properties that make the heredoc safe to execute AND safe to
# compare. Each one has bitten this repo or is one character away from doing so.
for name in "${FOUND[@]}"; do
  f="$TMPDIR_WORK/$name.git.hcl"
  [[ -s "$f" ]] || { fail "policy '$name' body is empty"; RC=1; continue; }

  # A single quote terminates the `sh -c '...'` wrapper: the policy would be
  # truncated and the rest interpreted as shell.
  if grep -q "'" "$f"; then
    fail "policy '$name' contains a single quote — it would break the sh -c wrapper"
    RC=1
  fi
  # The heredoc delimiter is unquoted (<<EOF), so the inner shell expands $VAR
  # and `cmd` before OpenBao ever sees the text.
  if grep -qE '[$`]' "$f"; then
    fail "policy '$name' contains \$ or backtick — it would be expanded by the inner shell"
    RC=1
  fi
  # Every substantive line must be a path rule. Catches a truncated paste or a
  # stray line of prose that OpenBao would reject at write time (too late).
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    [[ "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^path\ \"[^\"]+\"\ \{\ capabilities\ =\ \[.*\]\ \}$ ]]; then
      fail "policy '$name': not a well-formed path rule: $line"
      RC=1
    fi
  done < "$f"
  # A duplicated path key is a silent last-one-wins: the reader sees a rule that
  # is not the effective one.
  dupes="$(grep -oE '^path "[^"]+"' "$f" | sort | uniq -d || true)"
  if [[ -n "$dupes" ]]; then
    fail "policy '$name' declares duplicate paths (last one silently wins):"
    # shellcheck disable=SC2001  # prefixing every line of a multi-line string
    echo "$dupes" | sed 's/^/    /' >&2
    RC=1
  fi
done

if [[ $RC -ne 0 ]]; then
  fail "static policy gate FAILED — not proceeding to the live comparison"
  exit 1
fi

if [[ "$MODE" == "offline" ]]; then
  info "✔ openbao policy gate (static): ${#FOUND[@]} policies well-formed — ${FOUND[*]}"
  info "  run with --live to diff these against the cluster"
  exit 0
fi

# ── Live comparison (READ-ONLY against OpenBao) ──────────────────────────────
KB="$HOME/.kube/config-platform-$ENV_NAME_ARG"
if [[ ! -f "$KB" ]]; then
  fail "kubeconfig not found: $KB (set --env or ENV_NAME)"
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  fail "kubectl not on PATH"
  exit 2
fi

# The root token is read into a variable and handed to the pod via env. It is
# never echoed, never written to a file, and never appears in the metrics.
ROOT_TOKEN="$(kubectl --kubeconfig "$KB" get secret openbao-unseal -n openbao \
  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "placeholder" ]]; then
  fail "no usable OpenBao root token in openbao/openbao-unseal — cannot read policies"
  exit 2
fi

DRIFTED=()
CHECKED=()
for name in "${FOUND[@]}"; do
  live="$TMPDIR_WORK/$name.live.hcl"
  if ! kubectl --kubeconfig "$KB" exec -n openbao -c openbao openbao-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR=http://127.0.0.1:8200 \
      bao policy read "$name" > "$live" 2>/dev/null; then
    fail "could not read live policy '$name' from OpenBao"
    unset ROOT_TOKEN
    exit 2
  fi
  CHECKED+=("$name")
  if diff -u "$TMPDIR_WORK/$name.git.hcl" "$live" \
       --label "git:scripts/deploy/bootstrap-openbao.sh ($name)" \
       --label "live:openbao policy $name" > "$TMPDIR_WORK/$name.diff"; then
    info "✔ $name — live matches git"
  else
    DRIFTED+=("$name")
    fail "DRIFT in policy '$name':"
    cat "$TMPDIR_WORK/$name.diff" >&2
  fi
done
unset ROOT_TOKEN

# ── Optional Prometheus textfile-collector output ────────────────────────────
if [[ -n "$PROM_OUT" ]]; then
  tmp_prom="$TMPDIR_WORK/metrics.prom"
  {
    echo "# HELP openbao_policy_drift 1 if the live OpenBao policy differs from scripts/deploy/bootstrap-openbao.sh"
    echo "# TYPE openbao_policy_drift gauge"
    for name in "${CHECKED[@]}"; do
      v=0
      for d in "${DRIFTED[@]+"${DRIFTED[@]}"}"; do [[ "$d" == "$name" ]] && v=1; done
      echo "openbao_policy_drift{policy=\"$name\"} $v"
    done
    echo "# HELP openbao_policy_drift_check_success 1 if the drift check itself completed"
    echo "# TYPE openbao_policy_drift_check_success gauge"
    echo "openbao_policy_drift_check_success 1"
    echo "# HELP openbao_policy_drift_check_timestamp_seconds unix time of the last completed check"
    echo "# TYPE openbao_policy_drift_check_timestamp_seconds gauge"
    echo "openbao_policy_drift_check_timestamp_seconds $(date +%s)"
  } > "$tmp_prom"
  # Atomic: the textfile collector may be mid-scrape.
  if mv "$tmp_prom" "$PROM_OUT" 2>/dev/null; then
    info "metrics written to $PROM_OUT"
  else
    fail "could not write metrics to $PROM_OUT"
  fi
fi

if [[ ${#DRIFTED[@]} -gt 0 ]]; then
  fail ""
  fail "✖ OpenBao policy drift: ${DRIFTED[*]}"
  fail "  Live OpenBao no longer matches scripts/deploy/bootstrap-openbao.sh."
  fail "  Decide which side is right BEFORE re-running the bootstrap script —"
  fail "  'bao policy write' is a full replace and will delete whatever git omits."
  exit 1
fi

info "✔ no OpenBao policy drift (${#CHECKED[@]} policies checked)"
exit 0
