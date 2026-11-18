# Runbook: etcd snapshot backup and restore

Based on k3s-gitops `main` at `37b7a7c`. File references like `talos/Makefile` mean that file at 37b7a7c.

## Purpose, scope, when to use

hermnet has one control-plane node, **k3s-master** (192.168.7.15, Pi 5), and etcd runs on its SD card (`talos/README.md`, `talos/Makefile` `CP_IP`). If that card dies, the cluster's state is gone. An etcd snapshot is the only way back without rebuilding everything from git and restoring every volume.

Use this runbook:
- **Routinely:** at least weekly, and before every Talos or Kubernetes upgrade (`talos-k8s-upgrade.md`) or risky change.
- **For recovery:** when k3s-master's etcd is lost or corrupt and the node has to be reflashed.

Out of scope:
- Volume data. See `app-data-restore.md`.
- A full rebuild with new secrets. See `docs/runbook-restore.md`.
- Automated off-site upload. That is `docs/to-do.md` item 1 and is not built yet.

> **Teaching point:** a snapshot holds every Kubernetes Secret in plaintext, including the ones SealedSecrets decrypted. Treat it like a password vault. `.gitignore` already ignores `*.snapshot` and `talos/_out/`.

## Prerequisites

- [ ] A repo checkout and a working `talos/_out/talosconfig`, produced by `make -C talos gen` (`talos/Makefile`).
- [ ] `talosctl` at the version in `talos/versions.env` (`TALOS_VERSION=v1.14.4`; the checksums are in the same file).
- [ ] The SOPS age key, so `talos/secrets.sops.yaml` decrypts (`sops-age-keys.md`).
- [ ] `age`, plus a backup recipient public key `<AGE_BACKUP_PUBLIC_KEY>`. The matching private key must **not** live only on the workstation.
- [ ] An off-cluster storage location `<SNAPSHOT_OFFSITE_LOCATION>` (NAS, encrypted USB drive, or bucket).

## Part A: take a backup

### A1. Check etcd health
```bash
export TALOSCONFIG=$PWD/talos/_out/talosconfig
talosctl -n 192.168.7.15 health
talosctl -n 192.168.7.15 etcd status
```
**Verify:** health passes and etcd status shows one member with no errors. Note the DB size for the next step.

### A2. Snapshot (`talos/Makefile` target `etcd-backup`)
```bash
umask 077                        # the snapshot holds every Secret in plaintext
make -C talos etcd-backup        # writes talos/_out/etcd-YYYY-MM-DD.snapshot
chmod 600 talos/_out/etcd-$(date +%F).snapshot   # talosctl's own file mode is UNVERIFIED
```
**Verify:** `ls -l talos/_out/etcd-$(date +%F).snapshot` shows `-rw-------`, is non-empty, and is roughly the DB size from A1.

### A3. Encrypt and remove the plaintext
```bash
SNAP=talos/_out/etcd-$(date +%F).snapshot
sha256sum "$SNAP" > "$SNAP.sha256"           # record the plaintext hash for the restore drill
age -r <AGE_BACKUP_PUBLIC_KEY> -o "$SNAP.age" "$SNAP"
head -c 21 "$SNAP.age"; echo                 # expect: age-encryption.org/v1
ls -l "$SNAP" "$SNAP.age"                    # .age is slightly larger than the plaintext
shred -u "$SNAP"
```
The backup **private** key must stay off this workstation, so don't decrypt here. Instead, run the full round-trip on the offline host during the periodic restore drill: `age -d -i <AGE_BACKUP_PRIVATE_KEY_PATH> <FILE>.age | sha256sum`, compared with the saved `.sha256`.

`shred` is unreliable on SSDs and journaling or copy-on-write filesystems. Keep `talos/_out/` on tmpfs or an encrypted disk if you can.
**Verify:**
- The `.age` header line reads `age-encryption.org/v1`, and its size is a little above the plaintext's.
- After `shred`, only `$SNAP.age` and `$SNAP.sha256` remain.

### A4. Store off-cluster
Copy `etcd-YYYY-MM-DD.snapshot.age` to `<SNAPSHOT_OFFSITE_LOCATION>`. Keep at least 4 weekly copies plus the one from before the last upgrade. Old snapshots hold old credentials, so delete copies that fall outside the retention window.
**Verify:** list the remote copy and compare its size or sha256 with the local file.

TBD: automate this (encrypted upload to B2, or the siderolabs/talos-backup CronJob) per `docs/to-do.md` item 1. Rock decides where it goes and what retention to use.

## Part B: restore the control plane from a snapshot

Use Part B only when k3s-master has lost etcd. If the node boots and etcd is healthy, stop here.

