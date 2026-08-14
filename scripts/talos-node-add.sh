#!/usr/bin/env bash
# talos-node-add.sh — add a Talos node to an existing cluster on any Proxmox
# node, including a remote one reached over a site link.
#
# Clones the cluster identity from a live node (so no secrets are stored here),
# patches it for the new node, and brings the VM up with a dedicated storage
# disk. Written so a console "add node" flow can call it with the same inputs.
#
# Usage:
#   scripts/talos-node-add.sh \
#     --pve-host 162.55.99.90 --pve-ssh-pass-env HYPATIA_ROOT_PW \
#     --name talos-prod-cp4 --vmid 9303 --ip 10.0.0.93 --zone hypatia \
#     --mac bc:24:11:c4:04:93 --bridge vmbr3 --mtu 1370 \
#     --root-store lvm-hypatia --root-gb 300 \
#     --data-store lvm-hypatia-longhorn --data-gb 900 \
#     --template-node 10.0.0.92 --api-endpoint 10.0.0.90
#
# Requires: talosctl + kubectl on the caller, TALOSCONFIG exported, and either
# an SSH key to the PVE host or a password in the env var named by
# --pve-ssh-pass-env (never pass the password itself on the command line).
#
# Two failure modes this script exists to prevent, both hit while building cp4:
#
#   1. Talos >= 1.13 uses predictable interface names (ens18), so a config
#      written against `interface: eth0` silently never applies. The node then
#      keeps its DHCP address and joins etcd with the WRONG peer URL, which can
#      only be fixed by resetting the node. We always select the interface by
#      MAC, so the static address applies on the first boot.
#   2. On a remote node the overlay MTU is smaller than 1500. If it is not set
#      on the interface, pings succeed and large packets vanish. --mtu is
#      mandatory when --bridge is not the default LAN bridge.
set -euo pipefail

PVE_HOST=""; PVE_PASS_ENV=""; NAME=""; VMID=""; IP=""; ZONE=""; MAC=""
BRIDGE="vmbr0"; VLAN=""; MTU=""; ROOT_STORE=""; ROOT_GB="300"
DATA_STORE=""; DATA_GB=""; TEMPLATE_NODE=""; API_ENDPOINT=""
CORES="6"; MEMORY="24576"; TALOS_VER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --pve-ssh-pass-env) PVE_PASS_ENV="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --vmid) VMID="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --mac) MAC="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --vlan) VLAN="$2"; shift 2 ;;
    --mtu) MTU="$2"; shift 2 ;;
    --root-store) ROOT_STORE="$2"; shift 2 ;;
    --root-gb) ROOT_GB="$2"; shift 2 ;;
    --data-store) DATA_STORE="$2"; shift 2 ;;
    --data-gb) DATA_GB="$2"; shift 2 ;;
    --template-node) TEMPLATE_NODE="$2"; shift 2 ;;
    --api-endpoint) API_ENDPOINT="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

for v in PVE_HOST NAME VMID IP MAC ROOT_STORE TEMPLATE_NODE API_ENDPOINT; do
  [ -n "${!v}" ] || { echo "talos-node-add: --${v,,} is required" >&2; exit 1; }
