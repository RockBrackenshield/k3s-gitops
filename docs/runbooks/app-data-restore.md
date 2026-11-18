# Runbook: app data restore (VolSync restic, CNPG barman)

Based on k3s-gitops `main` at `37b7a7c`. File references mean that file at 37b7a7c.

## Purpose, scope, when to use

Restore one app's persistent data from its off-site backup after the data is lost or corrupt, or onto a rebuilt cluster. Run it after `docs/runbook-restore.md` Phases 1–2, which bring the cluster up. Its Phase 3 is the summary this runbook expands.

> **Repo inconsistency:** `docs/runbook-restore.md` Phase 3 has you apply the ReplicationDestination first, then rebind via `.status.latestImage` (a Snapshot-style flow). `restore/adguard-restore.yaml` uses `copyMethod: Direct`, which needs the empty PVC to exist **first**. This runbook follows the manifest.

### What is backed up at 37b7a7c

| Data (PVC) | Namespace | StorageClass | Backup | Schedule | Repo source |
|---|---|---|---|---|---|
| `adguard-config` (1Gi) | adguard | longhorn-usb | VolSync `adguard-config-backup` | 02:45 | `infrastructure/adguard/replication-source.yaml` |
| `jellyfin-config` (50Gi) | jellyfin | longhorn-usb | VolSync `jellyfin-config-backup` | 02:30 | `apps/jellyfin/base/replication-source.yaml` |
| `home-assistant-config` (10Gi) | home-assistant | longhorn-usb | VolSync `home-assistant-config` | 02:15 | `apps/home-assistant/replication-source.yaml` |
| Authentik DB dumps, `authentik-postgresql-dumps` (8Gi) | authentik | longhorn | CronJob `authentik-postgresql-dump` (02:30) → VolSync `authentik-postgresql-dumps` (03:10) | | `infrastructure/authentik/backup/*` |
| Paperless DB (CNPG `paperless-postgres`) | paperless | longhorn | barman-cloud ObjectStore `paperless-postgres-store` | 03:00 | `apps/paperless/base/postgres/*`; **not deployed**, see Part C |
| media, metube downloads, paperless NFS | various | | **none in-cluster** | | `docs/runbook-restore.md` Phase 3 step 5 |

All VolSync sources use one restic repository Secret, `shared-b2-repo`. It is created in `volsync-system` and copied into app namespaces by Reflector (`infrastructure/volsync/sealed-shared-b2-repo.yaml`).

> **Findings to check before relying on the backups:**
> 1. The Reflector namespace lists in `sealed-shared-b2-repo.yaml` are `adguard,jellyfin,monitoring,authentik`. **`home-assistant` is missing**, so its ReplicationSource probably cannot find `shared-b2-repo`. Check `kubectl -n home-assistant get secret shared-b2-repo` and the ReplicationSource status.
> 2. Every app shares **one** restic repository at the bucket root. The comment in the same file says VolSync tells apps apart by tags. UNVERIFIED: whether a restore picks the correct app's snapshot. Do a test restore into a scratch PVC first (Part A, step A0).

## Prerequisites

- [ ] Cluster up, with Longhorn, VolSync (chart 0.15.0, `bootstrap/apps/volsync.yaml`), snapshot-controller and Reflector healthy.
- [ ] The Sealed Secrets key restored (`docs/sealed-secrets-backup.md`), so `shared-b2-repo` decrypts.
- [ ] Independent copies of the restic password `<RESTIC_PASSWORD>` and the B2 credentials `<B2_KEY_ID>`/`<B2_APP_KEY>` in the password manager (`docs/sealed-secrets-backup.md` §2–3).
- [ ] The repository URL from the generation comment in `infrastructure/volsync/sealed-shared-b2-repo.yaml`.
- [ ] A maintenance window. The app is down during its restore.

## Part A: VolSync restore (Direct), per app

The worked example is **adguard**, whose manifests exist in `restore/`. For other apps, substitute from the table.

### A0. (First time) rehearse into a scratch PVC
Apply a copy of the ReplicationDestination (A5), named `restore-test` with `destinationPVC: restore-test`, against an empty `restore-test` PVC in the same namespace. Mount it read-only in a throwaway pod named `restore-test-inspect` and look at the files.
**Verify:** the files belong to the right app. This tests finding 2.

**Clean up immediately.** The scratch copy is a full copy of the app's data. `longhorn-usb` has `reclaimPolicy: Retain`, so the data outlives the PVC:
```bash
kubectl -n adguard delete pod restore-test-inspect
kubectl -n adguard delete replicationdestination restore-test
PV=$(kubectl -n adguard get pvc restore-test -o jsonpath='{.spec.volumeName}')
kubectl -n adguard delete pvc restore-test
kubectl delete pv "$PV"                                    # Released, Retain: not deleted automatically
kubectl -n longhorn-system delete volumes.longhorn.io "$PV"  # the Longhorn volume backing it
```
**Verify:**
- `kubectl -n adguard get pod,pvc,replicationdestination | grep restore-test` prints nothing.
- `kubectl get pv "$PV"` and `kubectl -n longhorn-system get volumes.longhorn.io "$PV"` both return NotFound.

