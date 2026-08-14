#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# fabric-preflight.sh — answer "can I safely remove / shrink / reboot this node?"
# with numbers, before anything moves.
#
#   bash scripts/fabric-preflight.sh                            # cluster-wide
#   bash scripts/fabric-preflight.sh --node talos-prod-cp2
#   bash scripts/fabric-preflight.sh --node talos-prod-cp2 --json
#   bash scripts/fabric-preflight.sh --simulate-add 100         # a new 100 GB node
#   bash scripts/fabric-preflight.sh --simulate-resize cp1=36   # cp1 -> 36 GB
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# This platform's signature failure is "a control that could not work, reporting
# success". Node removal is the worst place for it: by the time a drain stalls or
# an etcd member is gone, the cheap moment to say no has passed.
#
# Every check can FAIL, and a FAIL is a refusal, not a warning. This script is
# strictly READ-ONLY — `kubectl get` and `talosctl etcd members`, nothing else.
# It cannot cordon, drain, patch or delete. The logic lives in
# scripts/lib/fabric_preflight.py, which touches no cluster at all and is
# therefore testable against captured JSON.
#
# ── THE CHECK THAT MATTERS MOST ──────────────────────────────────────────────
# etcd quorum. Members vs failures tolerated:
#
#     1 member  -> 0        3 members -> 1        5 members -> 2
#     2 members -> 0        4 members -> 1
#
# TWO IS STRICTLY WORSE THAN THREE AND NO BETTER THAN ONE. So a consolidation is
# always add-first, remove-second: 3->4->3 never drops below "tolerates 1", while
# 3->2->3 passes through a window where one host reboot is a dead cluster.
# This refuses the second ordering rather than warning about it.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  every check passed (WARNs allowed)
#   1  at least one check FAILED — the operation is refused
#   2  could not determine an answer (missing tool, unreachable cluster)
#
# Exit 2 is deliberately distinct from 0. "I could not check" must never be
# mistaken for "it is safe" — that substitution is how a validate gate once
# reported PASSED on a CronJob that had never run.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL_BIN:-$(command -v kubectl || true)}"
TALOSCTL="${TALOSCTL_BIN:-$(command -v talosctl || true)}"

export FP_MODE="cluster"
export FP_TARGET=""
export FP_SIM=""
export FP_JSON="0"
# Reserve headroom on top of raw requests: kube-reserved, system-reserved and the
# eviction threshold all come off the top, and a rescheduled pod needs a node
# with room for it whole.
export FP_HEADROOM="${FABRIC_HEADROOM_PCT:-10}"

die() { printf 'fabric-preflight: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --node)            FP_MODE="node";       FP_TARGET="${2:?--node needs a node name}"; shift 2 ;;
    --simulate-add)    FP_MODE="sim-add";    FP_SIM="${2:?--simulate-add needs GB}";     shift 2 ;;
    --simulate-resize) FP_MODE="sim-resize"; FP_SIM="${2:?--simulate-resize needs node=GB}"; shift 2 ;;
    --json)            FP_JSON="1"; shift ;;
    -h|--help)         usage ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$KUBECTL" ] || die "kubectl not found. Set KUBECTL_BIN to an ABSOLUTE path — cron and sudo secure_path exclude ~/bin, and the 'cluster unreachable' that produces is a lie."
"$KUBECTL" version -o json >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECTL"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Capture once, so the whole report describes a single point in time rather than
# a smear across several queries.
"$KUBECTL" get nodes -o json                                   > "$WORK/nodes.json"
"$KUBECTL" get pods -A --field-selector=status.phase=Running -o json > "$WORK/pods.json"
"$KUBECTL" get pdb -A -o json 2>/dev/null > "$WORK/pdb.json" || echo '{"items":[]}' > "$WORK/pdb.json"

# etcd membership is authoritative when talosctl can reach it. When it cannot,
# fall back to counting control-plane nodes — an etcd member per control plane is
# this cluster's topology, but it is an INFERENCE and is labelled as one in the
# output. A removal is never approved on an unread quorum.
FP_ETCD_HEALTHY=0
FP_ETCD_INFERRED=0
if [ -n "$TALOSCTL" ] && members="$("$TALOSCTL" etcd members 2>/dev/null)"; then
  FP_ETCD_HEALTHY="$(printf '%s\n' "$members" | grep -cE '^[0-9a-f]{6,}' || true)"
fi
if [ "$FP_ETCD_HEALTHY" -eq 0 ]; then
  FP_ETCD_HEALTHY="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for n in d["items"]
          if "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {})))' \
    "$WORK/nodes.json")"
  FP_ETCD_INFERRED=1
fi
export FP_ETCD_HEALTHY FP_ETCD_INFERRED

exec python3 "$HERE/lib/fabric_preflight.py" \
  "$WORK/nodes.json" "$WORK/pods.json" "$WORK/pdb.json"