done
[ "$BRIDGE" = "vmbr0" ] || [ -n "$MTU" ] || {
  echo "talos-node-add: --mtu is required on a non-default bridge (overlay MTU)" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; chmod 700 "$WORK"

pve() {  # run a command on the Proxmox host
  if [ -n "$PVE_PASS_ENV" ]; then
    SSHPASS="${!PVE_PASS_ENV}" sshpass -e ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@${PVE_HOST}" "$@"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${PVE_HOST}" "$@"
  fi
}

echo "==> reading cluster identity from live node ${TEMPLATE_NODE}"
talosctl --endpoints "$API_ENDPOINT" -n "$TEMPLATE_NODE" get machineconfig -o yaml \
  | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and isinstance(d.get("spec"), str):
        sys.stdout.write(d["spec"]); break
' > "$WORK/template.yaml"
chmod 600 "$WORK/template.yaml"
[ -s "$WORK/template.yaml" ] || { echo "could not read template config" >&2; exit 1; }

TALOS_VER=$(python3 -c '
import yaml,sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and "machine" in d:
        print(d["machine"]["install"]["image"].rsplit(":",1)[1]); break
' "$WORK/template.yaml")
SCHEMATIC=$(python3 -c '
import yaml,sys
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and "machine" in d:
        print(d["machine"]["install"]["image"].split("/")[-1].split(":")[0]); break
' "$WORK/template.yaml")
echo "    Talos ${TALOS_VER}, schematic ${SCHEMATIC:0:12}..."

echo "==> ensuring Talos image present on ${PVE_HOST}"
pve "set -e
  cd /var/lib/vz/template/iso 2>/dev/null || cd /tmp
  IMG=talos-${TALOS_VER}-metal-amd64.raw
  if [ ! -f \"\$IMG\" ]; then
    curl -sSL -o img.zst 'https://factory.talos.dev/image/${SCHEMATIC}/${TALOS_VER}/metal-amd64.raw.zst'
    zstd -d -f img.zst -o \"\$IMG\" >/dev/null && rm -f img.zst
  fi
  echo \"    image: \$(pwd)/\$IMG\""

echo "==> creating VM ${VMID} (${NAME})"
NET="virtio=${MAC},bridge=${BRIDGE},firewall=0"
[ -n "$VLAN" ] && NET="${NET},tag=${VLAN}"
[ -n "$MTU" ] && NET="${NET},mtu=${MTU}"
pve "set -e
  if qm status ${VMID} >/dev/null 2>&1; then echo '    VM exists, reusing'; else
    qm create ${VMID} --name ${NAME} --cores ${CORES} --memory ${MEMORY} --balloon 0 \
      --cpu host --numa 1 --bios seabios --ostype l26 --scsihw virtio-scsi-pci \
      --serial0 socket --vga serial0 --agent enabled=1 --onboot 1 \
      --tags 'talos;infraweaver' --net0 '${NET}'
  fi
  IMG=\$(ls /var/lib/vz/template/iso/talos-${TALOS_VER}-metal-amd64.raw /tmp/talos-${TALOS_VER}-metal-amd64.raw 2>/dev/null | head -1)
  if ! qm config ${VMID} | grep -q '^virtio0:'; then
    qm importdisk ${VMID} \"\$IMG\" ${ROOT_STORE} >/dev/null
    qm set ${VMID} --virtio0 ${ROOT_STORE}:vm-${VMID}-disk-0,aio=io_uring,discard=on,cache=none >/dev/null
    qm resize ${VMID} virtio0 ${ROOT_GB}G >/dev/null
  fi
  if [ -n '${DATA_STORE}' ] && ! qm config ${VMID} | grep -q '^virtio1:'; then
    qm set ${VMID} --virtio1 ${DATA_STORE}:${DATA_GB},aio=io_uring,discard=on,cache=none >/dev/null
  fi
  qm set ${VMID} --boot order=virtio0 >/dev/null
  qm start ${VMID} 2>/dev/null || true
  echo '    VM started'"

echo "==> building node config (MAC-selected interface, static ${IP})"
python3 - "$WORK/template.yaml" "$WORK/node.yaml" "$IP" "$MAC" "$NAME" "${MTU:-0}" "${ZONE:-}" "${DATA_STORE:-}" <<'PY'
import sys, yaml
src, dst, ip, mac, name, mtu, zone, data_store = sys.argv[1:9]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
out = []
for d in docs:
    if "machine" in d:
        m = d["machine"]
        iface = m["network"]["interfaces"][0]
        iface.pop("interface", None)
        iface["deviceSelector"] = {"hardwareAddr": mac.lower()}   # never eth0: see header
        iface["addresses"] = ["%s/24" % ip]
        iface["dhcp"] = False
        if int(mtu):
            iface["mtu"] = int(mtu)
        m["network"]["interfaces"] = [iface]
        m["install"]["disk"] = "/dev/vda"
        sans = set(m.get("certSANs") or []); sans.add(ip); m["certSANs"] = sorted(sans)
        if zone:
            labels = m.get("nodeLabels") or {}
            labels["topology.kubernetes.io/zone"] = zone
            m["nodeLabels"] = labels
        out.append(d)
    elif d.get("kind") == "HostnameConfig":
        d["hostname"] = name
        out.append(d)
if data_store:
    out.append({
        "apiVersion": "v1alpha1", "kind": "UserVolumeConfig", "name": "longhorn",
        "provisioning": {"diskSelector": {"match": 'disk.transport == "virtio" && !system_disk'},
                         "minSize": "100GB"},
        "filesystem": {"type": "xfs"},
    })
yaml.safe_dump_all(out, open(dst, "w"), default_flow_style=False, sort_keys=False)
PY
chmod 600 "$WORK/node.yaml"

echo "==> waiting for maintenance mode, then applying config"
for i in $(seq 1 30); do
  if talosctl apply-config --insecure -n "$IP" -f "$WORK/node.yaml" >/dev/null 2>&1; then
    echo "    applied at ${IP}"; break
  fi
  # In maintenance the node may still be on DHCP; the operator supplies that
  # address via MAINT_IP when the node cannot be reached at its target IP.
  if [ -n "${MAINT_IP:-}" ] && talosctl apply-config --insecure -n "$MAINT_IP" -f "$WORK/node.yaml" >/dev/null 2>&1; then
    echo "    applied at ${MAINT_IP} (maintenance address)"; break
  fi
  sleep 20
done

echo "==> waiting for node to become Ready"
for i in $(seq 1 40); do
  if [ "$(kubectl get node "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
    echo "    ${NAME} Ready at ${IP}"; break
  fi
  sleep 15
done

if [ -n "$DATA_STORE" ]; then
  echo "==> pointing Longhorn at the dedicated disk (/var/mnt/longhorn)"
  kubectl -n longhorn-system patch nodes.longhorn.io "$NAME" --type=merge -p "{
    \"spec\":{\"disks\":{\"data-${ZONE:-extra}\":{\"path\":\"/var/mnt/longhorn\",\"allowScheduling\":true,
    \"evictionRequested\":false,\"storageReserved\":0,\"tags\":[\"${ZONE:-extra}\"],\"diskType\":\"filesystem\"}}}}" >/dev/null
  echo "    added. Disable the default /var/lib/longhorn disk separately —"
  echo "    Longhorn refuses add+remove in one request and needs a sync gap between them."
fi

echo "==> done: ${NAME} (${IP}) zone=${ZONE:-none}"
