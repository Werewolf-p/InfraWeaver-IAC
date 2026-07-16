#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/validate-netpol-ports.sh — Catch NetworkPolicy port/pod-port mismatches.
#
# WHY: A (Cilium)NetworkPolicy `ports[].port` matches the DESTINATION POD port —
# i.e. the container's `containerPort`, AFTER Service translation — NOT the
# Service `port`. Putting the Service port (e.g. 80/443) where the pod port
# belongs (e.g. 9000/9443) is silently inert under a non-enforcing CNI (flannel)
# and only starts dropping traffic once an enforcing CNI (Cilium) is switched on.
# That is exactly how `allow-traefik-ingress` (ns authentik) broke every SSO
# front-channel login: it allowed 80/9300 but authentik-server listens on
# 9000/9443. This gate makes that class of mismatch fail validation instead of
# failing silently in production.
#
# WHAT IT CHECKS (purely from in-repo manifests — no cluster access):
#   A) Service-port footgun (high confidence): a NetworkPolicy ingress allows a
#      numeric port P that equals the front `port` of a Service fronting the same
#      pods, while that Service's `targetPort` is a DIFFERENT numeric port. The
#      policy almost certainly meant the targetPort (the real pod port).
#   B) containerPort coverage: when the policy selects a workload defined in-repo
#      (Deployment/StatefulSet/DaemonSet/Pod/Job/CronJob) that declares
#      containerPorts, every numeric ingress port must be one of them.
#
# Conservative by design: when the target pods are NOT defined in-repo (e.g. a
# Helm-managed app whose Service/Deployment isn't committed), the policy is
# SKIPPED — the gate ratchets the resolvable class without false-flagging.
#
# Usage: scripts/validate-netpol-ports.sh [--repo-root <path>]
# Exit non-zero on any mismatch (CI-friendly).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${1:-}" == "--repo-root" ]] && REPO_ROOT="$2"
cd "$REPO_ROOT" || exit 1

echo "── NetworkPolicy port vs pod-port gate ───────────────────────────────────"

FINDINGS="$(python3 - << 'PY'
import glob, os, sys
try:
    import yaml
except Exception:
    print("__NO_YAML__")
    sys.exit(0)

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}

# Known pod (container) ports for Helm-managed workloads whose Deployment/Service
# is NOT committed to this repo, so the scanner cannot otherwise resolve them.
# Without this, the very bug this gate exists to prevent — authentik's
# allow-traefik-ingress allowing 80 instead of 9000/9443 — would be unverifiable
# from repo files alone. Add an entry when you add a NetworkPolicy in front of a
# Helm app that has no committed workload. Each entry is treated exactly like an
# in-repo workload for the containerPort-coverage check.
# Format: {"ns","selector":{labels}, "ports":[containerPorts]}
KNOWN_POD_PORTS = [
    # authentik-server (goauthentik/authentik Helm chart): http 9000, https 9443,
    # metrics 9300. Service maps 80->9000 / 443->9443. (memory: the SSO outage.)
    {"ns": "authentik",
     "selector": {"app.kubernetes.io/name": "authentik"},
     "ports": [9000, 9443, 9300]},
]

services = []   # {ns, selector:{}, ports:[{port:int, targetPort:int|str|None}]}
workloads = []  # {ns, labels:{}, ports:set(int), names:{name->int}}
netpols = []    # {ns, name, file, selector:{}, ingress:[{ports:[int]}]}

def as_int(v):
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.isdigit():
        return int(v)
    return None

def pod_template_labels(spec):
    tmpl = (spec or {}).get("template") or {}
    return ((tmpl.get("metadata") or {}).get("labels")) or {}

def container_ports(spec):
    nums, names = set(), {}
    tmpl = (spec or {}).get("template") or {}
    pspec = (tmpl.get("spec")) or {}
    for c in (pspec.get("containers") or []) + (pspec.get("initContainers") or []):
        for p in (c.get("ports") or []):
            n = as_int(p.get("containerPort"))
            if n is not None:
                nums.add(n)
                if p.get("name"):
                    names[p["name"]] = n
    return nums, names