(UNVERIFIED: that the Longhorn volume name equals the PV name. Check `kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}'` first and use that value.)

### A1. Confirm a backup exists
```bash
kubectl -n adguard get replicationsource adguard-config-backup -o jsonpath='{.status.lastSyncTime}{"\n"}{.status.latestMoverStatus.result}{"\n"}'
kubectl -n adguard get secret shared-b2-repo
```
**Verify:** a recent `lastSyncTime`, a `Successful` result, and the Secret exists.

### A2. Stop GitOps from undoing your changes
The root app and `adguard` both have `selfHeal: true` (`bootstrap/root-app.yaml`, `bootstrap/apps/adguard.yaml`). Scaling down by hand would be reverted. Turn off auto-sync on root first, then on the app:
```bash
kubectl -n argocd patch application root    --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application adguard --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```
**Verify:** `kubectl -n argocd get application adguard -o jsonpath='{.spec.syncPolicy}'` shows no `automated` key. (UNVERIFIED on this cluster. `jellyfin` already has `selfHeal: false`.)

### A3. Safety snapshot, then stop the app
```bash
kubectl -n adguard scale deployment adguard-home --replicas=0
```
The old volume survives a PVC delete because `longhorn-usb` has `reclaimPolicy: Retain` (`infrastructure/longhorn/storage-class.yaml`). For an extra net, take a VolumeSnapshot with class `longhorn` (`infrastructure/longhorn/volume-snapshot-class.yaml`) first.
**Verify:** `kubectl -n adguard get pods` shows no adguard pods.

### A4. Replace the PVC with an empty one
```bash
kubectl -n adguard delete pvc adguard-config
kubectl apply -f restore/adguard-pvc-final.yaml
```
**Verify:** `kubectl -n adguard get pvc adguard-config` is Bound to a **new** PV. Note the old PV name, which is now Released, for rollback.

### A5. Restore
```bash
kubectl apply -f restore/adguard-restore.yaml
kubectl -n adguard get replicationdestination adguard-config-restore -w
```
For other apps, copy the file and change `name`, `namespace`, `destinationPVC` and `capacity` to the table values. Add `restoreAsOf: "<RFC3339_TIME>"` under `restic:` to pick an older snapshot (VolSync docs).
**Verify:** `.status.lastSyncTime` is set and `.status.latestMoverStatus.result` is `Successful`.

### A6. Clean up and start the app
```bash
kubectl delete -f restore/adguard-restore.yaml
kubectl -n adguard scale deployment adguard-home --replicas=1
```
**Verify:** the pod is Running and the app shows its old config. For AdGuard: `dig @192.168.7.202 hermnet.org` resolves and the rewrites are present.

### A7. Re-enable GitOps
Re-apply `bootstrap/root-app.yaml` (`make bootstrap-root`). Root then re-syncs the child Application, including its `automated` policy.
**Verify:** `kubectl -n argocd get applications` shows root and adguard Synced/Healthy with auto-sync on.

## Part B: Authentik database (pg_dump route)

Authentik runs a plain `postgres:16.6-alpine` StatefulSet, `authentik-postgresql`, with PVC `data-authentik-postgresql-0`. It is **not** CNPG (`infrastructure/authentik/postgresql/statefulset.yaml`). Backups are `pg_dump -Fc` files on `authentik-postgresql-dumps`.

TBD (plan v3 O6): whether a rebuilt or new cluster restores this DB at all, or starts fresh. Get Rock's decision first.

1. Run Part A for PVC `authentik-postgresql-dumps` (namespace authentik, class `longhorn`, 8Gi). Pause the `authentik` app first.
   **Verify:** the restore succeeded.
2. Scale `authentik-server` and `authentik-worker` to 0.
   **Verify:** no server or worker pods.
