#!/usr/bin/env bash
# =============================================================================
# create-init-vm.sh — Deploy InfraWeaver Init VM on Proxmox
#
# USAGE (run this ON the Proxmox host, or via SSH):
#   bash create-init-vm.sh
#   bash create-init-vm.sh --vmid 9001 --name infraweaver-init \
#       --storage lvm-proxmox --bridge vmbr0 --vlan 3 \
#       --ip 10.10.0.50 --cidr 24 \
#       --no-cluster-nic \
#       --repo https://github.com/yourorg/InfraWeaver-platform --branch main \
#       --cpu 2 --mem 2048 --disk 60 \
#       --yes
#
# All --flags can also be set as IW_* environment variables:
#   IW_VMID, IW_VM_NAME, IW_STORAGE, IW_BRIDGE, IW_VLAN_TAG,
#   IW_VM_IP, IW_VM_GW, IW_VM_CIDR, IW_REPO_URL, IW_REPO_BRANCH,
#   IW_CPU, IW_MEM, IW_DISK, IW_SSH_PUBKEY, IW_YES=1
#
# Use --yes (or IW_YES=1) to skip the confirmation summary prompt.
# In non-interactive mode (no TTY) all prompts default automatically.
#
# WHAT THIS DOES:
#   1. Downloads Ubuntu 24.04 cloud image (cached)
#   2. Creates a minimal VM (2 CPU, 2GB RAM, 60GB disk)
#   3. Cloud-init: auto-installs tools, clones repo, starts init web server
#   4. Prints the VM IP and web UI URL when done
#
# RESULT:
#   → Web UI binds to 127.0.0.1:8080 and requires a one-time token.
#     Reach it from your workstation via an SSH tunnel:
#       ssh -L 8080:127.0.0.1:8080 iw@<vm-ip>
#     then open the tokenised URL the service logs (journalctl -u iw-init).
#   → Or just: cp .env.example .env && nano .env && bash scripts/deploy-local.sh
# =============================================================================
set -euo pipefail
set +x   # force xtrace OFF — bash inherits SHELLOPTS=xtrace from parent shells
          # which causes every command to be printed, garbling wizard output

# Disable bracketed paste mode — prevents $'\E[200~' artifacts when pasting
# into Proxmox noVNC / shell consoles that have it enabled
printf '\e[?2004l' 2>/dev/null || true

# ── Colors (defined early — used in wizard) ───────────────────────────────────
# Detect if the terminal supports colors; fall back to plain output if not
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'
  D='\033[2m'; NC='\033[0m'; B='\033[1m'; M='\033[0;35m'
else
  G=''; Y=''; R=''; C=''; D=''; NC=''; B=''; M=''
fi
log()  { echo -e "${G}>>${NC} $*"; }
warn() { echo -e "${Y}WARN:${NC} $*"; }
die()  { echo -e "${R}ERROR:${NC} $*" >&2; exit 1; }
ok()   { echo -e "${G}OK:${NC} $*"; }
hdr()  { echo -e "\n${C}${B}=== $* ===${NC}"; }
_HAS_TTY=false
{ printf '' >/dev/tty && _HAS_TTY=true; } 2>/dev/null || true

ask()  {
  # ask VAR "Question" "default"  → reads into VAR, shows default in brackets
  # Falls back to default silently when no TTY is available (non-interactive / SSH pipe)
  local _var="$1" _prompt="$2" _default="${3:-}"
  if ! "$_HAS_TTY"; then printf -v "$_var" '%s' "$_default"; return; fi
  local _display="${_default:+${D} [${_default}]${NC}}"
  printf "%b  %s%b: " "${M}" "$_prompt" "${_display}${NC}" >/dev/tty
  IFS= read -r _input </dev/tty
  printf -v "$_var" '%s' "${_input:-$_default}"
}
askyn() {
  # askyn "Question" "Y/n"  → returns 0=yes 1=no
  # Falls back to default (Y) when no TTY is available
  local _prompt="$1" _default="${2:-Y}"
  if ! "$_HAS_TTY"; then [[ "${_default,,}" == "y" ]]; return; fi
  printf "%b  %s %b[%s]%b: " "${M}" "$_prompt" "${D}" "$_default" "${NC}" >/dev/tty
  IFS= read -r _yn </dev/tty
  _yn="${_yn:-$_default}"
  [[ "${_yn,,}" == "y" || "${_yn,,}" == "yes" ]]
}
choose() {
  # choose VAR "Header line" item1 item2 item3...
  # Shows a numbered list; user picks by number or types a value; Enter = item 1
  # Falls back to the first item (default) when no TTY is available
  local _var="$1" _header="$2"; shift 2
  local _opts=("$@") _n="$#"
  if ! "$_HAS_TTY"; then printf -v "$_var" '%s' "${_opts[0]}"; return; fi
  "$_HAS_TTY" && echo -e "  ${C}${_header}${NC}" >/dev/tty
  local i; for (( i=0; i<_n; i++ )); do
    local _mark=""; (( i == 0 )) && _mark=" ${D}(default)${NC}"
    printf "    %b%d)%b %s%b\n" "${B}" "$((i+1))" "${NC}" "${_opts[$i]}" "${_mark}" >/dev/tty
  done
  printf "  %bChoice [1]:%b " "${M}" "${NC}" >/dev/tty
  local _input; IFS= read -r _input </dev/tty
  _input="${_input:-1}"
  local _choice
  if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _n )); then
    _choice="${_opts[$(( _input - 1 ))]}"
  else
    _choice="$_input"   # allow typing a value directly
  fi
  printf -v "$_var" '%s' "$_choice"
}

