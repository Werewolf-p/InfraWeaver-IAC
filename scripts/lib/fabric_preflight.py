#!/usr/bin/env python3
"""Decide whether a node can safely be removed, shrunk or rebooted — with numbers.

Called by scripts/fabric-preflight.sh, which does the cluster reads and passes
three files:

    fabric_preflight.py <nodes.json> <pods.json> <pdb.json>

Options come from the environment so the shell wrapper owns argument parsing:

    FP_MODE       cluster | node | sim-add | sim-resize
    FP_TARGET     node name, when FP_MODE=node
    FP_SIM        "100" for sim-add, "cp1=36" for sim-resize
    FP_JSON       "1" to emit JSON instead of a table
    FP_ETCD_HEALTHY, FP_ETCD_INFERRED, FP_HEADROOM

This module performs NO cluster calls. It is a pure function over the three
blobs, which is what makes it testable and what lets the console reuse it
against a simulated cluster.

Exit codes: 0 clear, 1 refused (a check FAILED), 2 undetermined.
Exit 2 is deliberately distinct from 0 — "I could not check" must never be
mistaken for "it is safe".
"""
from __future__ import annotations

import datetime
import json
import os
import sys

MIB = 1024 * 1024

# Talos reserves kube-reserved 2Gi + system-reserved 512Mi + an eviction margin.
# Measured against this cluster: a 24 GB VM reports 20.2 GiB allocatable and a
# 10 GB VM reports 6.4 GiB. 0.94 fits the large end; small nodes lose relatively
# more, so a simulated SMALL node is optimistic. Simulated rows are flagged.
ALLOCATABLE_FRACTION = 0.94

STATUS_ICON = {"PASS": "[ok  ]", "FAIL": "[FAIL]", "WARN": "[warn]", "SKIP": "[skip]"}


def to_mib(quantity):
    """Kubernetes quantity string to MiB.

    Returns 0.0 for anything unparsable. Callers must collect those separately:
    an unreadable request silently counted as zero reads as free capacity, which
    is the exact direction that makes a preflight approve something it should
    have refused.
    """
    if not quantity:
        return 0.0
    text = str(quantity)
    units = {
        "Ki": 1 / 1024, "Mi": 1.0, "Gi": 1024.0, "Ti": 1024.0 * 1024,
        "K": 1000 / MIB, "M": 1000 ** 2 / MIB, "G": 1000 ** 3 / MIB, "T": 1000 ** 4 / MIB,
    }
    for unit, mult in sorted(units.items(), key=lambda kv: -len(kv[0])):
        if text.endswith(unit):
            try:
                return float(text[: -len(unit)]) * mult
            except ValueError:
                return 0.0
    try:
        return float(text) / MIB
    except ValueError:
        return 0.0


def build_nodes(nodes_json):
    nodes = {}
    for item in nodes_json["items"]:
        name = item["metadata"]["name"]
        labels = item["metadata"].get("labels", {})
        conditions = {c["type"]: c["status"] for c in item["status"].get("conditions", [])}
        nodes[name] = {
            "name": name,
            "allocatable_mib": to_mib(item["status"]["allocatable"].get("memory")),
            "control_plane": "node-role.kubernetes.io/control-plane" in labels,
            "ready": conditions.get("Ready") == "True",
            "memory_pressure": conditions.get("MemoryPressure") == "True",
            "cordoned": bool(item["spec"].get("unschedulable")),
            "requests_mib": 0.0,
            "pods": 0,
            "immovable": [],
            "simulated": False,
        }
    return nodes


def attribute_pods(nodes, pods_json):
    """Fold running pods into their node's totals. Returns unparsable requests."""
    unparsable = []
    for pod in pods_json["items"]:
        node_name = pod["spec"].get("nodeName")
        if node_name not in nodes:
            continue
        namespace = pod["metadata"]["namespace"]
        pod_name = pod["metadata"]["name"]
        owner_kinds = {o.get("kind") for o in (pod["metadata"].get("ownerReferences") or [])}

        requested = 0.0
        for container in pod["spec"].get("containers", []):
            raw = container.get("resources", {}).get("requests", {}).get("memory")
            value = to_mib(raw)
            if raw and value == 0:
                unparsable.append(f"{namespace}/{pod_name}:{container['name']}={raw}")
            requested += value

        nodes[node_name]["requests_mib"] += requested
        nodes[node_name]["pods"] += 1

        # DaemonSet pods are recreated per node rather than moved: they neither
        # block a drain nor need a landing spot elsewhere.
        if "DaemonSet" in owner_kinds:
            continue

        # A pod bound to a node-local volume cannot be rescheduled. Naming these
        # up front is the difference between a planned exception and a drain that
        # stalls at 90% with no explanation of which pod is holding it.
        for volume in pod["spec"].get("volumes") or []:
            if "hostPath" in volume or "local" in volume:
                nodes[node_name]["immovable"].append(
                    f"{namespace}/{pod_name} (node-local volume)")
                break
    return unparsable


