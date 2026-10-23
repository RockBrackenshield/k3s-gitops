# Talos (hermnet)

Talos Linux v1.14 config for the 3-node Raspberry Pi cluster that replaced k3s.
Everything here is plain YAML patches plus a Makefile; versions live in
[`versions.env`](versions.env).

| Node | IP | Board | Role |
|------|----|-------|------|
| k3s-master | 192.168.7.15 | Pi 5 (`patches/rpi5.yaml`) | control plane + workloads, USB disk for Longhorn |
| k3s-worker-1 | 192.168.7.11 | Pi 4 (`patches/rpi4.yaml`) | worker |
| k3s-worker-2 | 192.168.7.13 | Pi 4 (`patches/rpi4.yaml`) | worker |

## Layout

- `schematics/` - Image Factory schematics (overlay + iscsi-tools, tailscale,
  util-linux-tools). The file's sha256 **is** the schematic ID; don't reformat them.
- `patches/common.yaml` - all nodes (pod/service CIDRs 10.42/10.43).
- `patches/controlplane.yaml` - untaint control plane, no Flannel, no kube-proxy.
- `patches/rpi{4,5}.yaml` - installer image (tag@digest) + SD-card install disk.
- `nodes/<host>.yaml` - hostname, static IP on `end0`; k3s-master also has the
  Longhorn label and the `UserVolumeConfig longhorn` (USB disk, by serial).
- `tailscale.example.yaml` - template for `nodes/<host>.tailscale.sops.yaml`.
- `secrets.sops.yaml`, `nodes/*.tailscale.sops.yaml` - **you create these**,
  encrypted with SOPS/age. They are not in the repo yet.

## Before the first `make gen`

1. age key: `age-keygen -o ~/.config/sops/age/keys.txt`; put the public key in
   `/.sops.yaml` (replace `age1REPLACE_ME_WITH_YOUR_AGE_PUBLIC_KEY`). Back up the
   private key off-cluster.
2. Cluster secrets (from `talos/`; `secrets.yaml` is gitignored):
   `talosctl gen secrets -o secrets.yaml && sops -e --filename-override secrets.sops.yaml secrets.yaml > secrets.sops.yaml && shred -u secrets.yaml`
3. Per node: `sops edit nodes/<host>.tailscale.sops.yaml`, paste
   `tailscale.example.yaml`, fill in a tagged, pre-approved, single-use key and
   `TS_HOSTNAME=talos-<host>`.
4. USB disk serial: replace `REPLACE_WITH_USB_SERIAL` in `nodes/k3s-master.yaml`
   with the serial from `lsblk -o NAME,SERIAL` (cross-check with
   `talosctl get disks`). `make apply` / `make upgrade` **refuse** to run until
   this is done.
5. `pre-commit install` - the guard (`scripts/check-sops.sh`) blocks plaintext
   `*.sops.yaml`, `talosconfig`, `kubeconfig`, `secrets.yaml` and `_out/`.

## Day 0

```bash
make -C talos schematic-check images   # flash the printed metal-arm64.raw.xz to each SD card
make -C talos gen validate             # renders _out/ (plaintext secrets, gitignored)
make -C talos apply NODE=k3s-master INSECURE=1     # node is in maintenance mode
make -C talos apply NODE=k3s-worker-1 INSECURE=1
make -C talos apply NODE=k3s-worker-2 INSECURE=1
make -C talos bootstrap kubeconfig
make -C talos cilium-bootstrap         # nodes go Ready; Argo adopts the release later
make bootstrap-argocd restore-sealed-secrets-key bootstrap-root   # repo root Makefile
```

Then `make -C talos etcd-backup` regularly. Upgrades:
`make -C talos upgrade NODE=<host>` after bumping `TALOS_VERSION` and the
installer digests in `versions.env`.

## Checks

- `make -C talos render-test` renders and validates all three nodes with
  throwaway secrets and a dummy serial (what CI runs; nothing is kept).
- `scripts/tests/talos-makefile_test.sh` proves the apply/upgrade refusal and
  the Cilium chart digest check.
- `scripts/check-versions.sh` keeps versions.env, the installer refs and the
  Argo Cilium app in sync.
