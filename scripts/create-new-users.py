#!/usr/bin/env python3
"""
create-new-users.py — For each new user (from new_users JSON list), read their
config from users.yaml and their password from the K8s authentik-secrets secret,
then print an ak shell script (to stdout) that creates or updates the user.

Usage (called by apply-changes.yml):
  python3 .github/scripts/create-new-users.py <worker-pod> <kubeconfig> <new-users-json>
  | kubectl exec -i -n authentik <worker-pod> -- ak shell

Arguments:
  worker_pod    — name of the Authentik worker pod
  kubeconfig    — path to kubeconfig file
  new_users_json — JSON array of new usernames, e.g. '["testuser"]'
"""
import base64
import binascii
import json
import os
import subprocess
import sys

import yaml

worker_pod = sys.argv[1] if len(sys.argv) > 1 else ""
kubeconfig = sys.argv[2] if len(sys.argv) > 2 else ""
new_users_raw = sys.argv[3] if len(sys.argv) > 3 else "[]"

try:
    new_usernames = json.loads(new_users_raw)
except json.JSONDecodeError as exc:
    # Falling back to [] here used to print "No new users" and exit 0 — a
    # malformed argument reported success and silently created nobody.
    print(f"ERROR: argv[3] is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not new_usernames:
    print("# No new users — nothing to create")
    sys.exit(0)

with open("users.yaml") as f:
    config = yaml.safe_load(f)
all_users = config.get("users", {})

# Read passwords from K8s secret for each new user
def get_k8s_secret_value(kubeconfig: str, secret_name: str, namespace: str, key: str) -> str:
    """Read a base64-encoded value from a K8s secret and return decoded string."""
    cmd = [
        "kubectl", "--kubeconfig", kubeconfig, "--insecure-skip-tls-verify",
        "get", "secret", secret_name, "-n", namespace,
        f"-o=jsonpath={{.data.{key}}}",
    ]
    # check=False: a missing secret is an expected outcome here, handled by the
    # empty-stdout branch below rather than by an exception.
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    encoded = result.stdout.strip()
    if not encoded:
        return ""
    try:
        return base64.b64decode(encoded).decode()
    except (binascii.Error, UnicodeDecodeError) as exc:
        print(f"WARN: secret {namespace}/{secret_name} key {key} is not "
              f"decodable base64: {exc}", file=sys.stderr)
        return ""

lines = [
    "import base64",
    "from authentik.core.models import User",
]

for username in new_usernames:
    udata = all_users.get(username, {})
    name = udata.get("name", username)
    email = udata.get("email", f"{username}@{os.environ.get('BASE_DOMAIN', 'example.com')}")
    secret_key = f"{username}-password"
    pw = get_k8s_secret_value(kubeconfig, "authentik-secrets", "authentik", secret_key)
    pw_b64 = base64.b64encode(pw.encode()).decode() if pw else ""

    lines.append(f"""
try:
    obj, created = User.objects.get_or_create(
        username={username!r},
        defaults={{"name": {name!r}, "email": {email!r}, "is_active": True}},
    )
    if not created:
        obj.name = {name!r}
        obj.email = {email!r}
        obj.is_active = True
    if {pw_b64!r}:
        obj.set_password(base64.b64decode({pw_b64!r}).decode())
    obj.save()
    action = "created" if created else "updated"
    pw_status = "password set" if {pw_b64!r} else "WARNING: no password (missing from secret)"
    print(f"OK: {username} {{action}} — {{pw_status}}")
except Exception as e:
    print(f"ERR: {username}: {{e}}")
""")

print("\n".join(lines))