def apply_simulation(nodes, mode, arg):
    """Mutate the node table to model a proposed change. Returns a description."""
    if mode == "sim-add":
        gigabytes = float(arg)
        allocatable = gigabytes * 1024 * ALLOCATABLE_FRACTION
        key = f"<simulated +{arg}GB>"
        nodes[key] = {
            "name": key, "allocatable_mib": allocatable, "control_plane": True,
            "ready": True, "memory_pressure": False, "cordoned": False,
            "requests_mib": 0.0, "pods": 0, "immovable": [], "simulated": True,
        }
        return f"a new {arg} GB node, ~{allocatable / 1024:.1f} GiB allocatable"

    if mode == "sim-resize":
        target, _, gigabytes = arg.partition("=")
        if not gigabytes:
            raise ValueError("--simulate-resize needs node=GB, e.g. cp1=36")
        matches = [k for k in nodes if target in k]
        if not matches:
            raise ValueError(f"no node matching {target!r}")
        key = matches[0]
        before = nodes[key]["allocatable_mib"]
        after = float(gigabytes) * 1024 * ALLOCATABLE_FRACTION
        nodes[key]["allocatable_mib"] = after
        nodes[key]["simulated"] = True
        return f"{key}: {before / 1024:.1f} GiB -> {after / 1024:.1f} GiB"

    return None