for f in glob.glob("kubernetes/**/*.yaml", recursive=True):
    if "node_modules" in f:
        continue
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        ns = meta.get("namespace")
        spec = d.get("spec") or {}
        if kind == "Service":
            sel = spec.get("selector") or {}
            ports = []
            for p in (spec.get("ports") or []):
                port = as_int(p.get("port"))
                tp = p.get("targetPort")
                ports.append({"port": port, "targetPort": as_int(tp) if as_int(tp) is not None else tp})
            if sel:
                services.append({"ns": ns, "selector": sel, "ports": ports})
        elif kind in WORKLOAD_KINDS:
            nums, names = container_ports(spec)
            workloads.append({"ns": ns, "labels": pod_template_labels(spec), "ports": nums, "names": names})
        elif kind == "CronJob":
            jt = (spec.get("jobTemplate") or {}).get("spec") or {}
            nums, names = container_ports(jt)
            workloads.append({"ns": ns, "labels": pod_template_labels(jt), "ports": nums, "names": names})
        elif kind == "Pod":
            nums, names = set(), {}
            for c in (spec.get("containers") or []):
                for p in (c.get("ports") or []):
                    n = as_int(p.get("containerPort"))
                    if n is not None:
                        nums.add(n)
                        if p.get("name"):
                            names[p["name"]] = n
            workloads.append({"ns": ns, "labels": meta.get("labels") or {}, "ports": nums, "names": names})
        elif kind == "NetworkPolicy":   # networking.k8s.io/v1 (k8s-native)
            sel = (spec.get("podSelector") or {}).get("matchLabels") or {}
            ingress = []
            for rule in (spec.get("ingress") or []):
                pts = [as_int(p.get("port")) for p in (rule.get("ports") or [])]
                ingress.append([p for p in pts if p is not None])
            netpols.append({"ns": ns, "name": meta.get("name"), "file": f,
                            "selector": sel, "ingress": ingress})

# Fold the known-port registry in as if it were an in-repo workload.
for e in KNOWN_POD_PORTS:
    workloads.append({"ns": e["ns"], "labels": e["selector"],
                      "ports": set(e["ports"]), "names": {}})

def compatible(a, b):
    """Two label selectors target an overlapping pod set: no conflicting keys,
    and one refines the other (subset) — conservative to avoid false matches."""
    if not a or not b:
        return False
    for k in set(a) & set(b):
        if a[k] != b[k]:
            return False
    ka, kb = set(a), set(b)
    return ka <= kb or kb <= ka

def selects(pod_labels, selector):
    """Does `selector` (matchLabels) select a pod with `pod_labels`?"""
    if not selector:
        return False
    return all(pod_labels.get(k) == v for k, v in selector.items())

violations = []
for np in netpols:
    allowed = sorted({p for rule in np["ingress"] for p in rule})
    if not allowed:
        continue

    # Services in the same namespace that front this policy's pods.
    fronting = [s for s in services if s["ns"] == np["ns"] and compatible(s["selector"], np["selector"])]
    # Workloads in the same namespace this policy selects.
    sel_workloads = [w for w in workloads if w["ns"] == np["ns"] and selects(w["labels"], np["selector"])]

    # (A) Service-port footgun.
    for s in fronting:
        for pe in s["ports"]:
            fp, tp = pe["port"], pe["targetPort"]
            if fp in allowed and isinstance(tp, int) and tp != fp:
                violations.append(
                    f"{np['file']}::{np['name']} (ns {np['ns']}): ingress allows port {fp}, "
                    f"but that is a Service FRONT port (Service maps {fp}->{tp}); "
                    f"NetworkPolicy must allow the pod port {tp}.")

    # (B) containerPort coverage — only when in-repo workloads declare ports.
    declared = set().union(*[w["ports"] for w in sel_workloads]) if sel_workloads else set()
    named = {}
    for w in sel_workloads:
        named.update(w["names"])
    if declared:
        for p in allowed:
            if p not in declared and p not in named.values():
                violations.append(
                    f"{np['file']}::{np['name']} (ns {np['ns']}): ingress allows port {p}, "
                    f"but no selected workload declares it as a containerPort "
                    f"(declared: {sorted(declared)}).")

for v in sorted(set(violations)):
    print(v)
PY
)"

if [[ "$FINDINGS" == "__NO_YAML__" ]]; then
  echo "  PyYAML not available — skipping (CI installs it)"
  exit 0
fi

if [[ -n "$FINDINGS" ]]; then
  echo "  ✗ NetworkPolicy port mismatch(es) — these allow a Service/front port where the"
  echo "    POD port is required; inert under flannel, silently drops traffic under Cilium:"
  echo "$FINDINGS" | sed 's/^/      /'
  echo "──────────────────────────────────────────────────────────────────────────"
  echo "NetworkPolicy port validation FAILED"
  exit 1
fi

echo "  ✓ no NetworkPolicy port/pod-port mismatches (resolvable from in-repo manifests)"
echo "──────────────────────────────────────────────────────────────────────────"
echo "NetworkPolicy port validation PASSED"
exit 0
