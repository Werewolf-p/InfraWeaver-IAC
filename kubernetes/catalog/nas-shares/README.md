# NAS shares — generated, do not hand-edit

Every file here is written by the InfraWeaver console's NAS flow
(`Storage → NAS & external → Shares & folders → Mount to workload`), and read
back by `/api/nas/mounts`.

Per mounted folder, per namespace, per access mode:

- a **static `PersistentVolume`** pointing at exactly one directory on the NAS
  (`csi.volumeAttributes.subDir`), pre-bound to its claim via `claimRef`,
- its **`PersistentVolumeClaim`**,
- a credential **`ExternalSecret`** (`nas-<provider>-<ro|rw>`) resolving
  `secret/platform/nas/creds/<provider>-<ro|rw>` from OpenBao.

## Why static PVs and not a StorageClass

`smb.csi.k8s.io` has two defaults that are wrong for mounting an *existing*
folder, and both fail silently:

- an empty `subDir` is replaced by the generated PV name, so the pod mounts
  `//host/share/pvc-<uuid>` instead of the folder you chose;
- `onDelete` defaults to `delete`, so removing the PV makes the CSI controller
  **recursively delete the directory on the NAS**.

A static PV names the directory explicitly, has `persistentVolumeReclaimPolicy:
Retain`, and gives the controller no provisioning path at all. Unmounting a
folder removes Kubernetes objects and never touches data.

## Read-only means read-only

Three independent layers, all emitted together. Removing any one of them is a
security regression:

1. **NAS** — the PV references the `…-ro` credential, whose service account
   holds only a `READ` ACE on the folder.
2. **Kernel** — `mountOptions: [ro]` and `csi.readOnly: true` on the PV.
3. **Pod** — `readOnly: true` on the container's `volumeMount`.

This directory is synced by `kubernetes/bootstrap/catalog-nas-shares.yaml`.
