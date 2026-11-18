# Runbook: add or replace a Longhorn disk

Based on k3s-gitops `main` at `37b7a7c`. File references mean that file at 37b7a7c.

## Purpose, scope, when to use

Today Longhorn has **one** disk: the USB disk on k3s-master (192.168.7.15), mounted at `/var/mnt/longhorn`. Every volume has 1 replica, so the backups are the only protection (`infrastructure/longhorn/values.yaml`, `storage-class.yaml`).

Use this runbook to:
- **Add** a USB SSD to a worker and then raise replicas to 2 (`docs/to-do.md` item 3, `talos/README.md` "Adding a disk later").
- **Replace** k3s-master's disk when it is failing or being upgraded.

The example uses k3s-worker-1 (192.168.7.11). For k3s-worker-2 (192.168.7.13), change the name and IP.

> **Teaching point: how a disk becomes Longhorn storage.** Three layers each have to agree:
> 1. **Talos:** a `UserVolumeConfig` named `longhorn` turns a physical disk into partition `u-longhorn`, mounted at `/var/mnt/longhorn` (`talos/nodes/k3s-master.yaml`).
> 2. **Longhorn Node CR:** registers that path as a disk and gives it **tags** (`infrastructure/longhorn/node-disk-config.yaml`: disk tag `usb`, node tag `usb-node`).
> 3. **StorageClass:** `longhorn-usb` (the default) and `longhorn-usb-eph` only place replicas on disks tagged `usb`, on nodes tagged `usb-node` (`infrastructure/longhorn/storage-class*.yaml`).
>
> If you skip the tags, the disk shows up in Longhorn but no `longhorn-usb` volume ever uses it. `talos/README.md` step 3 leaves the tags out; this runbook adds them.

> **Repo note:** `talos/README.md` says the disk is selected "by serial". At 37b7a7c, `talos/nodes/k3s-master.yaml` actually matches `disk.transport == "usb" && !system_disk && disk.rotational == true && disk.wwid.contains("t.10SABRENT")`. For new worker disks, select by serial as the README recommends.
>
> **Selection risk:** that `wwid.contains("t.10SABRENT")` match fits *any* Sabrent rotational USB disk. Before a second Sabrent disk is ever attached to k3s-master, including during Part B when old and new may both be plugged in, switch k3s-master's selector to `disk.serial == "<DISK_SERIAL>"` (PR, then `make -C talos gen apply NODE=k3s-master`). UNVERIFIED: whether Talos would provision onto an unintended matching disk.

## Prerequisites

- [ ] A fresh etcd snapshot (`etcd-backup-restore.md`).
- [ ] Recent VolSync backups: `kubectl get replicationsource -A`, check `lastSyncTime`.
- [ ] The SOPS key and every node's tailscale file, so `make -C talos gen` works (`sops-age-keys.md` Task C).
- [ ] A disk at least as large as the volumes you want replicated there. `media` alone is about 500Gi (`infrastructure/storage/media/longhorn-volume.yaml`).
- [ ] The Pi 4 can power the disk. Use a powered hub if needed. UNVERIFIED for your exact SSD.

## Part A: add a disk to a worker

### A1. Identify the disk
Plug it in, then run:
```bash
talosctl -n 192.168.7.11 get disks
```
**Verify:** a new non-system disk appears, and you have its **serial** (`<DISK_SERIAL>`) and size. `mmcblk0` is the SD card and system disk (`talos/patches/rpi4.yaml`). Never select by `/dev/sdX`.

### A2. Describe it to Talos (PR)
Append to `talos/nodes/k3s-worker-1.yaml`, using the same shape as k3s-master:
```yaml
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: disk.transport == "usb" && disk.serial == "<DISK_SERIAL>" && !system_disk
  minSize: <MIN_SIZE>      # e.g. near the disk size, like k3s-master's 100GB
  grow: true
filesystem:
  type: xfs
```
**Verify:** `make -C talos render-test` passes and CI is green. Rock merges.

### A3. Apply
```bash
make -C talos gen validate
make -C talos apply NODE=k3s-worker-1
```
**Verify:** `talosctl -n 192.168.7.11 get volumestatus u-longhorn` shows it ready, and `talosctl -n 192.168.7.11 get mountstatus` lists `/var/mnt/longhorn`.

### A4. Register it in Longhorn with tags (PR)
Add a second document to `infrastructure/longhorn/node-disk-config.yaml`, modelled on the k3s-master one:
```yaml
---
apiVersion: longhorn.io/v1beta2
kind: Node
metadata:
  name: k3s-worker-1
  namespace: longhorn-system
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  allowScheduling: true
  tags: [usb-node]
  disks:
    usb-longhorn-disk:
      diskType: filesystem
      path: /var/mnt/longhorn
      allowScheduling: true
      storageReserved: 0
      tags: [usb]
```
Don't add the `node.longhorn.io/create-default-disk` label as well. Longhorn would then create an untagged default disk at the same path (`values.yaml`: `createDefaultDiskLabeledNodes: true`).