# ── Animation helpers ─────────────────────────────────────────────────────────
_SP_PID=""
_SP_CHARS='|/-\'

spin_start() {
  # spin_start "message" — starts a background spinner; call spin_stop when done
  local _msg="$1"
  ( set +e   # disable set -e inside spinner; (( i++ )) returns 1 when i=0
    local _i=0
    while true; do
      printf '\r  [%s] %s  ' "${_SP_CHARS:$((_i%4)):1}" "$_msg"
      _i=$(( _i + 1 ))   # plain assignment, always exits 0; avoids set -e trap
      sleep 0.1
    done
  ) &
  _SP_PID=$!
}

spin_stop() {
  # spin_stop "done message" — kills spinner and prints final OK line
  if [[ -n "$_SP_PID" ]]; then
    kill "$_SP_PID" 2>/dev/null || true   # || true: PID may already be dead
    wait "$_SP_PID" 2>/dev/null || true
    _SP_PID=""
  fi
  printf '\r  %b[OK]%b  %s        \n' "$G" "$NC" "${1:-done}"
}

spin_fail() {
  if [[ -n "$_SP_PID" ]]; then
    kill "$_SP_PID" 2>/dev/null || true
    wait "$_SP_PID" 2>/dev/null || true
    _SP_PID=""
  fi
  printf '\r  %b[FAIL]%b %s      \n' "$R" "$NC" "${1:-failed}"
}

# Step counter for the VM creation phase
_STEP_N=0
_STEP_TOTAL=7
step() {
  (( _STEP_N++ )) || true
  printf '\n  %b[%d/%d]%b %s\n' "$C" "$_STEP_N" "$_STEP_TOTAL" "$NC" "$1"
}

# Kill any running spinner on Ctrl+C or exit
trap '[[ -n "$_SP_PID" ]] && kill "$_SP_PID" 2>/dev/null; printf "\r\n"' EXIT


IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_CACHE="/var/lib/vz/template/iso/ubuntu-24.04-cloud.img"

# Env-var overrides (non-interactive mode when all IW_* vars are set)
VMID="${IW_VMID:-}"
VM_NAME="${IW_VM_NAME:-}"
STORAGE="${IW_STORAGE:-}"
AUTO_YES="${IW_YES:-}"  # set to "1" to skip confirm prompt
BRIDGE="${IW_BRIDGE:-}"
VLAN_TAG="${IW_VLAN_TAG-_ask_}"         # sentinel: ask if UNSET; empty string = untagged
VM_IP="${IW_VM_IP:-_ask_}"
VM_GW="${IW_VM_GW:-}"
VM_CIDR="${IW_VM_CIDR:-}"
CLUSTER_NIC="${IW_CLUSTER_NIC:-_ask_}"  # yes/no
CLUSTER_BRIDGE="${IW_CLUSTER_BRIDGE:-}"
CLUSTER_VLAN="${IW_CLUSTER_VLAN:-}"
CLUSTER_IP="${IW_CLUSTER_IP:-_ask_}"
CLUSTER_CIDR="${IW_CLUSTER_CIDR:-}"
REPO_URL="${IW_REPO_URL:-}"
REPO_BRANCH="${IW_REPO_BRANCH:-}"
CPU="${IW_CPU:-}"
MEM="${IW_MEM:-}"
DISK="${IW_DISK:-}"
if [[ -n "${IW_SSH_PUBKEY:-}" ]]; then
  DEPLOYER_SSH_PUBKEY="$IW_SSH_PUBKEY"
elif [[ -f /root/.ssh/id_ed25519.pub ]]; then
  DEPLOYER_SSH_PUBKEY="$(cat /root/.ssh/id_ed25519.pub)"
elif [[ -f /root/.ssh/id_rsa.pub ]]; then
  DEPLOYER_SSH_PUBKEY="$(cat /root/.ssh/id_rsa.pub)"
elif [[ -f /root/.ssh/authorized_keys ]]; then
  DEPLOYER_SSH_PUBKEY="$(head -1 /root/.ssh/authorized_keys)"
else
  DEPLOYER_SSH_PUBKEY=""
fi

# ── Parse CLI args (override env vars / skip wizard fields) ──────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid)           VMID="$2";            shift 2 ;;
    --name)           VM_NAME="$2";         shift 2 ;;
    --storage)        STORAGE="$2";         shift 2 ;;
    --bridge)         BRIDGE="$2";          shift 2 ;;
    --vlan)           VLAN_TAG="$2";        shift 2 ;;
    --ip)             VM_IP="$2";           shift 2 ;;
    --gw)             VM_GW="$2";           shift 2 ;;
    --cidr)           VM_CIDR="$2";         shift 2 ;;
    --cluster-vlan)   CLUSTER_VLAN="$2";    shift 2 ;;
    --cluster-ip)     CLUSTER_IP="$2";      shift 2 ;;
    --cluster-cidr)   CLUSTER_CIDR="$2";    shift 2 ;;
    --no-cluster-nic) CLUSTER_NIC="no";     shift   ;;
    --repo)           REPO_URL="$2";        shift 2 ;;
    --branch)         REPO_BRANCH="$2";     shift 2 ;;
    --cpu)            CPU="$2";             shift 2 ;;
    --mem)            MEM="$2";             shift 2 ;;
    --disk)           DISK="$2";            shift 2 ;;
    --ssh-pubkey)     DEPLOYER_SSH_PUBKEY="$2"; shift 2 ;;
    --yes|-y)         AUTO_YES=1;           shift   ;;
    --help|-h)
      sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