def run_checks(nodes, pdb_json, unparsable, mode, target, healthy, inferred, headroom):
    checks = []
    blockers = []

    def check(check_id, title, status, detail):
        checks.append({"id": check_id, "title": title, "status": status, "detail": detail})
        if status == "FAIL":
            blockers.append(f"{check_id}: {detail}")

    total_allocatable = sum(n["allocatable_mib"] for n in nodes.values())
    total_requests = sum(n["requests_mib"] for n in nodes.values())
    largest = max(nodes.values(), key=lambda n: n["allocatable_mib"]) if nodes else None
    surviving = total_allocatable - (largest["allocatable_mib"] if largest else 0)
    needed = total_requests * (1 + headroom / 100.0)
    ratio = (needed / surviving) if surviving > 0 else float("inf")

    # -- 1. etcd quorum: the check that can end the cluster -------------------
    tolerates = (healthy - 1) // 2 if healthy else 0
    source = "inferred from control-plane node count" if inferred else "talosctl etcd members"
    if healthy == 0:
        check("etcd.quorum", "etcd quorum", "SKIP",
              "could not read etcd membership — a removal cannot be approved blind")
    elif mode == "node" and target:
        is_control_plane = nodes.get(target, {}).get("control_plane", False)
        after = healthy - 1 if is_control_plane else healthy
        after_tolerates = (after - 1) // 2 if after else 0
        if is_control_plane and after == 2:
            check("etcd.quorum", "etcd quorum", "FAIL",
                  f"removing {target} leaves 2 members, which tolerate 0 failures — "
                  f"strictly worse than 3 and no better than 1. Add a member FIRST: "
                  f"3->4->3 never drops below tolerating 1, 3->2->3 does. [{source}]")
        elif is_control_plane and after < 3:
            check("etcd.quorum", "etcd quorum", "FAIL",
                  f"removing {target} leaves {after} member(s), tolerating "
                  f"{after_tolerates}. [{source}]")
        else:
            check("etcd.quorum", "etcd quorum", "PASS",
                  f"{healthy} healthy, tolerates {tolerates}; after removal {after} "
                  f"tolerating {after_tolerates}. [{source}]")
    else:
        check("etcd.quorum", "etcd quorum", "PASS" if healthy >= 3 else "FAIL",
              f"{healthy} member(s), tolerates {tolerates}. [{source}]")

    # -- 2. N+1 capacity ------------------------------------------------------
    if ratio <= 1.0:
        check("capacity.n1", "N+1 memory", "PASS",
              f"ratio {ratio:.2f} — requests+{headroom}% ({needed / 1024:.1f} GiB) fit "
              f"in the {surviving / 1024:.1f} GiB surviving without {largest['name']}")
    else:
        check("capacity.n1", "N+1 memory", "FAIL",
              f"ratio {ratio:.2f} — {(needed - surviving) / 1024:.1f} GiB short. Losing "
              f"{largest['name']} ({largest['allocatable_mib'] / 1024:.1f} GiB) cannot be "
              f"absorbed by the other {len(nodes) - 1} node(s)")

    # -- 3 & 4. Target-specific: does its load fit, and can all of it move? ---
    if mode == "node" and target in nodes:
        node = nodes[target]
        elsewhere = sum(n["allocatable_mib"] - n["requests_mib"]
                        for name, n in nodes.items() if name != target)
        if node["requests_mib"] <= elsewhere:
            check("capacity.drain", "drain target fits elsewhere", "PASS",
                  f"{node['requests_mib'] / 1024:.1f} GiB to move, "
                  f"{elsewhere / 1024:.1f} GiB free on the other nodes")
        else:
            check("capacity.drain", "drain target fits elsewhere", "FAIL",
                  f"{node['requests_mib'] / 1024:.1f} GiB to move but only "
                  f"{elsewhere / 1024:.1f} GiB free elsewhere — the drain will stall")

        immovable = node["immovable"]
        check("placement.immovable", "node-local volumes",
              "FAIL" if immovable else "PASS",
              (f"{len(immovable)} pod(s) cannot be rescheduled: "
               + "; ".join(immovable[:5])) if immovable
              else "no pod on this node is pinned by a node-local volume")

    # -- 5. PDBs that would block an eviction ---------------------------------
    at_floor = []
    for pdb in pdb_json.get("items", []):
        status = pdb.get("status", {})
        current = status.get("currentHealthy", 0)
        desired = status.get("desiredHealthy", 0)
        if current <= desired:
            at_floor.append(f"{pdb['metadata']['namespace']}/{pdb['metadata']['name']} "
                            f"({current} healthy / {desired} desired)")
    check("placement.pdb", "PodDisruptionBudgets", "WARN" if at_floor else "PASS",
          (f"{len(at_floor)} PDB(s) are at their floor; an eviction blocks until a "
           f"replacement is Ready: " + "; ".join(at_floor[:5])) if at_floor
          else f"{len(pdb_json.get('items', []))} PDB(s), none at their floor")

    # -- 6. Never start a fabric change on a degraded cluster -----------------
    not_ready = [n["name"] for n in nodes.values() if not n["ready"]]
    pressured = [n["name"] for n in nodes.values() if n["memory_pressure"]]
    cordoned = [n["name"] for n in nodes.values() if n["cordoned"] and n["name"] != target]
    if not_ready:
        check("health.nodes", "cluster health", "FAIL", f"not Ready: {', '.join(not_ready)}")
    elif pressured:
        check("health.nodes", "cluster health", "WARN",
              f"MemoryPressure=True on {', '.join(pressured)} — that node is already "
              f"evicting, and rescheduled work can land on it")
    elif cordoned:
        check("health.nodes", "cluster health", "WARN",
              f"already cordoned: {', '.join(cordoned)} — its capacity is counted above "
              f"but the scheduler will not use it")
    else:
        check("health.nodes", "cluster health", "PASS", f"{len(nodes)} node(s) Ready")

    # -- 7. Are the numbers above trustworthy at all? -------------------------
    check("data.requests", "request quantities parsable", "WARN" if unparsable else "PASS",
          (f"{len(unparsable)} container request(s) were unparsable and counted as 0, so "
           f"the totals UNDERSTATE demand: " + "; ".join(unparsable[:5])) if unparsable
          else "every running container memory request parsed cleanly")

    # A SKIPped quorum check must block a removal. "I could not check" is not "safe".
    if mode == "node" and any(c["id"] == "etcd.quorum" and c["status"] == "SKIP" for c in checks):
        blockers.append("etcd.quorum: unverified — refusing to approve a node removal blind")

    capacity = {
        "total_allocatable_mib": round(total_allocatable, 1),
        "total_requests_mib": round(total_requests, 1),
        "headroom_pct": headroom,
        "largest_node": largest["name"] if largest else None,
        "surviving_allocatable_mib": round(surviving, 1),
        "ratio": round(ratio, 3),
        "shortfall_mib": round(max(0.0, needed - surviving), 1),
    }
    return checks, blockers, capacity


