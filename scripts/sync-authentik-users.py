#!/usr/bin/env python3
"""
sync-authentik-users.py — Generate a Django shell script from users.yaml
and print it to stdout for piping into `ak shell`.

Group resolution order:
  1. If user has explicit `authentik_groups` list → use that
  2. Otherwise derive from `access_level`:
       admin        → platform-admins, authentik Admins, platform-users
       platform-user → platform-users

Usage:
  python3 .github/scripts/sync-authentik-users.py > /tmp/ak-sync.py
  kubectl exec -n authentik <worker-pod> -- ak shell < /tmp/ak-sync.py
"""
import sys
import yaml

# Default group sets per access_level (used when authentik_groups not set)
ACCESS_LEVEL_GROUPS = {
    "admin": ["platform-admins", "authentik Admins", "platform-users"],
    "platform-user": ["platform-users"],
}

with open("users.yaml") as f:
    config = yaml.safe_load(f)

users = config.get("users", {})
print(f"# Auto-generated group sync from users.yaml — {list(users.keys())}", file=sys.stderr)

lines = ["from authentik.core.models import User, Group\n"]
for username, udata in users.items():
    explicit = udata.get("authentik_groups")
    if explicit:
        groups = explicit
    else:
        level = udata.get("access_level", "platform-user")
        groups = ACCESS_LEVEL_GROUPS.get(level, ["platform-users"])

    groups_repr = repr(groups)
    lines.append(
        f"try:\n"
        f"    u = User.objects.get(username={repr(username)})\n"
        f"    desired = {groups_repr}\n"
        f"    for g in desired:\n"
        f"        grp, _ = Group.objects.get_or_create(name=g)\n"
        f"        grp.users.add(u)\n"
        f"    print('OK: {username} -> ' + str(desired))\n"
        f"except User.DoesNotExist:\n"
        f"    print('WARN: {username} not found in Authentik (blueprint may not have synced yet)')\n"
    )

print("\n".join(lines))
