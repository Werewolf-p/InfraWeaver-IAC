#!/usr/bin/env bash
# hypatia-host-setup.sh — the Proxmox-host side of the remote site, as code.
#
# Everything below was applied by hand on 2026-08-14 while bringing hypatia in
# as a third failure domain. This script is the record of it and re-applies it
# idempotently, so the host can be rebuilt without archaeology.
#
#   scripts/hypatia-host-setup.sh --host 162.55.99.90 --pass-env HYPATIA_ROOT_PW
#   scripts/hypatia-host-setup.sh --host 162.55.99.90 --dry-run
#
# What it establishes:
#   1. Two-disk split. The VG named `pve` (boot disk) carries VM images and
#      backups; a second VG named `longhorn` carries replicated storage.
#      NOTE: identify disks by VG NAME, never /dev/nvmeXn1 — the enumeration
#      order changed between two reboots on this exact machine.
#   2. PVE storage entries pinned to this node.
#   3. NAT for the guest network, so guests egress locally instead of
#      hairpinning through the home WAN over the WireGuard tunnel. Without it,
#      container image pulls on the remote Talos node never complete.
#
# Not covered here (deliberately, they live elsewhere):
#   - the layer-2 site link  -> sites/hypatia.yaml + scripts/site-link.sh
#   - the Talos node itself  -> scripts/talos-node-add.sh
set -euo pipefail

HOST=""; PASS_ENV=""; DRY=0
GUEST_NET="10.1.10.0/24"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --pass-env) PASS_ENV="$2"; shift 2 ;;
    --guest-net) GUEST_NET="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$HOST" ] || { echo "usage: --host <pve-host> [--pass-env ENVVAR]" >&2; exit 1; }

remote() {
  if [ -n "$PASS_ENV" ]; then
    SSHPASS="${!PASS_ENV}" sshpass -e ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@${HOST}" "$@"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${HOST}" "$@"
  fi
}

read -r -d '' SCRIPT <<EOF || true
set -e
echo "== volume groups =="
vgs --noheadings -o vg_name | tr -d ' ' | sed 's/^/   /'

if ! vgs longhorn >/dev/null 2>&1; then
  echo "   VG 'longhorn' missing."
  echo "   Create it on the NON-boot disk only, e.g.:"
  echo "     vgremove -f <stale-vg-on-that-disk>"
  echo "     pvcreate /dev/<disk>p3 && vgcreate longhorn /dev/<disk>p3"
  echo "   Refusing to guess which disk — losing the wrong one is unrecoverable."
fi

echo "== backup volume on the local disk =="
if lvs pve/backup >/dev/null 2>&1; then
  echo "   pve/backup exists"
else
  lvcreate -V 250G -T pve/data -n backup
  mkfs.ext4 -q -L pve-backup /dev/pve/backup
  echo "   created pve/backup"
fi
mkdir -p /mnt/pve-backup
grep -q "/mnt/pve-backup" /etc/fstab || echo "/dev/pve/backup /mnt/pve-backup ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /mnt/pve-backup || mount /mnt/pve-backup

echo "== PVE storages (pinned to this node) =="
NODE=\$(hostname)
pvesm status --storage lvm-hypatia >/dev/null 2>&1 || \
  pvesm add lvmthin lvm-hypatia --vgname pve --thinpool data --content images,rootdir --nodes "\$NODE"
if vgs longhorn >/dev/null 2>&1; then
  pvesm status --storage lvm-hypatia-longhorn >/dev/null 2>&1 || \
    pvesm add lvm lvm-hypatia-longhorn --vgname longhorn --content images --nodes "\$NODE"
fi
pvesm status --storage backup-hypatia >/dev/null 2>&1 || \
  pvesm add dir backup-hypatia --path /mnt/pve-backup --content backup,iso,vztmpl --nodes "\$NODE"
pvesm status 2>/dev/null | awk 'NR==1 || /hypatia/' | sed 's/^/   /'

echo "== NAT for the guest network =="
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-guest-forward.conf
iptables -t nat -C POSTROUTING -s ${GUEST_NET} -o vmbr0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s ${GUEST_NET} -o vmbr0 -j MASQUERADE
mkdir -p /etc/network/if-up.d
cat > /etc/network/if-up.d/nat-guest-net <<'HOOK'
#!/bin/sh
[ "\$IFACE" = "vmbr0" ] || exit 0
iptables -t nat -C POSTROUTING -s GUESTNET -o vmbr0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s GUESTNET -o vmbr0 -j MASQUERADE
HOOK
sed -i "s#GUESTNET#${GUEST_NET}#g" /etc/network/if-up.d/nat-guest-net
chmod +x /etc/network/if-up.d/nat-guest-net
iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -i masquerade | sed 's/^/   /'
echo "== done =="
EOF

if [ "$DRY" = "1" ]; then
  echo "$SCRIPT"
  exit 0
fi
remote "bash -s" <<< "$SCRIPT"
