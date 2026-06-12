#!/usr/bin/env python3
"""
list-recovery-users.py — Print usernames that need recovery/welcome emails.

Modes:
  (default)    Print all usernames with send_recovery_email: true
               Used by full-redeploy to send admin summary.

  --new-only   Print only usernames that are NEW in the most recent commit
               (present in HEAD but not in HEAD~1).
               Used by apply-changes to send per-user welcome emails.
               Falls back to all users if no git history is available.

Usage:
  python3 .github/scripts/list-recovery-users.py
  python3 .github/scripts/list-recovery-users.py --new-only
"""
import argparse
import subprocess

import yaml


def load_usernames_from_content(content: str) -> set:
    try:
        data = yaml.safe_load(content)
        return set((data or {}).get("users", {}).keys())
    except Exception:
        return set()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--new-only",
        action="store_true",
        help="Only print usernames added in the most recent commit",
    )
    args = parser.parse_args()

    with open("users.yaml") as f:
        config = yaml.safe_load(f)

    all_users = config.get("users", {})

    if not args.new_only:
        for username, udata in all_users.items():
            if udata.get("send_recovery_email", False):
                print(username)
        return

    # --new-only: compare HEAD vs HEAD~1 to find newly added users
    try:
        prev_content = subprocess.check_output(
            ["git", "show", "HEAD~1:users.yaml"],
            stderr=subprocess.DEVNULL,
        ).decode()
        prev_usernames = load_usernames_from_content(prev_content)
    except subprocess.CalledProcessError:
        # First commit or no history — treat all users as new
        prev_usernames = set()

    current_usernames = set(all_users.keys())
    new_usernames = current_usernames - prev_usernames

    for username in sorted(new_usernames):
        print(username)


if __name__ == "__main__":
    main()