After merge, Argo's `longhorn` app syncs it. It may need a manual sync (`docs/runbook-restore.md` Troubleshooting "Longhorn disk missing").

**Verify:** `kubectl -n longhorn-system get nodes.longhorn.io k3s-worker-1 -o yaml` shows the disk with tag `usb`, `allowScheduling: true`, a non-zero `storageMaximum` and a Ready condition.

### A5. Raise replicas on live volumes
One volume at a time, smallest first:
```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system patch volumes.longhorn.io <VOLUME> --type merge -p '{"spec":{"numberOfReplicas":2}}'
```
**Verify:** `kubectl -n longhorn-system get volumes.longhorn.io <VOLUME> -o jsonpath='{.status.robustness}'` returns `healthy`, with 2 running replicas on two nodes. `replicaSoftAntiAffinity: true` lets them share a node only if they have to.

### A6. Make it the default in git (PR)
Set the replica count to 2 in all four places:
- `infrastructure/longhorn/values.yaml`: `defaultReplicaCount` and `defaultClassReplicaCount`.
- `infrastructure/longhorn/storage-class.yaml` and `storage-class-eph.yaml`: `numberOfReplicas: "2"`.
- `infrastructure/storage/*/longhorn-volume.yaml`: `numberOfReplicas`.

Note: StorageClass `parameters` are immutable in Kubernetes, so Argo can't update them in place. TBD: Rock decides whether to delete and recreate the two StorageClasses (safe for existing PVs; UNVERIFIED with this Argo setup) or add new classes.

**Verify:** after sync, Argo shows Synced/Healthy and a newly created test PVC gets 2 replicas.

## Part B: replace k3s-master's disk

With 1 replica, **eviction has nowhere to go**. Before either path, make sure k3s-master's selector is serial-based (see the selection-risk note at the top). Pick one path:

**B-1. With a second disk present (after Part A):**
1. Raise every volume to 2 replicas (A5) and wait until all are healthy.
2. In `node-disk-config.yaml`, set `allowScheduling: false` and `evictionRequested: true` on k3s-master's disk (PR).
3. Wait until the disk shows **0** replicas.
4. Swap the disk. Update the `diskSelector` in `talos/nodes/k3s-master.yaml` to the new disk's serial, then `make -C talos gen apply NODE=k3s-master`.
5. Re-enable scheduling.

**B-2. Without a second disk:**
1. Make sure the backups are current.
2. Image the old disk off the node (`docs/runbook-restore.md` Phase 0).
3. Swap the disk, update the selector and apply.
4. Restore the data with `app-data-restore.md`.

**Verify (both):** `volumestatus u-longhorn` is ready, the k3s-master Node CR has exactly one disk at `/var/mnt/longhorn`, and all volumes are healthy.

Wiping an old disk (`talosctl -n <NODE_IP> wipe disk <DEV>`) is destructive, and it selects by device name, so it is the one exception to "never select by /dev/sdX". Before wiping:
1. Check `talosctl wipe disk --help`.
2. Confirm the disk shows **0** replicas.
3. **Immediately before** the wipe, run `talosctl -n <NODE_IP> get disks` again and confirm that `<DEV>` has the expected `<DISK_SERIAL>`. Device names can change across reboots and replugs.

**Verify:** the serial for `<DEV>` matches what you expect, in the same terminal session, seconds before you wipe.

## Rollback

- **Replicas:** patch `numberOfReplicas` back to 1, then revert the A6 PR.
- **New disk misbehaving:**
  1. Set `allowScheduling: false` and `evictionRequested: true` on it.
  2. Wait for 0 replicas.
  3. Remove it from the Node CR and the `UserVolumeConfig` (revert PRs), then `make -C talos gen apply NODE=<HOST>`.
- **Old data, last resort:** `app-data-restore.md`.

## References

- `talos/README.md` ("Adding a disk later")
- `talos/nodes/k3s-master.yaml`, `talos/patches/rpi4.yaml`, `talos/Makefile`
- `infrastructure/longhorn/values.yaml`, `node-disk-config.yaml`, `storage-class.yaml`, `storage-class-eph.yaml`
- `infrastructure/storage/media/longhorn-volume.yaml`
- `bootstrap/apps/longhorn.yaml` (Longhorn 1.13.0)
- `docs/to-do.md` item 3, `docs/runbook-restore.md`
- Longhorn docs: "Node and disk tags", "Evicting replicas" (1.13)

## Staleness note (Flux PRs)

- The Talos steps don't change.
- After go-live (#10), `infrastructure/longhorn/` is applied by the Flux Kustomization `longhorn-config`, and the chart by the `longhorn` HelmRelease with values in `flux/releases/longhorn/values.yaml` (draft #9).
- "Manual Argo sync" becomes `flux reconcile kustomization longhorn-config -n flux-system`.
- A6 must edit `flux/releases/longhorn/values.yaml` instead of, or as well as, `infrastructure/longhorn/values.yaml`.
- The `argocd.argoproj.io/*` annotations in the A4 snippet become irrelevant.
- TBD: which values file is authoritative once both clusters run (plan v3).