def render_table(report, checks, capacity, headroom):
    print(f"\n  fabric preflight — {report['generated_at']}")
    if report["simulation"]:
        print(f"  simulating: {report['simulation']}")
    if report["target_node"]:
        print(f"  target:     {report['target_node']}")
    print()
    print(f"  {'NODE':<28} {'ALLOC':>9} {'REQ':>9} {'USE%':>6}  CP  PODS")
    for node in report["nodes"]:
        pct = f"{node['pct']:.0f}" if node["pct"] is not None else "-"
        print(f"  {node['name']:<28} {node['allocatable_gib']:>7.1f}Gi "
              f"{node['requests_gib']:>7.1f}Gi {pct:>5}%  "
              f"{'y' if node['control_plane'] else ' ':^3} {node['pods']:>4}")
    print(f"\n  N+1: lose {capacity['largest_node']} -> "
          f"{capacity['surviving_allocatable_mib'] / 1024:.1f} GiB survives; need "
          f"{capacity['total_requests_mib'] / 1024:.1f} GiB +{headroom}% "
          f"= ratio {capacity['ratio']}")
    print()
    for check in checks:
        print(f"  {STATUS_ICON[check['status']]} {check['title']}")
        print(f"         {check['detail']}")
    print(f"\n  VERDICT: {report['verdict']}")
    if report["blockers"]:
        print("  Refused. Fix the blockers above, or change the plan:")
        for blocker in report["blockers"]:
            print(f"    - {blocker}")
    print()


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2

    with open(argv[1]) as fh:
        nodes_json = json.load(fh)
    with open(argv[2]) as fh:
        pods_json = json.load(fh)
    with open(argv[3]) as fh:
        pdb_json = json.load(fh)

    mode = os.environ.get("FP_MODE", "cluster")
    target = os.environ.get("FP_TARGET", "")
    sim_arg = os.environ.get("FP_SIM", "")
    as_json = os.environ.get("FP_JSON") == "1"
    healthy = int(os.environ.get("FP_ETCD_HEALTHY", "0"))
    inferred = os.environ.get("FP_ETCD_INFERRED") == "1"
    headroom = int(os.environ.get("FP_HEADROOM", "10"))

    nodes = build_nodes(nodes_json)
    if mode == "node" and target not in nodes:
        print(f"fabric-preflight: no such node {target!r}. Known: "
              f"{', '.join(sorted(nodes))}", file=sys.stderr)
        return 2

    unparsable = attribute_pods(nodes, pods_json)
    try:
        simulation = apply_simulation(nodes, mode, sim_arg)
    except ValueError as exc:
        print(f"fabric-preflight: {exc}", file=sys.stderr)
        return 2

    checks, blockers, capacity = run_checks(
        nodes, pdb_json, unparsable, mode, target, healthy, inferred, headroom,
    )

    report = {
        "generated_at": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds"),
        "mode": mode,
        "target_node": target or None,
        "simulation": simulation,
        "capacity": capacity,
        "etcd": {"healthy": healthy,
                 "tolerates": (healthy - 1) // 2 if healthy else 0,
                 "inferred": inferred},
        "nodes": [
            {
                "name": n["name"],
                "allocatable_gib": round(n["allocatable_mib"] / 1024, 2),
                "requests_gib": round(n["requests_mib"] / 1024, 2),
                "pct": round(100 * n["requests_mib"] / n["allocatable_mib"], 1)
                       if n["allocatable_mib"] else None,
                "control_plane": n["control_plane"],
                "ready": n["ready"],
                "cordoned": n["cordoned"],
                "pods": n["pods"],
                "immovable": len(n["immovable"]),
                "simulated": n["simulated"],
            }
            for n in sorted(nodes.values(), key=lambda x: -x["allocatable_mib"])
        ],
        "checks": checks,
        "blockers": blockers,
        "verdict": "REFUSED" if blockers else "CLEAR",
    }

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        render_table(report, checks, capacity, headroom)

    return 1 if blockers else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
