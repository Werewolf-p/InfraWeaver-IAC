#!/usr/bin/env bash
# scripts/lib.sh — Shared library for InfraWeaver platform scripts
# Source this file at the top of any script: source "$(dirname "$0")/lib.sh"
#
# Provides: log, warn, die, ok, require_cmd, git_commit_if_changed, parse_yaml_list

set -euo pipefail

# Terminal colors (only when stdout is a TTY)
if [[ -t 1 ]]; then
  _BOLD='\033[1m'; _GREEN='\033[0;32m'; _YELLOW='\033[1;33m'; _RED='\033[0;31m'; _NC='\033[0m'
else
  _BOLD=''; _GREEN=''; _YELLOW=''; _RED=''; _NC=''
fi

# Script name prefix for log messages (set before sourcing: SCRIPT_NAME="my-script")
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[-1]}" .sh)}"

log()  { echo -e "${_GREEN}[${SCRIPT_NAME}]${_NC} $*"; }
info() { echo -e "${_GREEN}[${SCRIPT_NAME}]${_NC} $*"; }
warn() { echo -e "${_YELLOW}[${SCRIPT_NAME}] ⚠${_NC} $*" >&2; }
die()  { echo -e "${_RED}[${SCRIPT_NAME}] ✗${_NC} $*" >&2; exit 1; }
fail() { echo -e "${_RED}[${SCRIPT_NAME}] ✗${_NC} $*" >&2; exit 1; }
ok()   { echo -e "${_GREEN}[${SCRIPT_NAME}] ✅${_NC} $*"; }

# Check required commands are available
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
}

# Commit changes if any files changed (git add + commit with [skip ci])
# Usage: git_commit_if_changed "commit message" path/to/files...
git_commit_if_changed() {
  local msg="$1"; shift
  local changed=false
  for path in "$@"; do
    if ! git diff --quiet HEAD -- "$path" 2>/dev/null || \
       git ls-files --others --exclude-standard "$path" 2>/dev/null | grep -q .; then
      changed=true; break
    fi
  done
  if $changed; then
    git config user.email "copilot-bot@infraweaver.local" 2>/dev/null || true
    git config user.name "InfraWeaver Sync" 2>/dev/null || true
    git add "$@" 2>/dev/null || true
    git commit -m "${msg} [skip ci]

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" || true
    log "Committed: $msg"
    return 0
  fi
  return 1
}

# Parse a list from platform.yaml: parse_yaml_list platform.yaml "catalog.enabled"
parse_yaml_list() {
  local file="$1" key="$2"
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$file'))
parts = '$key'.split('.')
for p in parts:
    d = d.get(p, {}) if isinstance(d, dict) else {}
if isinstance(d, list):
    for item in d: print(item)
elif isinstance(d, dict):
    for k in d: print(k)
" 2>/dev/null
}