# ── Banner (line-by-line reveal) ─────────────────────────────────────────────
echo ""
echo -e "${C}${B}"
sleep 0.05; echo "  +==============================================================+"
sleep 0.05; echo "  |          InfraWeaver -- Init VM Deployer                    |"
sleep 0.05; echo "  |          Creates a lightweight bootstrap VM on Proxmox      |"
sleep 0.05; echo "  +==============================================================+"
echo -e "${NC}"
echo -e "  ${D}This wizard will create a small Ubuntu VM that hosts the${NC}"
echo -e "  ${D}InfraWeaver web UI and deploys your Kubernetes cluster.${NC}"
echo ""

# ── Pre-flight (must run on Proxmox) ─────────────────────────────────────────
command -v qm &>/dev/null || die "This script must run on a Proxmox VE host (qm not found)"

# ── Auto-detect Proxmox environment ──────────────────────────────────────────
PVE_NODE=$(hostname -s)

# Available storages that can hold VM images
mapfile -t AVAIL_STORAGES_ARR < <(pvesm status --content images 2>/dev/null \
  | awk 'NR>1 && $3=="active" {print $1}' || echo "lvm-proxmox")
[[ ${#AVAIL_STORAGES_ARR[@]} -eq 0 ]] && AVAIL_STORAGES_ARR=("lvm-proxmox")

# ── Bridge detection via pvesh (Proxmox-native API) ──────────────────────────
# pvesh returns only Proxmox-managed interfaces — excludes docker0, fwbr*, virbr*
# Each bridge entry has: iface, type=bridge, address, cidr, bridge_vids (VLAN IDs)
declare -A BRIDGE_IP      # bridge → "addr/cidr" or ""
declare -A BRIDGE_SUBNET  # bridge → same as BRIDGE_IP (for suggest_free_ip)
declare -A BRIDGE_VIDS    # bridge → space-separated list of VLAN IDs (empty = not VLAN-aware)

# Expand VLAN range strings like "2-3 10 20-22" → "2 3 10 20 21 22"
_expand_vids() {
  python3 -c "
import sys
result = []
for tok in sys.argv[1].split():
    tok = tok.strip()
    if '-' in tok:
        a, b = tok.split('-', 1)
        result.extend(range(int(a), int(b)+1))
    elif tok.isdigit():
        result.append(int(tok))
print(' '.join(str(x) for x in sorted(set(result))))
" "$1" 2>/dev/null || echo ""
}

# Query pvesh; fall back to ip-link if pvesh unavailable
_pvesh_json=$(pvesh get /nodes/"$PVE_NODE"/network --output-format json 2>/dev/null || echo "[]")

mapfile -t _pvesh_bridges < <(echo "$_pvesh_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for iface in data:
    if iface.get('type') == 'bridge':
        name  = iface.get('iface', '')
        cidr  = iface.get('cidr', '')     # pvesh returns full 'IP/prefix' in cidr
        ip    = iface.get('address', '')
        vids  = iface.get('bridge_vids', iface.get('vids', ''))
        # cidr is already '10.25.0.3/24'; use it directly to avoid duplicate IP
        addr  = cidr if cidr else ''
        print(f'{name}|{addr}|{vids}')
")

AVAIL_BRIDGES_ARR=()
for _entry in "${_pvesh_bridges[@]}"; do
  IFS='|' read -r _br _addr _vids <<< "$_entry"
  [[ -z "$_br" ]] && continue
  AVAIL_BRIDGES_ARR+=("$_br")
  BRIDGE_IP[$_br]="$_addr"
  BRIDGE_SUBNET[$_br]="$_addr"
  BRIDGE_VIDS[$_br]="$(_expand_vids "$_vids")"
done

# Fallback: scan ip link for vmbr* bridges if pvesh gave nothing
if [[ ${#AVAIL_BRIDGES_ARR[@]} -eq 0 ]]; then
  while IFS= read -r _br; do
    AVAIL_BRIDGES_ARR+=("$_br")
    _bip=$(ip -o -4 addr show dev "$_br" 2>/dev/null | awk '{print $4}' | head -1)
    BRIDGE_IP[$_br]="${_bip:-}"
    BRIDGE_SUBNET[$_br]="${_bip:-}"
    _vids_raw=$(grep -A5 "iface $_br" /etc/network/interfaces 2>/dev/null \
      | grep 'bridge-vids' | awk '{$1=""; print $0}')
    BRIDGE_VIDS[$_br]="$(_expand_vids "${_vids_raw:-}")"
  done < <(ip link show type bridge 2>/dev/null \
    | awk -F: '/^[0-9]+:/{gsub(/ /,"",$2); print $2}' | grep '^vmbr' | sort)
  [[ ${#AVAIL_BRIDGES_ARR[@]} -eq 0 ]] && AVAIL_BRIDGES_ARR=("vmbr0")
fi

# Identify the management bridge: the one hosting this Proxmox node's own IP
MGMT_GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
_MGMT_BRIDGE=""
_MGMT_BRIDGE_IDX=0
for _i in "${!AVAIL_BRIDGES_ARR[@]}"; do
  _br="${AVAIL_BRIDGES_ARR[$_i]}"
  if [[ -n "${BRIDGE_IP[$_br]:-}" ]]; then
    _MGMT_BRIDGE="$_br"
    _MGMT_BRIDGE_IDX=$_i
    break
  fi
done

# Build human-readable labels; management bridge sorted first
BRIDGE_LABELS=()
_sorted_bridges=()
[[ -n "$_MGMT_BRIDGE" ]] && _sorted_bridges+=("$_MGMT_BRIDGE")
for _br in "${AVAIL_BRIDGES_ARR[@]}"; do
  [[ "$_br" == "$_MGMT_BRIDGE" ]] && continue
  _sorted_bridges+=("$_br")
done
AVAIL_BRIDGES_ARR=("${_sorted_bridges[@]}")

for _br in "${AVAIL_BRIDGES_ARR[@]}"; do
  _addr="${BRIDGE_IP[$_br]:-}"
  _vids="${BRIDGE_VIDS[$_br]:-}"
  _label="$_br"
  if [[ -n "$_addr" ]]; then
    _label+=" (${_addr})"
  else
    _label+=" (no IP)"
  fi
  if [[ -n "$_vids" ]]; then
    _label+=" [VLAN-aware: ${_vids// /,}]"
  fi
  [[ "$_br" == "$_MGMT_BRIDGE" ]] && _label+=" [this host]"
  BRIDGE_LABELS+=("$_label")
done

# Scan Proxmox VM/LXC configs to find which VMs use a given VLAN tag
_get_vlan_tenants() {
  local _vlan="$1"
  local _names=()
  local _conf
  for _conf in /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf; do
    [[ -f "$_conf" ]] || continue
    # Match netN lines containing tag=<vlan> (exact number, not e.g. tag=30 matching 3)
    if grep -qP "^net[0-9]+:.*\btag=${_vlan}\b" "$_conf" 2>/dev/null; then
      local _name
      _name=$(grep -m1 '^name:' "$_conf" 2>/dev/null | awk '{print $2}')
      [[ -z "$_name" ]] && _name="vm$(basename "${_conf%.conf}")"
      _names+=("$_name")
    fi
  done
  local IFS=','
  echo "${_names[*]}"
}

# Build VLAN option list for a given bridge
# Each entry: "3  [github-runner]" or "2  [no VMs]"
# Sets global _VLAN_OPTS_ARR
_build_vlan_opts() {
  local _br="$1"
  local _vids="${BRIDGE_VIDS[$_br]:-}"
  _VLAN_OPTS_ARR=("none (untagged)  [host/management network]")
  if [[ -n "$_vids" ]]; then
    for _v in $_vids; do
      local _tenants
      _tenants=$(_get_vlan_tenants "$_v")
      if [[ -n "$_tenants" ]]; then
        _VLAN_OPTS_ARR+=("${_v}  [${_tenants}]")
      else
        _VLAN_OPTS_ARR+=("${_v}  [no VMs on this VLAN]")
      fi
    done
  fi
}

# Next free VMID >= 9000
NEXT_VMID=9000
while qm status "$NEXT_VMID" &>/dev/null 2>&1; do (( NEXT_VMID++ )); done


# ── Helper: suggest a free IP in a subnet ──────────────────────────────────────
suggest_free_ip() {
  # suggest_free_ip <cidr> — returns first free IP in .50-.99; shows scan progress
  local _cidr="$1"
  local _base; _base=$(echo "$_cidr" | cut -d/ -f1 | cut -d. -f1-3)
  printf '  Scanning %s.50-%s.99 for a free IP ' "$_base" "$_base"
  for _last in $(seq 50 99); do
    local _ip="${_base}.${_last}"
    printf '.'
    if ! ping -c1 -W1 "$_ip" &>/dev/null; then
      printf ' found: %s\n' "$_ip"
      echo "$_ip"; return
    fi
  done
  printf ' using fallback\n'
  echo "${_base}.50"
}

# ── Helper: derive gateway (.1) from an IP + prefix length ────────────────────
_calc_gw_from_ip() {
  # _calc_gw_from_ip <ip> <prefix>  →  prints network-address.1
  # Example: 10.10.0.50 24  →  10.10.0.1
  #          192.168.5.100 16  →  192.168.0.1
  local _ip="$1" _prefix="${2:-24}"
  [[ -z "$_ip" ]] && echo "" && return
  awk -v ip="$_ip" -v prefix="$_prefix" 'BEGIN {
    n = split(ip, a, ".")
    if (n != 4) { print ""; exit }
    ip_int = a[1]*16777216 + a[2]*65536 + a[3]*256 + (a[4]+0)
    blk = 1; for (i = 0; i < (32 - prefix); i++) blk *= 2
    net = int(ip_int / blk) * blk
    gw  = net + 1
    printf "%d.%d.%d.%d", int(gw/16777216)%256, int(gw/65536)%256, int(gw/256)%256, gw%256
  }'
}

# ── Interactive Wizard ────────────────────────────────────────────────────────
hdr "VM Settings"

# VMID — just show and confirm
if [[ -z "$VMID" ]]; then
  if "$_HAS_TTY"; then
    "$_HAS_TTY" && echo -e "  Next available VM ID: ${B}${NEXT_VMID}${NC}" >/dev/tty
    printf "  %bVM ID [%d]:%b " "${M}" "$NEXT_VMID" "${NC}" >/dev/tty
    IFS= read -r _vmid_in </dev/tty
    VMID="${_vmid_in:-$NEXT_VMID}"
  else
    VMID="$NEXT_VMID"
  fi
fi

# VM name — default, just confirm
[[ -z "$VM_NAME" ]] && ask VM_NAME "VM name" "infraweaver-init"

# Storage — numbered choice
if [[ -z "$STORAGE" ]]; then
  choose STORAGE "Storage pool:" "${AVAIL_STORAGES_ARR[@]}"
fi

# Resources — sane defaults, just confirm
[[ -z "$CPU"  ]] && ask CPU  "CPU cores" "2"
[[ -z "$MEM"  ]] && ask MEM  "RAM (MB)"  "2048"
[[ -z "$DISK" ]] && ask DISK "Disk (GB)" "60"

hdr "Management Network  (net0 - web UI access)"

# Bridge — if only one Proxmox bridge exists, auto-select it (the VLAN is the real choice)
if [[ -z "$BRIDGE" ]]; then
  if [[ ${#AVAIL_BRIDGES_ARR[@]} -eq 1 ]]; then
    BRIDGE="${AVAIL_BRIDGES_ARR[0]}"
    "$_HAS_TTY" && echo -e "  ${D}Bridge: ${B}${BRIDGE}${NC} ${D}(${BRIDGE_IP[$BRIDGE]:-no IP}) -- only Proxmox bridge, auto-selected${NC}" >/dev/tty
  else
    choose _BRIDGE_LABEL "Management bridge:" "${BRIDGE_LABELS[@]}"
    BRIDGE=$(echo "$_BRIDGE_LABEL" | awk '{print $1}')
  fi
fi

# VLAN — options derived from the selected bridge's configured VIDs
# Always ask when bridge is VLAN-aware; untagged = Proxmox management plane,
# numbered VIDs = VM/cluster traffic on that VLAN segment
if [[ "$VLAN_TAG" == "_ask_" ]]; then
  _build_vlan_opts "$BRIDGE"
  if [[ ${#_VLAN_OPTS_ARR[@]} -gt 1 ]]; then
    _vids_display="${BRIDGE_VIDS[$BRIDGE]// /,}"
    "$_HAS_TTY" && echo -e "  ${D}${BRIDGE} is VLAN-aware (VIDs: ${_vids_display}). Choose the VLAN for the init VM's management NIC.${NC}" >/dev/tty
    "$_HAS_TTY" && echo -e "  ${D}Use 'none' if the init VM should be on the untagged/native VLAN (same as this host).${NC}" >/dev/tty
    choose _VLAN_CHOICE "Management VLAN tag:" "${_VLAN_OPTS_ARR[@]}"
  else
    "$_HAS_TTY" && echo -e "  ${D}Bridge ${BRIDGE} is not VLAN-aware -- management NIC will be untagged.${NC}" >/dev/tty
    _VLAN_CHOICE="none (untagged)"
  fi
  if [[ "$_VLAN_CHOICE" == none* || -z "$_VLAN_CHOICE" ]]; then
    VLAN_TAG=""
  else
    VLAN_TAG=$(echo "$_VLAN_CHOICE" | awk '{print $1}')   # strip tenant annotation
  fi
fi

# Management IP — always static
if [[ "$VM_IP" == "_ask_" ]]; then
  _suggested_ip=""
  _suggested_gw="${MGMT_GW:-}"

  if [[ -z "$VLAN_TAG" ]]; then
    # Untagged — bridge IP is on the same subnet as the VM will be; scan is valid
    _br_subnet="${BRIDGE_SUBNET[$BRIDGE]:-}"
    if [[ -n "$_br_subnet" ]]; then
      log "Scanning for a free IP in ${_br_subnet} (this takes a few seconds)..."
      _suggested_ip=$(suggest_free_ip "$_br_subnet")
      _net_prefix="${_br_subnet%.*}"
      [[ -z "$_suggested_gw" ]] && _suggested_gw="${_net_prefix}.1"
    fi
  else
    # Tagged VLAN — the bridge's own IP is on the native VLAN, a different subnet.
    # We don't know the VLAN subnet, so ask without a wrong suggestion.
    "$_HAS_TTY" && echo -e "  ${D}(VLAN ${VLAN_TAG} has its own subnet — enter the IP/gateway for that VLAN)${NC}" >/dev/tty
  fi

  ask VM_IP   "Static IP for this VM"  "${_suggested_ip:-}"
  ask VM_CIDR "Prefix length"          "24"
  # Recalculate gateway from the user's actual IP + prefix (always correct regardless of VLAN)
  _suggested_gw=$(_calc_gw_from_ip "$VM_IP" "${VM_CIDR:-24}")
  ask VM_GW   "Gateway"                "${_suggested_gw:-}"
else
  # IP was pre-set via --ip / IW_VM_IP — fill in any missing CIDR + gateway
  [[ -z "$VM_CIDR" ]] && VM_CIDR="24"
  [[ -z "$VM_GW"   ]] && VM_GW=$(_calc_gw_from_ip "$VM_IP" "$VM_CIDR")
fi

hdr "Cluster Network  (net1 - Talos node communication)"
echo -e "  ${D}A second NIC on your Talos node network lets the init VM${NC}"
echo -e "  ${D}discover and configure cluster nodes directly.${NC}"
echo ""

if [[ "$CLUSTER_NIC" == "_ask_" ]]; then
  if askyn "Add a cluster NIC?" "Y"; then CLUSTER_NIC="yes"; else CLUSTER_NIC="no"; fi
fi

if [[ "$CLUSTER_NIC" == "yes" ]]; then
  # Cluster bridge — auto-select when only one option (same bridge, different VLAN)
  if [[ -z "$CLUSTER_BRIDGE" ]]; then
    if [[ ${#AVAIL_BRIDGES_ARR[@]} -eq 1 ]]; then
      CLUSTER_BRIDGE="${AVAIL_BRIDGES_ARR[0]}"
      "$_HAS_TTY" && echo -e "  ${D}Bridge: ${B}${CLUSTER_BRIDGE}${NC} ${D}-- auto-selected (same bridge, different VLAN)${NC}" >/dev/tty
    else
      choose _CBR_LABEL "Cluster bridge:" "${BRIDGE_LABELS[@]}"
      CLUSTER_BRIDGE=$(echo "$_CBR_LABEL" | awk '{print $1}')
    fi
  fi

  # Cluster VLAN — pick from bridge VIDs; nudge toward a different VLAN than management
  if [[ -z "$CLUSTER_VLAN" ]]; then
    _build_vlan_opts "$CLUSTER_BRIDGE"
    if [[ ${#_VLAN_OPTS_ARR[@]} -gt 1 ]]; then
      _vids_display="${BRIDGE_VIDS[$CLUSTER_BRIDGE]// /,}"
      "$_HAS_TTY" && echo -e "  ${D}Pick the VLAN where your Talos cluster nodes live (VIDs: ${_vids_display}).${NC}" >/dev/tty
      [[ -n "$VLAN_TAG" ]] && echo -e "  ${D}(Management is on VLAN ${VLAN_TAG} -- choose a different one for cluster traffic.)${NC}" >/dev/tty
      [[ -z "$VLAN_TAG" ]] && echo -e "  ${D}(Management is untagged -- choose a VLAN for cluster traffic.)${NC}" >/dev/tty
      choose _CVLAN_CHOICE "Cluster VLAN tag (Talos node traffic):" "${_VLAN_OPTS_ARR[@]}"
    else
      "$_HAS_TTY" && echo -e "  ${D}Bridge ${CLUSTER_BRIDGE} is not VLAN-aware -- cluster NIC will be untagged.${NC}" >/dev/tty
      _CVLAN_CHOICE="none (untagged)"
    fi
    if [[ "$_CVLAN_CHOICE" == none* || -z "$_CVLAN_CHOICE" ]]; then
      CLUSTER_VLAN=""
    else
      CLUSTER_VLAN=$(echo "$_CVLAN_CHOICE" | awk '{print $1}')   # strip tenant annotation
    fi
  fi

  if [[ "$CLUSTER_IP" == "_ask_" ]]; then
    if askyn "Use DHCP for the cluster NIC?" "N"; then
      CLUSTER_IP=""; CLUSTER_CIDR=""
    else
      # Suggest a free IP on the cluster bridge subnet
      _cbr_subnet="${BRIDGE_SUBNET[$CLUSTER_BRIDGE]:-}"
      _suggested_cluster_ip=""
      if [[ -n "$_cbr_subnet" ]]; then
        log "Scanning for a free cluster IP in ${_cbr_subnet%/*}/24..."
        _suggested_cluster_ip=$(suggest_free_ip "$_cbr_subnet")
      fi
      [[ -z "$_suggested_cluster_ip" ]] && _suggested_cluster_ip="10.10.0.50"
      ask CLUSTER_IP  "Static IP for cluster NIC" "$_suggested_cluster_ip"
      [[ -z "$CLUSTER_CIDR" ]] && ask CLUSTER_CIDR "Prefix length" "24"
    fi
  fi
fi

hdr "Repository"
[[ -z "$REPO_URL"    ]] && ask REPO_URL    "Git repo URL" \
  "https://github.com/your-org/your-repo"
[[ -z "$REPO_BRANCH" ]] && ask REPO_BRANCH "Branch"       "main"

hdr "SSH Access"
echo -e "  ${D}Public key injected into the 'iw' user on the VM.${NC}"
echo ""
if [[ -z "$DEPLOYER_SSH_PUBKEY" ]]; then
  ask DEPLOYER_SSH_PUBKEY "SSH public key (paste full key)" ""
  [[ -z "$DEPLOYER_SSH_PUBKEY" ]] && die "An SSH public key is required."
else
  echo -e "  ${G}[OK]${NC} Auto-detected: ${D}${DEPLOYER_SSH_PUBKEY:0:60}...${NC}"
fi

# ── Confirm summary ───────────────────────────────────────────────────────────
echo ""
echo "  +-----------------------------------------------------------+"
echo "  |  SUMMARY                                                  |"
echo "  +-----------------------------------------------------------+"
echo -e "  |  VM ID      : ${B}${VMID}${NC} / ${VM_NAME}"
echo -e "  |  Resources  : ${B}${CPU} CPU / ${MEM} MB RAM / ${DISK} GB${NC}"
echo -e "  |  Storage    : ${B}${STORAGE}${NC}"
echo -e "  |  net0 (mgmt): bridge=${B}${BRIDGE}${NC}${VLAN_TAG:+, VLAN=${VLAN_TAG}} -> ${B}${VM_IP}/${VM_CIDR}${NC}"
if [[ "$CLUSTER_NIC" == "yes" ]]; then
  echo -e "  |  net1 (k8s) : bridge=${B}${CLUSTER_BRIDGE}${NC}, VLAN=${B}${CLUSTER_VLAN}${NC} -> ${B}${CLUSTER_IP:-DHCP}${NC}${CLUSTER_CIDR:+/${CLUSTER_CIDR}}"
fi
echo -e "  |  Repo       : ${B}${REPO_URL}${NC} @ ${REPO_BRANCH}"
echo "  +-----------------------------------------------------------+"
echo ""
if [[ -n "$AUTO_YES" ]]; then
  log "Auto-confirming (--yes flag)"
else
  askyn "Proceed with these settings?" "Y" || die "Aborted."
fi
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
if qm status "$VMID" &>/dev/null; then
  warn "VM $VMID already exists!"
  read -rp "  Destroy and recreate it? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    spin_start "Stopping and destroying VM $VMID"
    qm stop "$VMID" --skiplock 2>/dev/null || true
    sleep 2
    qm destroy "$VMID" --purge --skiplock 2>/dev/null || true
    spin_stop "VM $VMID removed"
  else
    die "Aborting. Use a different --vmid or remove the existing VM."
  fi
fi

echo ""
echo -e "  ${B}Creating your InfraWeaver Init VM -- ${_STEP_TOTAL} steps${NC}"

# ── Download cloud image (cached) ─────────────────────────────────────────────
step "Checking cloud image cache"
if [[ -f "$IMAGE_CACHE" ]]; then
  echo "    Cloud image already cached at $IMAGE_CACHE"
else
  spin_start "Downloading Ubuntu 24.04 cloud image (~500 MB)"
  mkdir -p "$(dirname "$IMAGE_CACHE")"
  spin_stop ""  # stop spinner before wget takes over terminal output
  wget -q --show-progress -O "$IMAGE_CACHE" "$IMAGE_URL" \
    || curl -fL --progress-bar -o "$IMAGE_CACHE" "$IMAGE_URL"
  echo -e "  ${G}[OK]${NC}  Cloud image saved to $IMAGE_CACHE"
fi

# ── Build cloud-init user-data ────────────────────────────────────────────────
step "Generating cloud-init user-data"

USERDATA_FILE="$(mktemp /tmp/iw-userdata-XXXXX.yaml)"

# Build cluster NIC netplan snippet (only if requested)
if [[ "$CLUSTER_NIC" == "yes" ]]; then
  if [[ -n "$CLUSTER_IP" ]]; then
    CLUSTER_NETPLAN_CMD="cat > /etc/netplan/60-cluster.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    ens19:
      addresses: [${CLUSTER_IP}/${CLUSTER_CIDR:-24}]
NETPLAN
chmod 600 /etc/netplan/60-cluster.yaml
netplan apply || true"
  else
    CLUSTER_NETPLAN_CMD="cat > /etc/netplan/60-cluster.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    ens19:
      dhcp4: true
NETPLAN
chmod 600 /etc/netplan/60-cluster.yaml
netplan apply || true"
  fi
else
  CLUSTER_NETPLAN_CMD="# No cluster NIC configured"
fi

cat > "$USERDATA_FILE" << CLOUDINIT
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

ssh_pwauth: false

users:
  - name: iw
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: true
    ssh_authorized_keys:
      - ${DEPLOYER_SSH_PUBKEY}

# Start qemu-guest-agent as early as possible so Proxmox can detect the VM IP
# before/during package installation (which can take 2-3 minutes on first boot)
bootcmd:
  - [ systemctl, enable, qemu-guest-agent ]
  - [ systemctl, start, qemu-guest-agent ]

package_update: true
package_upgrade: false
packages:
  - python3
  - python3-pip
  - git
  - curl
  - wget
  - jq
  - openssh-server
  - openssh-client
  - sshpass
  - nano
  - qemu-guest-agent

runcmd:
  # Configure cluster NIC (ens19 / net1) if requested
  - |
    ${CLUSTER_NETPLAN_CMD}
  # Clone the InfraWeaver repository
  - GIT_TERMINAL_PROMPT=0 git clone --branch ${REPO_BRANCH} --depth=1 ${REPO_URL} /opt/infraweaver 2>&1 | tee /var/log/iw-clone.log
  - chown -R iw:iw /opt/infraweaver
  # Create systemd service for the init web server
  - |
    cat > /etc/systemd/system/iw-init.service << 'SVC'
    [Unit]
    Description=InfraWeaver Init Web Server
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    User=iw
    WorkingDirectory=/opt/infraweaver
    ExecStartPre=-/bin/bash -c '/usr/bin/git -C /opt/infraweaver pull --ff-only origin main'
    ExecStart=/usr/bin/python3 scripts/init/server.py
    Restart=on-failure
    RestartSec=5
    Environment=IW_REPO_DIR=/opt/infraweaver

    [Install]
    WantedBy=multi-user.target
    SVC
  - systemctl daemon-reload
  - systemctl enable iw-init
  - systemctl start iw-init
  # Print SSH-tunnel access guidance to console (escaped so it runs on the VM)
  # The web UI binds to 127.0.0.1 and requires a one-time token; reach it by
  # forwarding the port over SSH, then read the token from the service log.
  - sleep 3
  - |
    IP=\$(hostname -I | awk '{print \$1}')
    echo ""
    echo "+==============================================================+"
    echo "| InfraWeaver Init VM is ready!                              |"
    echo "|                                                             |"
    echo "| Web UI binds to 127.0.0.1:8080 (not exposed on the LAN).   |"
    echo "| From your workstation, tunnel the port over SSH:           |"
    echo "|   ssh -L 8080:127.0.0.1:8080 iw@\${IP}                       |"
    echo "| Then open the tokenised URL printed by the service:        |"
    echo "|   journalctl -u iw-init | grep -m1 'Open'                  |"
    echo "| SSH login -> iw / infraweaver                              |"
    echo "+==============================================================+"
    echo ""
  - echo "iw-init ready" > /var/lib/cloud/instance/init-done

final_message: "InfraWeaver init VM ready. SSH in (ssh -L 8080:127.0.0.1:8080 iw@${VM_IP}), then open the tokenised URL from: journalctl -u iw-init | grep Open"
CLOUDINIT

log "Cloud-init user-data written to $USERDATA_FILE"

# ── Create VM ──────────────────────────────────────────────────────────────────
step "Creating VM configuration"
spin_start "Running qm create $VMID"

qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEM" \
  --cores "$CPU" \
  --sockets 1 \
  --cpu host \
  --ostype l26 \
  --boot c \
  --bootdisk scsi0 \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0 \
  --onboot 1 \
  --tablet 0 \
  --description "InfraWeaver Init VM - web UI at :8080"

# Set management network (net0)
NET_OPTS="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NET_OPTS="${NET_OPTS},tag=${VLAN_TAG}"
qm set "$VMID" --net0 "$NET_OPTS"

# Capture the MAC Proxmox auto-assigned to net0 — used for ARP-based IP detection later
VM_MAC=$(qm config "$VMID" 2>/dev/null | grep '^net0:' \
  | grep -oP '(?<=virtio=)[^,]+' | tr '[:upper:]' '[:lower:]')

# Set cluster network (net1) — only if requested
if [[ "$CLUSTER_NIC" == "yes" ]]; then
  CLUSTER_NET_OPTS="virtio,bridge=${CLUSTER_BRIDGE:-$BRIDGE},tag=${CLUSTER_VLAN}"
  qm set "$VMID" --net1 "$CLUSTER_NET_OPTS"
fi
spin_stop "VM $VMID configured"

# ── Import disk ──────────────────────────────────────────────────────────────
step "Importing disk image to storage $STORAGE"
spin_start "Importing disk (this may take 15-30s)"
qm importdisk "$VMID" "$IMAGE_CACHE" "$STORAGE" --format raw &>/dev/null
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,size=${DISK}G"
qm resize "$VMID" scsi0 "${DISK}G" 2>/dev/null || true
spin_stop "Disk imported and resized to ${DISK}G"

# ── Cloud-init drive ─────────────────────────────────────────────────────────
step "Writing cloud-init configuration"
spin_start "Attaching cloud-init drive"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --cicustom "user=local:snippets/iw-init-${VMID}.yaml"

# Copy user-data to Proxmox snippets
mkdir -p /var/lib/vz/snippets
cp "$USERDATA_FILE" "/var/lib/vz/snippets/iw-init-${VMID}.yaml"
rm -f "$USERDATA_FILE"

qm set "$VMID" --ipconfig0 "ip=${VM_IP}/${VM_CIDR},gw=${VM_GW}"

qm set "$VMID" --nameserver "8.8.8.8 1.1.1.1"
qm set "$VMID" --searchdomain "local"
spin_stop "Cloud-init configured"

# ── Start VM ──────────────────────────────────────────────────────────────────
step "Starting VM"
spin_start "Sending start command to VM $VMID"
qm start "$VMID"
spin_stop "VM $VMID started"

# ── All done ─────────────────────────────────────────────────────────────────
step "All done!"
echo ""
sleep 0.2
echo -e "${G}${B}+===============================================================+${NC}"
sleep 0.05
echo -e "${G}${B}  InfraWeaver Init VM is booting!${NC}"
echo ""
sleep 0.05
echo -e "  SSH     ->  ${C}ssh iw@${VM_IP}${NC}  (password: infraweaver)"
echo -e "  Web UI  ->  binds to ${B}127.0.0.1:8080${NC} on the VM (not on the LAN)"
echo -e "              tunnel it: ${C}${B}ssh -L 8080:127.0.0.1:8080 iw@${VM_IP}${NC}"
echo -e "              then open the tokenised URL the service prints:"
echo -e "              ${C}journalctl -u iw-init | grep -m1 Open${NC}"
echo ""
sleep 0.05
echo -e "  The init server will be ready in ~60-90 seconds (cloud-init)."
echo -e "  Open the tokenised web UI URL, fill in your .env values, then Deploy."
echo ""
sleep 0.05
echo -e "  ${Y}Alternative (no web UI):${NC}"
echo -e "  SSH into the VM and run:"
echo -e "  ${C}  cp /opt/infraweaver/.env.example /opt/infraweaver/.env && \\"
echo -e "     nano /opt/infraweaver/.env && \\"
echo -e "     bash /opt/infraweaver/scripts/deploy-local.sh${NC}"
echo ""
sleep 0.05
echo -e "${G}${B}+===============================================================+${NC}"
echo ""
