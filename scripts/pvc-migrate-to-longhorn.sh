#!/usr/bin/env bash
# pvc-migrate-to-longhorn.sh — move a node-pinned local-path PVC onto Longhorn.
#
# A local-path PVC is bound to one node forever. If that node goes away the
# workload cannot start anywhere else, which makes any "the cluster survives a
# host failure" claim untrue for that app. This converts one such PVC to a
# replicated Longhorn volume, keeping the PVC name so the owning StatefulSet or
# Deployment is unchanged.
#
# A StatefulSet's volumeClaimTemplate is immutable, but a StatefulSet only
# creates a PVC when one does not already exist. So we pre-create a PVC with
# the original name backed by Longhorn, and the workload adopts it on start.
#
# Usage:
#   scripts/pvc-migrate-to-longhorn.sh --ns authentik --pvc data-authentik-postgresql-0 \
#       --workload statefulset/authentik-postgresql [--storage-class longhorn] [--yes]
#
#   --dry-run   print the plan and exit
#
# The original PV is retained (Released), never deleted. Roll back by deleting
# the new PVC and re-binding the old PV.
set -euo pipefail

NS=""; PVC=""; WORKLOAD=""; SC="longhorn"; ASSUME_YES=0; DRY=0; ARGO_APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    --pvc) PVC="$2"; shift 2 ;;
    --workload) WORKLOAD="$2"; shift 2 ;;
    --storage-class) SC="$2"; shift 2 ;;
    --argocd-app) ARGO_APP="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NS" ] && [ -n "$PVC" ] && [ -n "$WORKLOAD" ] || {
  echo "usage: --ns <ns> --pvc <pvc> --workload <kind/name>" >&2; exit 1; }

