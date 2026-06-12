#!/usr/bin/env bash
# =============================================================================
# start-local.sh — Start InfraWeaver Init Wizard on any Linux / macOS machine
#
# Run this on a spare Ubuntu VM, your laptop, WSL, or any machine that has
# network access to your Proxmox API (port 8006).  No Proxmox shell needed.
#
# USAGE:
#   wget -qO- https://raw.githubusercontent.com/your-org/your-repo/main/scripts/init/start-local.sh | bash
#   curl -sSL https://raw.githubusercontent.com/your-org/your-repo/main/scripts/init/start-local.sh | bash
#
# ENV OVERRIDES:
#   IW_WORK_DIR   — where to clone the repo  (default: ~/.infraweaver)
#   IW_REPO_URL   — git URL to clone          (default: GitHub repo)
#   IW_REPO_BRANCH— branch to check out       (default: main)
#   IW_PORT       — web UI port               (default: 8080)
#   IW_HOST       — bind address              (default: 127.0.0.1)
# =============================================================================
set -euo pipefail

REPO_URL="${IW_REPO_URL:-https://github.com/your-org/your-repo}"
REPO_BRANCH="${IW_REPO_BRANCH:-main}"
WORK_DIR="${IW_WORK_DIR:-$HOME/.infraweaver}"
PORT="${IW_PORT:-8080}"
HOST="${IW_HOST:-127.0.0.1}"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'
  D='\033[2m'; NC='\033[0m'; B='\033[1m'
else
  G=''; Y=''; R=''; C=''; D=''; NC=''; B=''
fi
log()  { echo -e "${G}  >>${NC} $*"; }
warn() { echo -e "${Y}  WARN:${NC} $*"; }
die()  { echo -e "${R}  ERROR:${NC} $*" >&2; exit 1; }

echo -e ""
echo -e "${C}${B}  +============================================================+${NC}"
echo -e "${C}${B}  |         InfraWeaver — Local Init Starter                   |${NC}"
echo -e "${C}${B}  +============================================================+${NC}"
echo -e "${D}  Starts the InfraWeaver wizard on this machine.${NC}"
echo -e "${D}  Needs network access to your Proxmox API (port 8006).${NC}"
echo -e ""

# ── 1. Check prerequisites ────────────────────────────────────────────────────
log "Checking prerequisites..."

PY=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null; then
    ver=$("$cmd" -c 'import sys; print(sys.version_info[:2] >= (3,8))' 2>/dev/null)
    if [[ "$ver" == "True" ]]; then PY="$cmd"; break; fi
  fi
done
[[ -z "$PY" ]] && die "Python 3.8+ is required. Install it with: sudo apt install python3  (or brew install python3)"
log "Python OK: $($PY --version)"

command -v git &>/dev/null || die "git is required. Install it with: sudo apt install git  (or brew install git)"
log "git OK: $(git --version)"

# ── 2. Clone or update the repo ──────────────────────────────────────────────
if [[ -d "$WORK_DIR/.git" ]]; then
  log "Repo already at ${B}${WORK_DIR}${NC} — pulling latest ${REPO_BRANCH}..."
  git -C "$WORK_DIR" fetch --quiet origin
  git -C "$WORK_DIR" checkout --quiet "$REPO_BRANCH"
  git -C "$WORK_DIR" reset --quiet --hard "origin/$REPO_BRANCH"
  log "Repo updated."
else
  log "Cloning ${B}${REPO_URL}${NC} (branch: ${REPO_BRANCH}) → ${WORK_DIR} ..."
  mkdir -p "$(dirname "$WORK_DIR")"
  git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR"
  log "Clone complete."
fi

# ── 3. Start the init server ──────────────────────────────────────────────────
# The server binds to 127.0.0.1 by default and prints a one-time access token
# (with a ready-to-open URL) on startup. From a remote VM, forward the port
# over SSH rather than exposing it on the network.
echo -e ""
echo -e "  ${C}${B}Starting InfraWeaver Init Server...${NC}"
echo -e ""
echo -e "  ${G}${B}+----------------------------------------------------------+${NC}"
echo -e "  ${G}${B}|  Web UI binds to http://${HOST}:${PORT}                  ${NC}"
echo -e "  ${G}${B}+----------------------------------------------------------+${NC}"
echo -e ""
echo -e "  ${D}A one-time access token + open URL is printed just below.${NC}"
echo -e "  ${D}Running this on a remote VM? Forward the port over SSH:${NC}"
echo -e "  ${D}  ssh -L ${PORT}:127.0.0.1:${PORT} user@init-vm${NC}"
echo -e "  ${D}then open the printed URL on your workstation. Ctrl+C to stop.${NC}"
echo -e ""

# Browser auto-open is intentionally disabled: the UI now requires the
# one-time token, so open the tokenised URL the server prints below.

export IW_REPO_DIR="$WORK_DIR"
export IW_PORT="$PORT"
export IW_HOST="$HOST"

exec "$PY" "$WORK_DIR/scripts/init/server.py" --port "$PORT" --host "$HOST"
