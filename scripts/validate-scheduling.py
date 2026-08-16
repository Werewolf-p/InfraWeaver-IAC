#!/usr/bin/env python3
"""validate-scheduling.py — keep placement rules bound to something real.

On 2026-08-15 `talos-prod-cp2` was deleted. Eight places in this repo said
"keep this workload off the far node"; every one of them said it either as a
PREFERENCE or by NODE NAME, and most named cp2. The result was not an error —
it was silence. The authentik server moved to zone=hypatia (a Hetzner box
~15 ms away across a stretched VLAN) and Traefik p95 for authentik went
0.270 s -> 3.765 s. Nothing in git had changed.

Two failure modes produced that, and this gate blocks both.

  STALE  A rule naming a node that no longer exists still parses, still renders,
         still passes kubeconform, and does nothing. `nodeAffinity` terms that
         match no node do not error — they just stop contributing. A REQUIRED
         rule silently narrows (OpenBao's `hostname In [cp2, cp3]` became a hard
         pin to cp3 alone, one replica, no fallback); a PREFERRED one silently
         evaporates.
           → G1/G2: every hostname and zone a scheduling rule names must exist
             in scripts/fleet-topology.yaml.

  SOFT   A zone is a WAN boundary, not a hint. `preferred...` on a zone key
         reads as intent and behaves as a suggestion: the scheduler's resource
         scoring outweighs a weight-100 preference the moment the near nodes
         fill up, which is exactly what happened. Node-level preferences remain
         fine — a hostname hint is honestly a hint.
           → G3: no preferredDuringSchedulingIgnoredDuringExecution keyed on
             topology.kubernetes.io/zone. Say required, or say nothing.

  G4     A `zone NotIn [...]` rule must exclude exactly the remote zones the
         fleet declares. Excluding a subset is a rule that reads like protection
         and isn't; excluding a zone that is local is an outage waiting for the
         next capacity crunch.

WHAT IS DELIBERATELY NOT CHECKED: which workloads are latency-bound. That is a
judgement call and lives in docs/SCHEDULING-ZONES.md. This gate only guarantees
that whatever is written down still binds to a node that exists — the property
that was missing, and the one a machine can actually verify.

Usage:  python3 scripts/validate-scheduling.py [--repo-root PATH] [--list]
Exit 0 clean, 1 on any finding.
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("validate-scheduling: PyYAML is required\n")
    sys.exit(1)

HOSTNAME_KEY = "kubernetes.io/hostname"
ZONE_KEY = "topology.kubernetes.io/zone"
PREFERRED = "preferredDuringSchedulingIgnoredDuringExecution"
REQUIRED = "requiredDuringSchedulingIgnoredDuringExecution"

# Node names appear legitimately in places that are NOT scheduling rules and must
# not be gated: a PersistentVolume's own `spec.nodeAffinity` is written by the
# local-path provisioner and describes where a disk physically is, and the
# automation CronJobs template a target node name into a patch at runtime.
SKIP_PATH_FRAGMENTS = (
    "kubernetes/core/argocd/manifests/node-automation.yaml",  # rebalancer templates ${target_node}
)


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def walk_yaml(root: str, subdirs: tuple[str, ...]):
    for sub in subdirs:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, sub)):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in sorted(filenames):
                if name.endswith((".yaml", ".yml")):
                    yield os.path.join(dirpath, name)


def load_docs(path: str):
    """Parse a file into dicts. Helm values files are plain YAML; a few embed a
    scheduling block as a STRING (openbao's `affinity: |`), so string values are
    re-parsed too — a rule hidden inside a template string is still a rule."""
    text = read(path)
    docs = []
    try:
        for doc in yaml.safe_load_all(text):
            if doc is not None:
                docs.append(doc)
    except yaml.YAMLError:
        return []
    return docs


def iter_nodes(obj, path=()):
    """Yield (breadcrumb, node) for every dict/list in the tree, re-entering
    strings that themselves parse as YAML mappings."""
    if isinstance(obj, dict):
        yield path, obj
        for k, v in obj.items():
            yield from iter_nodes(v, path + (str(k),))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from iter_nodes(v, path + (f"[{i}]",))
    elif isinstance(obj, str) and ("nodeAffinity" in obj or "nodeSelector" in obj):
        try:
            inner = yaml.safe_load(obj)
        except yaml.YAMLError:
            return
        if isinstance(inner, (dict, list)):
            yield from iter_nodes(inner, path + ("<inline>",))


def collect(root: str):
    """Return findings as (kind, file, breadcrumb, detail)."""
    fleet = yaml.safe_load(read(os.path.join(root, "scripts", "fleet-topology.yaml")))
    known_nodes = set(fleet.get("nodes") or {})
    retired = fleet.get("retired") or {}
    known_zones = set(fleet.get("zones") or {})
    remote_zones = set(fleet.get("remote_zones") or [])

    findings: list[tuple[str, str, str, str]] = []
    seen: list[tuple[str, str, str]] = []

    for path in walk_yaml(root, ("kubernetes",)):
        rel = os.path.relpath(path, root)
        if any(frag in rel for frag in SKIP_PATH_FRAGMENTS):
            continue
        for doc in load_docs(path):
            # A PersistentVolume's nodeAffinity describes a disk, not a policy.
            if isinstance(doc, dict) and doc.get("kind") == "PersistentVolume":
                continue
            for crumb, node in iter_nodes(doc):
                where = "/".join(crumb) or "<root>"

                # nodeSelector: {kubernetes.io/hostname: <node>}
                sel = node.get("nodeSelector")
                if isinstance(sel, dict) and HOSTNAME_KEY in sel:
                    value = str(sel[HOSTNAME_KEY])
                    seen.append((rel, f"{where}/nodeSelector", value))
                    if value not in known_nodes:
                        findings.append(("G1", rel, f"{where}.nodeSelector", value))

                # matchExpressions blocks, wherever they appear
                for expr in node.get("matchExpressions") or []:
                    if not isinstance(expr, dict):
                        continue
                    key, op = expr.get("key"), expr.get("operator")
                    values = [str(v) for v in (expr.get("values") or [])]
                    if key == HOSTNAME_KEY:
                        seen.append((rel, where, f"hostname {op} {values}"))
                        for v in values:
                            if v not in known_nodes:
                                findings.append(("G1", rel, where, v))
                    elif key == ZONE_KEY:
                        seen.append((rel, where, f"zone {op} {values}"))
                        for v in values:
                            if v not in known_zones:
                                findings.append(("G2", rel, where, v))
                        if PREFERRED in crumb:
                            findings.append(("G3", rel, where, f"zone {op} {values}"))
                        if op == "NotIn" and set(values) != remote_zones:
                            findings.append(
                                ("G4", rel, where, f"excludes {sorted(values)}, fleet says {sorted(remote_zones)}")
                            )
    return findings, seen, retired, known_nodes, known_zones


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--list", action="store_true", help="print every scheduling rule found")
    args = ap.parse_args()
    root = os.path.abspath(args.repo_root)

    findings, seen, retired, nodes, zones = collect(root)

    if args.list:
        print(f"==> fleet: nodes={sorted(nodes)} zones={sorted(zones)}")
        print(f"==> {len(seen)} node/zone scheduling rules found\n")
        for rel, where, detail in seen:
            print(f"  {rel}\n      {where}: {detail}")
        print()

    if not findings:
        print(f"✅ scheduling: {len(seen)} placement rules, all bound to a node/zone that exists")
        return 0

    messages = {
        "G1": "names a node that is not in the fleet",
        "G2": "names a zone that is not in the fleet",
        "G3": "expresses a ZONE rule as a preference",
        "G4": "excludes the wrong set of zones",
    }
    print("\n❌ scheduling rules that do not bind:\n")
    for kind, rel, where, detail in findings:
        note = ""
        if kind == "G1" and detail in retired:
            note = f"  (retired {retired[detail].get('retired')})"
        print(f"  [{kind}] {rel}")
        print(f"        {where}")
        print(f"        {messages[kind]}: {detail}{note}")
    print(
        "\n  G1/G2 — a rule matching no node does not error, it just stops working.\n"
        "          Update scripts/fleet-topology.yaml if the fleet changed, or fix\n"
        "          the rule if the node is gone.\n"
        "  G3    — a zone is a WAN boundary, not a hint. Use\n"
        "          requiredDuringSchedulingIgnoredDuringExecution, or drop the rule.\n"
        "  G4    — say `zone NotIn [<remote_zones>]` exactly, so adding a second\n"
        "          remote site updates every latency-bound workload at once.\n"
        "  Policy: docs/SCHEDULING-ZONES.md\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
