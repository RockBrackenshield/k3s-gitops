# Runbooks

These are practical procedures for the hermnet cluster: three Raspberry Pis on Talos v1.14.4, Kubernetes 1.36.5, Cilium 1.20.4, Longhorn, and Argo CD today. All are based on `main` at `37b7a7c`, and every repo file they cite is cited at that commit.

They are drafts. Rock reviews and merges them, Malis security-checks them, and Seneschal teaches from them.

| Runbook | Use it when | Flux stale risk |
|---|---|---|
| [etcd-backup-restore.md](etcd-backup-restore.md) | Weekly, before any upgrade, or when the control plane loses etcd | Low |
| [talos-k8s-upgrade.md](talos-k8s-upgrade.md) | Bumping Talos or Kubernetes in `talos/versions.env` | Low |
| [sops-age-keys.md](sops-age-keys.md) | New workstation, editing `talos/**/*.sops.yaml`, adding or rotating recipients, key backup (Talos part; Flux part TBD) | Medium |
| [longhorn-add-disk.md](longhorn-add-disk.md) | Adding a worker disk, raising replicas, replacing the k3s-master disk | Medium |
| [app-data-restore.md](app-data-restore.md) | Restoring an app's PVC from VolSync, or the Authentik DB; CNPG part TBD | High |

The full-cluster rebuild stays in [`../runbook-restore.md`](../runbook-restore.md), and these runbooks reference it. The Sealed Secrets key is covered in [`../sealed-secrets-backup.md`](../sealed-secrets-backup.md).

## Suggested learning order

1. sops-age-keys. Without the key you can't render node configs.
2. etcd-backup-restore.
3. talos-k8s-upgrade.
4. app-data-restore.
5. longhorn-add-disk.

## Conventions

- **Values:** real values appear only where they are already in the public repo at 37b7a7c:
  - node names;
  - node IPs 192.168.7.11/.13/.15 and LoadBalancer IPs .202 (DNS) and .205 (Traefik);
  - the `hermnet.org` and `hubble.hermnet.org` hostnames;
  - the k3s-master disk-selector fragment;
  - versions and namespaces.

  Everything else is an `<UPPER_SNAKE>` placeholder: keys, tokens, passwords, bucket credentials, serials, other addresses.
- **Verify checks:** every step ends with one. Don't go to the next step until it passes.
- **Markers:** `TBD:` means a decision or the Flux work is still open. `UNVERIFIED` means not tested on this cluster.
- **Secrets:** never paste decrypted secrets, snapshots or keys into a terminal log, a chat or the repo. Work under `umask 077`.
- **`talos/_out/`:** this holds plaintext machine configs (with the cluster CA keys), `talosconfig`, `kubeconfig` and etcd snapshots. It is gitignored, but not cleaned up for you. When a session is done, remove what you no longer need:
  ```bash
  shred -u talos/_out/*.yaml talos/_out/*.snapshot 2>/dev/null
  rm -rf talos/_out
  ```
  Re-render later with `make -C talos gen`. Keep the checkout on an encrypted disk.

## When the Flux PRs land

PRs #12, #9, #10 and #11 move reconciliation from Argo CD to Flux on a new cluster (plan v3). Every runbook ends with a staleness note that lists exactly what changes. Re-review all five after go-live (#10).
