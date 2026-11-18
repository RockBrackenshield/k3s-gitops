# Runbook: Talos and Kubernetes upgrade, one node at a time

Based on k3s-gitops `main` at `37b7a7c`. File references mean that file at 37b7a7c.

## Purpose, scope, when to use

Move the cluster to a new Talos release, or a new Kubernetes patch or minor release, one node at a time. Current pins (`talos/versions.env`):

| Pin | Value |
|---|---|
| `TALOS_VERSION` | v1.14.4 |
| `KUBERNETES_VERSION` | 1.36.5 |
| `CILIUM_VERSION` | 1.20.4 |
| `SCHEMATIC_RPI4` / `SCHEMATIC_RPI5` | schematic IDs |
| `INSTALLER_DIGEST_RPI4` / `INSTALLER_DIGEST_RPI5` | installer digests |

Use it when Renovate opens a bump PR (`infrastructure/renovate/configmap.yaml` watches the annotated lines), or when Rock decides to upgrade.

Out of scope:
- Cilium upgrades.
- Kubernetes **1.37**, which waits until Cilium 1.20 lists it as tested (comment in `talos/versions.env`).

| Node | IP | Board, installer | Notes |
|---|---|---|---|
| k3s-worker-1 | 192.168.7.11 | Pi 4, `INSTALLER_rpi4` | upgrade first |
| k3s-worker-2 | 192.168.7.13 | Pi 4, `INSTALLER_rpi4` | second |
| k3s-master | 192.168.7.15 | Pi 5, `INSTALLER_rpi5` | last; single control plane |

(`talos/Makefile`: `IP_*`, `BOARD_*`, `INSTALLER_*`.)

> **Teaching point:** k3s-master is the only control plane. It also holds the only Longhorn disk (`infrastructure/longhorn/values.yaml`, replicas 1) and answers the pinned LoadBalancer IPs, DNS on .202 and Traefik on .205 (`docs/runbook-restore.md`). While it upgrades, expect the API, all Longhorn volumes, LAN DNS and ingress to be down for several minutes. Pick a quiet window. Clients fall back to the router's secondary DNS.

## Prerequisites

- [ ] Read the Talos release notes for the target version, including the supported Kubernetes range.
- [ ] `talosctl` matching the **target** Talos version, checked against its release `sha256sum.txt`. Record the checksums in `talos/versions.env` (`TALOSCTL_SHA256_*`).
- [ ] A fresh, verified etcd snapshot (`etcd-backup-restore.md`, Part A).
- [ ] VolSync backups recent: `kubectl get replicationsource -A`, check `lastSyncTime`.
- [ ] All three nodes Ready, and `talosctl -n 192.168.7.15 health` passes.
- [ ] The SOPS age key, for `make -C talos gen` (`sops-age-keys.md`).
- [ ] A tailscale file for every node. At 37b7a7c only `talos/nodes/k3s-master.tailscale.sops.yaml` exists. Without the worker files, `make gen` fails on the workers (see the `TS_SRC` input in `talos/Makefile`). Create them first with `sops-age-keys.md` Task C.

## Part A: prepare the change (in a PR)

### A1. Bump the pins
Edit `talos/versions.env`:
- `TALOS_VERSION`
- `TALOSCTL_SHA256_LINUX_AMD64` / `_ARM64`
- `INSTALLER_DIGEST_RPI4` / `_RPI5`: the multi-arch index digest of `factory.talos.dev/metal-installer/<SCHEMATIC_ID>:<TALOS_VERSION>`. Resolve it on your workstation with a registry tool you trust.

If extensions change, edit `talos/schematics/rpi{4,5}.yaml` and set `SCHEMATIC_RPI*` to the sha256 of each file. Don't reformat those files (`talos/README.md`).
**Verify:** `git diff` touches only the intended lines.

### A2. Update the board patches
Set the `installer.image` line in `talos/patches/rpi4.yaml` and `talos/patches/rpi5.yaml` to `factory.talos.dev/metal-installer/<SCHEMATIC_ID>:<TALOS_VERSION>@<INSTALLER_DIGEST>`.
**Verify:** `scripts/check-versions.sh` passes. It compares the patches with `versions.env`.

### A3. Offline checks
```bash
make -C talos schematic-check      # needs network: asks factory.talos.dev that the IDs exist
make -C talos render-test          # throwaway secrets, nothing kept
scripts/tests/talos-makefile_test.sh
```
**Verify:** all three pass, and CI (`.github/workflows/talos.yml`, `validate.yml`) is green on the PR. Rock merges.

## Part B: upgrade Talos, one node at a time

### B1. Render configs from merged `main`
```bash
git pull && make -C talos gen validate
```
**Verify:** `validate` passes for all three nodes.

