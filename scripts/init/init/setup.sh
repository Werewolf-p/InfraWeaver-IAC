#!/usr/bin/env bash
# =============================================================================
# setup.sh — Universal InfraWeaver entry point
#
# One URL, works anywhere:
#   - On a Proxmox host   → choose: run wizard HERE or spin up a dedicated init VM
#   - On any Linux/macOS  → starts the wizard locally (needs network to Proxmox API)
#
# USAGE:
#   wget -qO- https://raw.githubusercontent.com/your-org/your-repo/main/scripts/init/setup.sh | bash
#   curl -sSL https://raw.githubusercontent.com/your-org/your-repo/main/scripts/init/setup.sh | bash
#
# ENV OVERRIDES (passed through to sub-scripts):
#   IW_REPO_URL    — git URL  (default: GitHub main repo)
#   IW_REPO_BRANCH — branch   (default: main)
#   IW_WORK_DIR    — local clone dir for "run here" mode (default: ~/.infraweaver)
#   IW_PORT        — web UI port (default: 8080)
#   IW_YES=1       — skip confirmation prompts in VM-creation mode
# =============================================================================
set -euo pipefail

REPO_URL="${IW_REPO_URL:-https://github.com/your-org/your-repo}"
REPO_BRANCH="${IW_REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/your-org/your-repo/${REPO_BRANCH}"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'
  D='\033[2m'; NC='\033[0m'; B='\033[1m'; M='\033[0;35m'
else
  G=''; Y=''; R=''; C=''; D=''; NC=''; B=''; M=''
fi

# Disable bracketed paste (Proxmox noVNC/shell artefact)
printf '\e[?2004l' 2>/dev/null || true

die() { echo -e "${R}  ERROR:${NC} $*" >&2; exit 1; }

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${C}${B}  +==============================================================+${NC}"
echo -e "${C}${B}  |             InfraWeaver — Setup                              |${NC}"
echo -e "${C}${B}  +==============================================================+${NC}"
echo ""

# ── Detect environment ────────────────────────────────────────────────────────
IS_PROXMOX=false
if [[ -d /etc/pve ]] || command -v pvesh &>/dev/null || [[ -f /usr/bin/qm ]]; then
  IS_PROXMOX=true
fi

# ── Non-Proxmox: just start the wizard locally ────────────────────────────────
if ! "$IS_PROXMOX"; then
  echo -e "  ${D}Not a Proxmox host — starting the wizard on this machine.${NC}"
  echo -e "  ${D}Make sure this machine has network access to your Proxmox API (port 8006).${NC}"
  echo ""
  # shellcheck disable=SC1090
  exec bash <(wget -qO- "${RAW_BASE}/scripts/init/start-local.sh")
fi

# ── Proxmox detected — present options ───────────────────────────────────────
PVE_VER=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "")

echo -e "  ${G}Proxmox VE host detected${NC}${D}${PVE_VER:+ (${PVE_VER})}${NC}"
echo ""
echo -e "  How would you like to run InfraWeaver?"
echo ""
echo -e "  ${B}1)${NC} ${G}Create a dedicated init VM${NC} ${D}(recommended)${NC}"
echo -e "     ${D}Spins up a lightweight Ubuntu VM, starts the wizard inside it.${NC}"
echo -e "     ${D}Keeps your Proxmox host clean. VM can be deleted after setup.${NC}"
echo ""
echo -e "  ${B}2)${NC} ${Y}Run the wizard directly on THIS Proxmox host${NC}"
echo -e "     ${D}No VM created. Wizard runs as a process on the host.${NC}"
echo -e "     ${D}Fine for a quick trial; host must have python3 + git installed.${NC}"
echo ""

# Read choice (works both interactively and when piped via wget | bash)
CHOICE=""
if [[ -t 0 ]]; then
  # stdin is a terminal
  read -rp "  Choice [1]: " CHOICE </dev/tty || true
else
  # stdin is the pipe — read from /dev/tty directly
  { read -rp "  Choice [1]: " CHOICE </dev/tty; } 2>/dev/null || true
fi
CHOICE="${CHOICE:-1}"
echo ""

case "$CHOICE" in
  1)
    echo -e "  ${C}→ Creating init VM on this Proxmox host...${NC}"
    echo ""
    # Pass through any IW_* env vars the user may have set
    exec bash <(wget -qO- "${RAW_BASE}/scripts/init/create-init-vm.sh")
    ;;
  2)
    echo -e "  ${C}→ Starting wizard on this Proxmox host...${NC}"
    echo ""
    exec bash <(wget -qO- "${RAW_BASE}/scripts/init/start-local.sh")
    ;;
  *)
    die "Invalid choice '${CHOICE}'. Run the script again and enter 1 or 2."
    ;;
esac