### B1. Get the snapshot back
```bash
umask 077                        # the decrypted snapshot holds every Secret in plaintext
age -d -i <AGE_BACKUP_PRIVATE_KEY_PATH> -o /dev/shm/etcd-<DATE>.snapshot <SNAPSHOT_OFFSITE_LOCATION>/etcd-<DATE>.snapshot.age
```
`/dev/shm` is RAM-backed, so the plaintext never touches disk.
**Verify:** `ls -l /dev/shm/etcd-<DATE>.snapshot` shows `-rw-------` and a plausible size. If you have the `.sha256` from A3, it matches.

### B2. Reflash and reapply k3s-master
Follow `docs/runbook-restore.md` Phase 1 for flashing. Then:
```bash
make -C talos gen validate
make -C talos apply NODE=k3s-master INSECURE=1
```
`INSECURE=1` (maintenance mode) sends the full machine config, **including the cluster CA keys**, to a node that has not been authenticated. Run it only from the trusted wired LAN, and only after `talosctl get disks --insecure -n 192.168.7.15` shows the expected disks for k3s-master (`docs/runbook-restore.md` Phase 1: "Check on a trusted LAN").
Use the **same** `talos/secrets.sops.yaml`. A new secrets bundle means a new cluster CA: the workers and your kubeconfig would no longer trust the restored control plane.
**Verify:** `talosctl -n 192.168.7.15 version` answers and the node reports the installed Talos version.

### B3. Bootstrap from the snapshot (do not run `make -C talos bootstrap`)
```bash
talosctl -n 192.168.7.15 -e 192.168.7.15 bootstrap --recover-from=/dev/shm/etcd-<DATE>.snapshot
```
A snapshot taken with `talosctl etcd snapshot` carries an integrity hash. `--recover-skip-hash-check` is only for a raw `db` file copied off the disk (Talos disaster-recovery docs).
**Verify:** `talosctl -n 192.168.7.15 etcd status` shows one healthy member, and `talosctl -n 192.168.7.15 health` passes.

Once B3 has succeeded, delete the decrypted copy:
```bash
shred -u /dev/shm/etcd-<DATE>.snapshot
ls /dev/shm/etcd-<DATE>.snapshot     # must fail: "No such file or directory"
```
If B3 fails, keep the file only while you retry (see Rollback), then delete it the same way.

### B4. Kubeconfig, CNI, nodes
```bash
make -C talos kubeconfig
export KUBECONFIG=$PWD/talos/_out/kubeconfig
kubectl get nodes
```
If the nodes are NotReady because Cilium is missing, run `make -C talos cilium-bootstrap` (`docs/runbook-restore.md` Troubleshooting).
**Verify:** all three nodes are Ready (k3s-master, k3s-worker-1, k3s-worker-2). The workers were not reflashed and rejoin by themselves.

### B5. Reconcile
The cluster now looks as it did when the snapshot was taken, **including its Secrets**. A credential rotated after the snapshot date is back at its old value. Re-rotate those credentials, and treat the old values as exposed if they were rotated because of a leak.
**Verify:**
- `kubectl -n argocd get applications`: everything ends up Synced/Healthy.
- `kubectl get replicationsource -A`: the backups are running again.
- Take a fresh snapshot (Part A).

## Rollback

- **Part A** changes nothing on the cluster. To undo, delete the bad artifact.
- **Part B:** if the recover in B3 fails, try an older snapshot. Decrypt it the same way (B1, with `umask 077`), and delete every decrypted copy afterwards. If none works, do a full rebuild with `make restore KEY=...` (root `Makefile`) and `docs/runbook-restore.md`, then restore data with `app-data-restore.md`.

## References

- `talos/Makefile` (`etcd-backup`, `bootstrap`, `kubeconfig`, `cilium-bootstrap`)
- `talos/README.md`
- `docs/runbook-restore.md` (Phase 1, Troubleshooting)
- `docs/to-do.md` item 1
- `.gitignore`
- Talos docs: "Disaster Recovery" (v1.14)
- Project notes: `talos-migration-plan-rev3` ("SD card wear")

## Staleness note (Flux PRs #12, #9, #10, #11)

- The Talos steps don't change.
- B4/B5 change wording. "Argo adopts Cilium" becomes Flux's HelmRelease `cilium` (`flux/releases/cilium/` in draft #9), and the check becomes `flux get kustomizations -A`, `flux get helmreleases -A`.
- Plan v3 builds a **new** cluster. A snapshot from the old Argo cluster must never be restored onto the new one. Label snapshots by cluster.
- TBD: the cluster naming and labelling scheme for snapshots once both clusters exist.
