#!/usr/bin/env python3
"""Extract kubeconfig and talosconfig from OpenTofu state file."""
import json
import os
import sys

state_path = os.path.expanduser("~/.tofu/state/platform-productie/terraform.tfstate")
out_dir = "/tmp/kubeconfig-extract"
os.makedirs(out_dir, exist_ok=True)

try:
    with open(state_path) as f:
        state = json.load(f)
except FileNotFoundError:
    print(f"ERROR: state not found at {state_path}")
    sys.exit(1)

kubeconfig = talosconfig = None

for resource in state.get("resources", []):
    rtype = resource.get("type", "")
    rname = resource.get("name", "")
    instances = resource.get("instances", [])
    if not instances:
        continue
    content = instances[0].get("attributes", {}).get("content", "")

    if rtype == "local_sensitive_file" and rname == "kubeconfig":
        kubeconfig = content
    elif rtype == "local_sensitive_file" and rname in ("talosconfig", "talosconfig_generated"):
        if not talosconfig:
            talosconfig = content
    # Also check talos_cluster_kubeconfig resource
    elif rtype == "talos_cluster_kubeconfig":
        if not kubeconfig:
            kubeconfig = instances[0].get("attributes", {}).get("kubeconfig_raw", "")
    elif rtype in ("data.talos_client_configuration", "talos_client_configuration") and not talosconfig:
        talosconfig = instances[0].get("attributes", {}).get("talos_config", "")

if kubeconfig:
    path = f"{out_dir}/kubeconfig"
    with open(path, "w") as f:
        f.write(kubeconfig)
    os.chmod(path, 0o600)
    print(f"kubeconfig: {len(kubeconfig)} bytes -> {path}")
else:
    print("ERROR: kubeconfig not found in state")
    sys.exit(1)

if talosconfig:
    path = f"{out_dir}/talosconfig"
    with open(path, "w") as f:
        f.write(talosconfig)
    os.chmod(path, 0o600)
    print(f"talosconfig: {len(talosconfig)} bytes -> {path}")
else:
    print("WARN: talosconfig not found")