3. Run a one-off pod named `authentik-pg-restore`. It mounts `authentik-postgresql-dumps` and uses the CronJob's image and env (`infrastructure/authentik/backup/cronjob-pg-dump.yaml`). That env includes the **database password** from Secret `authentik-postgresql-credentials`.
   - Give it `restartPolicy: Never`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`, and no service-account token (`automountServiceAccountToken: false`).
   - Mount the dumps PVC `readOnly: true`.

   In the pod, run:
   ```bash
   pg_restore --clean --if-exists -d authentik /dumps/authentik-<STAMP>.dump
   ```
   **Verify:** it exits 0, and `psql -c '\dt'` lists the Authentik tables.
4. Delete the pod as soon as the restore is verified. It holds DB credentials:
   ```bash
   kubectl -n authentik delete pod authentik-pg-restore
   ```
   **Verify:** `kubectl -n authentik get pod authentik-pg-restore` returns NotFound.
5. Scale server and worker back to 1, then re-enable sync (A7).
   **Verify:** an Authentik login works, and a protected app such as `hubble.hermnet.org` redirects through Authentik (`docs/runbook-restore.md` Phase 5).

## Part C: CNPG recovery from barman (Paperless)

TBD: not runnable at 37b7a7c.
- `apps/paperless/base/kustomization.yaml` has every resource commented out.
- It names `postgres/cluster.yaml` (no WAL archiving), not `postgres/cluster-cnpg.yaml` (barman plugin).
- Rock decides which Cluster file is authoritative before this part is written.

Outline for later (CNPG and barman-cloud plugin docs):
1. Create a new `Cluster` with `bootstrap.recovery.source` pointing at an `externalClusters` entry. That entry uses plugin `barman-cloud.cloudnative-pg.io` with `barmanObjectName: paperless-postgres-store` (`apps/paperless/base/postgres/object-store.yaml`).
2. Credentials come from `cnpg-barman-b2-credentials` (`infrastructure/cloudnative-pg/sealed-barman-b2-credentials-secret.yaml`).
3. **Verify:** the Cluster is in healthy state, then a first ScheduledBackup run.

TBD (plan v3 O8): recover from the **old** path, then archive to a **new** prefix or bucket. The new path is not chosen.

## Part D: data with no in-cluster backup

media (about 500Gi), metube downloads and paperless NFS have no VolSync. Copy them back from `<EXTERNAL_BACKUP_LOCATION>` into the new PVCs (`docs/runbook-restore.md` Phase 3 step 5).

TBD: there is no backup target in git for these (`docs/to-do.md` item 2). Rock picks one.

## Rollback

**Every rollback path, including an abort at any point after A2, ends with A7.** Otherwise Argo auto-sync stays off for root and the app, and drift correction stays off cluster-wide.

- **Before A5:** the old data is still on the Released PV, thanks to `Retain`. To rebind it:
  1. Delete the new PVC.
  2. `kubectl patch pv <OLD_PV> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`.
  3. Recreate the PVC with `volumeName: <OLD_PV>`.
  4. Scale the app back up, then run **A7**.
- **After a bad restore:** repeat A5 with an older `restoreAsOf`, or restore the VolumeSnapshot from A3. Then run **A7**.
- **Authentik:** keep the pre-restore `data-authentik-postgresql-0` (take a Longhorn snapshot before Part B step 3). If you abort, delete any `authentik-pg-restore` pod (Part B step 4), scale server and worker back to 1, then run **A7**.
- **Aborted rehearsal (A0):** run the A0 cleanup block.

**Verify (all paths):** `kubectl -n argocd get application root <APP> -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.syncPolicy.automated}{"\n"}{end}'` shows an `automated` policy for both, and no restore pods or scratch PVCs remain.

## References

- `docs/runbook-restore.md` (Phase 3, 5)
- `docs/sealed-secrets-backup.md`, `docs/to-do.md`
- `restore/adguard-restore.yaml`, `restore/adguard-pvc-final.yaml`
- `infrastructure/volsync/sealed-shared-b2-repo.yaml`
- `infrastructure/adguard/{replication-source,pvc,deployment}.yaml`
- `apps/jellyfin/base/{replication-source,pvc-config}.yaml`
- `apps/home-assistant/{replication-source,pvc}.yaml`
- `infrastructure/authentik/{backup,postgresql}/*`
- `apps/paperless/base/postgres/*`
- `infrastructure/longhorn/storage-class.yaml`, `volume-snapshot-class.yaml`
- `bootstrap/root-app.yaml`, `bootstrap/apps/*.yaml`
- VolSync docs (restic, ReplicationDestination); CloudNativePG and barman-cloud plugin docs
- Project notes: `project-flux/plan-v3.md` §1, §7

## Staleness note (Flux PRs)

HIGH. This runbook changes the most:
- **A2/A7:** pausing becomes `flux suspend kustomization <NAME>` / `flux resume kustomization <NAME>`. TBD: the app-tier Kustomization names. The app tier is not in the `flux/` tree yet (draft #9 is infrastructure only).
- **Repository:** plan v3 uses a **new** restic repo path and password for new backups. The old ones are read-only for restores through a temporary Secret that Rock creates. VolSync's Secret comes via `flux/overlays/volsync` (draft #9). TBD: Secret names and paths (O8).
- **AdGuard:** if #5/#6 merge, AdGuard and `restore/adguard-*` go away and the worked example has to change. TBD: a new example (Jellyfin is the likely candidate).
- **CNPG:** the operator and plugin move to Flux HelmReleases (`flux/releases/cloudnative-pg-*`, draft #9). Part C stays TBD.