### B2. k3s-worker-1
```bash
make -C talos upgrade NODE=k3s-worker-1     # talosctl upgrade -n 192.168.7.11 --image <INSTALLER_rpi4>
```
UNVERIFIED: the drain, stage and preserve behaviour of your `talosctl upgrade` version. Read `talosctl upgrade --help` before the first run.

**Verify:**
- `talosctl -n 192.168.7.11 version`: the server Tag equals the new `TALOS_VERSION`.
- `talosctl -n 192.168.7.11 get extensions`: the schematic ID equals `SCHEMATIC_RPI4`.
- `kubectl get nodes`: k3s-worker-1 is Ready.
- `talosctl -n 192.168.7.15 health` passes.

### B3. k3s-worker-2
Same as B2, with `NODE=k3s-worker-2` and 192.168.7.13. **Verify:** the same checks.

### B4. k3s-master (last)
```bash
make -C talos etcd-backup          # one more snapshot right before (then encrypt, Part A of etcd runbook)
make -C talos upgrade NODE=k3s-master
```
**Verify:**
- `talosctl -n 192.168.7.15 version` shows the new version.
- `get extensions` equals `SCHEMATIC_RPI5`.
- `etcd status` is healthy.
- `talosctl -n 192.168.7.15 get volumestatus u-longhorn` is ready.
- `kubectl -n longhorn-system get volumes.longhorn.io`: every volume is attached and healthy, or detached where no workload uses it.
- `dig @192.168.7.202 hermnet.org` resolves (`docs/runbook-restore.md` Phase 5).

## Part C: upgrade Kubernetes

Upgrade one minor version at a time, and stay at or below 1.36.x for now.

### C1. Pin it (PR)
Set `KUBERNETES_VERSION` in `talos/versions.env` **and** `K8S_VERSION` in `.github/workflows/validate.yml`. `scripts/check-versions.sh` enforces that they match. The `.github/` edit is Rock's to make.
**Verify:** `scripts/check-versions.sh` and CI pass.

### C2. Dry run, then upgrade
```bash
talosctl -n 192.168.7.15 upgrade-k8s --to <KUBERNETES_VERSION> --dry-run
talosctl -n 192.168.7.15 upgrade-k8s --to <KUBERNETES_VERSION>
```
**Verify:**
- `kubectl get nodes -o wide`: all three nodes show the new kubelet version.
- `kubectl version` shows the new server version.
- `kubectl get pods -A | grep -v -E 'Running|Completed'` lists nothing unexpected.

### C3. Re-render
Run `make -C talos gen validate` so later applies carry the new version.

## Rollback

- **Talos on one node:**
  ```bash
  talosctl -n <NODE_IP> rollback
  ```
  Talos keeps the previous image in its A/B slots. Then revert the `versions.env` and patches PR.
  **Verify:** `talosctl version` shows the old Tag.
- **Kubernetes patch version:** `upgrade-k8s --to <PREVIOUS_PATCH>`. Minor-version downgrades are not supported. Last resort: an etcd restore (`etcd-backup-restore.md`, Part B) taken before C2.
- **Node won't boot:** reflash with the old image (`make -C talos images` on the old commit), then `apply INSECURE=1`. Maintenance mode sends the full machine config, **including the cluster CA keys**, to a node that has not been authenticated. Run it only from the trusted wired LAN, and only after `talosctl get disks --insecure -n <NODE_IP>` shows the expected disks for that node.

## References

- `talos/versions.env`
- `talos/Makefile` (`upgrade`, `gen`, `validate`, `render-test`, `schematic-check`, `images`)
- `talos/patches/rpi4.yaml`, `talos/patches/rpi5.yaml`, `talos/schematics/`
- `scripts/check-versions.sh`, `scripts/tests/talos-makefile_test.sh`
- `.github/workflows/talos.yml`, `.github/workflows/validate.yml`
- `infrastructure/renovate/configmap.yaml`
- `docs/runbook-restore.md`
- Talos docs: "Upgrading Talos", "Upgrading Kubernetes" (v1.14)
- Project notes: `talos-rpi-cluster-notes.md` (overlays, `extraKernelArgs`, EEPROM)

## Staleness note (Flux PRs)

- `scripts/check-versions.sh` reads the Cilium version from `bootstrap/apps/cilium.yaml`, an Argo Application. After go-live (#10), Cilium is the Flux HelmRelease in `flux/releases/cilium/helmrelease.yaml` (draft #9).
- TBD: update `check-versions.sh` and the `versions.env` comment to read the HelmRelease. No open Flux PR does this yet.
- Renovate's managers change in #11, the Flux manager. Re-check which `versions.env` lines it bumps.
- The health checks gain `flux get helmreleases -A`. The Talos steps themselves don't change.
