#!/usr/bin/env python3
"""
sync-authentik-users-api.py — Sync group memberships via Authentik REST API.

Used when Authentik is already running (not a fresh deployment).
Preferred over kubectl exec ak shell because it:
  - Works during rolling restarts (just needs 1 healthy pod)
  - Doesn't risk OOM-killing the worker with a heavy Django shell load
  - Is idempotent and safe to retry

Environment variables:
  AK_TOKEN  — Authentik bootstrap API token (from authentik-secrets k8s secret)
  AK_URL    — Authentik base URL (e.g. https://auth.example.com)

Group resolution order (same as sync-authentik-users.py):
  1. If user has explicit authentik_groups list → use that
  2. Otherwise derive from access_level:
       admin         → platform-admins, authentik Admins, platform-users
       platform-user → platform-users
"""
import os
import sys
import json
import yaml
try:
    import urllib.request
    import urllib.parse
    import urllib.error
except ImportError:
    sys.exit("stdlib urllib not available")

AK_TOKEN = os.environ.get("AK_TOKEN", "")
AK_URL = os.environ.get("AK_URL", f"https://auth.{os.environ.get('BASE_DOMAIN', 'example.com')}").rstrip("/")

if not AK_TOKEN:
    sys.exit("ERROR: AK_TOKEN not set")

ACCESS_LEVEL_GROUPS = {
    "admin": ["platform-admins", "authentik Admins", "platform-users"],
    "platform-user": ["platform-users"],
}


def ak_get(path: str) -> dict:
    url = f"{AK_URL}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {AK_TOKEN}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def ak_post(path: str, body: dict) -> dict:
    url = f"{AK_URL}{path}"
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {AK_TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def get_or_create_group(name: str, group_cache: dict) -> str | None:
    if name in group_cache:
        return group_cache[name]
    encoded = urllib.parse.quote(name)
    results = ak_get(f"/api/v3/core/groups/?name={encoded}&page_size=1").get("results", [])
    if results:
        pk = results[0]["pk"]
        group_cache[name] = pk
        return pk
    # Create group
    try:
        resp = ak_post("/api/v3/core/groups/", {"name": name})
        pk = resp.get("pk")
        if pk:
            group_cache[name] = pk
            return pk
    except urllib.error.HTTPError as e:
        print(f"  WARN: failed to create group '{name}': {e}", file=sys.stderr)
    return None


def get_user_pk(username: str, user_cache: dict) -> str | None:
    if username in user_cache:
        return user_cache[username]
    encoded = urllib.parse.quote(username)
    results = ak_get(f"/api/v3/core/users/?username={encoded}&page_size=1").get("results", [])
    if results:
        pk = results[0]["pk"]
        user_cache[username] = pk
        return pk
    return None


def add_user_to_group(group_pk: str, user_pk: str) -> bool:
    try:
        ak_post(f"/api/v3/core/groups/{group_pk}/add_user/", {"pk": user_pk})
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False  # already in group or group gone
        raise


with open("users.yaml") as f:
    config = yaml.safe_load(f)

users = config.get("users", {})
group_cache: dict = {}
user_cache: dict = {}
ok_count = 0
warn_count = 0

for username, udata in users.items():
    explicit = udata.get("authentik_groups")
    if explicit:
        desired_groups = explicit
    else:
        level = udata.get("access_level", "platform-user")
        desired_groups = ACCESS_LEVEL_GROUPS.get(level, ["platform-users"])

    user_pk = get_user_pk(username, user_cache)
    if not user_pk:
        print(f"WARN: {username} not found in Authentik (blueprint may not have synced yet)")
        warn_count += 1
        continue

    added = []
    for group_name in desired_groups:
        gp = get_or_create_group(group_name, group_cache)
        if gp:
            add_user_to_group(gp, user_pk)
            added.append(group_name)

    print(f"OK: {username} → {added}")
    ok_count += 1

print(f"\n==> API sync complete: {ok_count} users OK, {warn_count} warnings")
