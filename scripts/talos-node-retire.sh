#!/usr/bin/env bash
# talos-node-retire.sh — remove a Talos node from the cluster without losing data.
#
# Retiring a node is safe only when nothing depends on it exclusively. This
# script refuses to act until that is proven, then performs the removal in the
# order that keeps the cluster serving throughout:
#
#   preflight -> evict replicas -> cordon+drain -> leave etcd -> delete node -> stop VM
#
# The VM is stopped, never destroyed. Deleting the disk stays a human decision.
#
# Usage:
#   scripts/talos-node-retire.sh --name talos-prod-cp2 --api-endpoint 10.0.0.90 \
#       [--pve-host 10.1.0.3 --vmid 9301] [--yes]
#
#   --check-only   run the preflight and stop (safe to run any time)
#
# Requires talosctl + kubectl on the caller with TALOSCONFIG exported.
set -euo pipefail

NAME=""; API_ENDPOINT=""; PVE_HOST=""; VMID=""; ASSUME_YES=0; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --api-endpoint) API_ENDPOINT="$2"; shift 2 ;;
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --vmid) VMID="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NAME" ] && [ -n "$API_ENDPOINT" ] || { echo "usage: --name <node> --api-endpoint <ip>" >&2; exit 1; }

echo "==> preflight for ${NAME}"

# 1. Any volume whose ONLY healthy replica lives here would die with the node.
STRANDED=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | python3 -c '
import json,sys,collections
node=sys.argv[1]
byv=collections.defaultdict(list)
for x in json.load(sys.stdin)["items"]:
    s=x["spec"]
    if s.get("failedAt"): continue
    if (x.get("status") or {}).get("currentState")!="running": continue
    byv[s["volumeName"]].append(s.get("nodeID"))
for v,n in sorted(byv.items()):
    if set(n)=={node}: print(v)
' "$NAME")
if [ -n "$STRANDED" ]; then
  echo "    REFUSING: these volumes have their only running replica on ${NAME}:"
  echo "$STRANDED" | sed 's/^/      /'
  echo "    Fix first: raise numberOfReplicas and let them rebuild elsewhere."
  echo "    Detached volumes cannot rebuild — attach them with a maintenance"
  echo "    ticket on volumeattachments.longhorn.io first."
  exit 2
fi
echo "    no volume depends solely on ${NAME}"

# 2. Degraded volumes mean a rebuild is still in flight somewhere.
DEGRADED=$(kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c '
import json,sys
for x in json.load(sys.stdin)["items"]:
    st=x.get("status",{})
    if st.get("robustness")=="degraded": print(x["metadata"]["name"])
')
if [ -n "$DEGRADED" ]; then
  echo "    WARNING: volumes still degraded (rebuild in progress):"
  echo "$DEGRADED" | sed 's/^/      /'
  [ "$ASSUME_YES" = "1" ] || { echo "    re-run when healthy, or pass --yes to override"; exit 3; }
fi

# 3. etcd must survive losing this member.
MEMBERS=$(talosctl --endpoints "$API_ENDPOINT" -n "$API_ENDPOINT" etcd members 2>/dev/null | tail -n +2 | wc -l)
echo "    etcd members now: ${MEMBERS} -> after removal: $((MEMBERS-1)) (quorum needs $(( (MEMBERS-1)/2 + 1 )))"
[ "$MEMBERS" -ge 3 ] || { echo "    REFUSING: removing a member from a ${MEMBERS}-member cluster loses quorum"; exit 4; }

[ "$CHECK_ONLY" = "1" ] && { echo "==> check-only, stopping here"; exit 0; }
if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Retire ${NAME}? [type the node name to confirm] " a
  [ "$a" = "$NAME" ] || { echo "aborted"; exit 1; }
fi

echo "==> asking Longhorn to evict remaining replicas from ${NAME}"
kubectl -n longhorn-system patch nodes.longhorn.io "$NAME" --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null
for i in $(seq 1 60); do
  left=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | python3 -c '
import json,sys
node=sys.argv[1]; n=0
for x in json.load(sys.stdin)["items"]:
    if x["spec"].get("nodeID")==node and not x["spec"].get("failedAt"): n+=1
print(n)' "$NAME")
  echo "    replicas still on ${NAME}: ${left}"
  [ "$left" = "0" ] && break
  sleep 30
done

echo "==> cordon + drain"
kubectl cordon "$NAME" >/dev/null
kubectl drain "$NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=10m || \
  echo "    drain reported errors; check pods before continuing"

echo "==> leaving etcd"
ID=$(talosctl --endpoints "$API_ENDPOINT" -n "$API_ENDPOINT" etcd members 2>/dev/null | awk -v n="$NAME" '$3==n{print $2}')
if [ -n "$ID" ]; then
  # remove-member takes the hex member ID, not the hostname
  talosctl --endpoints "$API_ENDPOINT" -n "$API_ENDPOINT" etcd remove-member "$ID"
  echo "    removed etcd member ${ID}"
fi

echo "==> deleting Kubernetes node object"
kubectl delete node "$NAME" --ignore-not-found >/dev/null

if [ -n "$PVE_HOST" ] && [ -n "$VMID" ]; then
  echo "==> stopping VM ${VMID} on ${PVE_HOST} (NOT deleting it)"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${PVE_HOST}" \
    "qm shutdown ${VMID} --timeout 120 || qm stop ${VMID}; qm set ${VMID} --onboot 0; qm status ${VMID}"
  echo "    disk left intact — delete the VM yourself once you are satisfied"
fi

echo "==> ${NAME} retired. etcd members now:"
talosctl --endpoints "$API_ENDPOINT" -n "$API_ENDPOINT" etcd members 2>/dev/null | tail -n +2 | awk '{print "    "$3}'