OLD_PV=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
SIZE=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}')
NODE=$(kubectl get pv "$OLD_PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || echo "")
REPLICAS=$(kubectl -n "$NS" get "$WORKLOAD" -o jsonpath='{.spec.replicas}')

echo "==> plan"
echo "    ${NS}/${PVC}  size=${SIZE}  currently pinned to: ${NODE:-<none>}"
echo "    old PV: ${OLD_PV}  ->  new ${SC} volume, same PVC name"
echo "    workload ${WORKLOAD} (replicas=${REPLICAS}) will be stopped during the copy"
[ "$DRY" = "1" ] && exit 0
if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Proceed? [type the pvc name] " a; [ "$a" = "$PVC" ] || { echo aborted; exit 1; }
fi

TMP_PVC="${PVC}-lh-migrate"

# ArgoCD with selfHeal reverts the scale-to-0 within seconds, so the workload
# keeps its RWO volume mounted and the copy Job can never attach.
#
# ⚠️ Patching the Application does NOT hold. Every Application here is generated
# by an ApplicationSet (appset-core*.yaml), and the appset controller re-applies
# spec.syncPolicy.automated within ~20s. On 2026-08-18 that raced a live
# migration: ArgoCD scaled n8n back up mid-copy, the new pod re-mounted the PVC
# that was already pending deletion, and kubernetes.io/pvc-protection then held
# that PVC in Terminating indefinitely. The workload was left down and the PVC
# had to be recovered by hand. The same applies to ignoreDifferences and to any
# other field on the Application — the appset owns all of it.
#
# So suspend the CONTROLLER instead. Scaling argocd-application-controller to 0
# is self-referential: with it stopped nothing is reconciling, so nothing can
# undo the scale-down — including the scale-down of the controller itself. It is
# a normal maintenance action and fully reversible. Reconciliation pauses
# cluster-wide for the few minutes a copy takes; the trap restores it on every
# exit path, including failure and Ctrl-C.
ARGO_CTRL_STS="argocd-application-controller"
ARGO_CTRL_REPLICAS=""
restore_argocd() {
  [ -n "$ARGO_CTRL_REPLICAS" ] || return 0
  kubectl -n argocd scale statefulset "$ARGO_CTRL_STS" \
    --replicas="$ARGO_CTRL_REPLICAS" >/dev/null 2>&1 \
    && echo "    restored ${ARGO_CTRL_STS} to ${ARGO_CTRL_REPLICAS} replica(s)"
}
if [ -n "$ARGO_APP" ]; then
  ARGO_CTRL_REPLICAS=$(kubectl -n argocd get statefulset "$ARGO_CTRL_STS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  if [ -z "$ARGO_CTRL_REPLICAS" ]; then
    echo "!! cannot read ${ARGO_CTRL_STS} replicas — refusing to run blind" >&2
    echo "   (without a reliable pause, ArgoCD deadlocks the PVC deletion)" >&2
    exit 1
  fi
  # Trap BEFORE scaling down, so an interrupt between the two still restores.
  trap restore_argocd EXIT INT TERM
  echo "==> pausing ArgoCD reconciliation (${ARGO_CTRL_STS} ${ARGO_CTRL_REPLICAS} -> 0)"
  kubectl -n argocd scale statefulset "$ARGO_CTRL_STS" --replicas=0 >/dev/null
  for _ in $(seq 1 30); do
    [ "$(kubectl -n argocd get pods \
         -l app.kubernetes.io/name=argocd-application-controller \
         --no-headers 2>/dev/null | grep -c .)" = "0" ] && break
    sleep 2
  done
  echo "    reconciliation paused"
fi

echo "==> 1/6 stopping ${WORKLOAD}"
kubectl -n "$NS" scale "$WORKLOAD" --replicas=0
for i in $(seq 1 30); do
  n=$(kubectl -n "$NS" get pods -o json | python3 -c '
import json,sys
pvc=sys.argv[1]; n=0
for p in json.load(sys.stdin)["items"]:
    for v in p["spec"].get("volumes",[]):
        c=(v.get("persistentVolumeClaim") or {}).get("claimName")
        if c==pvc and p["status"]["phase"] in ("Running","Pending"): n+=1
print(n)' "$PVC")
  [ "$n" = "0" ] && break
  echo "    waiting for ${n} pod(s) using ${PVC} to stop"; sleep 10
done

echo "==> 2/6 creating Longhorn volume ${TMP_PVC} (${SIZE})"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TMP_PVC}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  resources:
    requests:
      storage: ${SIZE}
EOF

echo "==> 3/6 copying data (old -> new)"
kubectl -n "$NS" delete job "migrate-${PVC}" --ignore-not-found >/dev/null
# Reuse the owning workload's securityContext. Two reasons: the namespace may
# enforce PodSecurity "restricted" (which rejects a default root Job), and
# copying as the app's own uid/gid keeps file ownership the app expects.
SECCTX=$(kubectl -n "$NS" get "$WORKLOAD" -o json | python3 -c '
import json,sys
s=json.load(sys.stdin)["spec"]["template"]["spec"]
pod=s.get("securityContext") or {}
pod.setdefault("runAsNonRoot", True)
pod.setdefault("seccompProfile", {"type":"RuntimeDefault"})
if "runAsUser" not in pod:
    for c in s.get("containers",[]):
        u=(c.get("securityContext") or {}).get("runAsUser")
        if u is not None: pod["runAsUser"]=u; break
    else: pod["runAsUser"]=1000
pod.setdefault("fsGroup", pod["runAsUser"])
print(json.dumps(pod))
')
NODESEL=""
[ -n "$NODE" ] && NODESEL="      nodeSelector: {kubernetes.io/hostname: ${NODE}}"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate-${PVC}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      securityContext: ${SECCTX}
${NODESEL}
      containers:
        - name: copy
          image: busybox:1.36
          command: ["sh","-c","cp -a /src/. /dst/ && sync && du -sh /dst"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits: { cpu: "500m", memory: "256Mi" }
          volumeMounts:
            - { name: src, mountPath: /src }
            - { name: dst, mountPath: /dst }
      volumes:
        - name: src
          persistentVolumeClaim: { claimName: ${PVC} }
        - name: dst
          persistentVolumeClaim: { claimName: ${TMP_PVC} }
EOF
kubectl -n "$NS" wait --for=condition=complete "job/migrate-${PVC}" --timeout=30m
kubectl -n "$NS" logs "job/migrate-${PVC}" | tail -5 | sed 's/^/    /'

NEW_PV=$(kubectl -n "$NS" get pvc "$TMP_PVC" -o jsonpath='{.spec.volumeName}')

echo "==> 4/6 retaining both PVs so nothing is deleted on unbind"
kubectl patch pv "$OLD_PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
kubectl patch pv "$NEW_PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null

echo "==> 5/6 rebinding ${PVC} to the Longhorn volume"
# The completed Job's pod still references both PVCs, and the pvc-protection
# finalizer will keep them Terminating forever until it is gone.
kubectl -n "$NS" delete job "migrate-${PVC}" --wait=true >/dev/null
kubectl -n "$NS" delete pvc "$TMP_PVC" --wait=true >/dev/null
kubectl -n "$NS" delete pvc "$PVC" --wait=true >/dev/null
kubectl patch pv "$NEW_PV" --type=json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null 2>&1 || true
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  volumeName: ${NEW_PV}
  resources:
    requests:
      storage: ${SIZE}
EOF
for i in $(seq 1 20); do
  [ "$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}')" = "Bound" ] && break
  sleep 5
done

echo "==> 6/6 restarting ${WORKLOAD}"
kubectl -n "$NS" scale "$WORKLOAD" --replicas="${REPLICAS:-1}"
echo "    old PV ${OLD_PV} retained (Released) — delete it manually once verified"
kubectl -n "$NS" get pvc "$PVC" | sed 's/^/    /'
