<!-- k3s-gitops/docs/runbook-restore.md -->
# Cluster Restore Runbook (Talos)

Full rebuild of the hermnet cluster: three Raspberry Pis running Talos Linux,
Cilium as CNI + LoadBalancer, Argo CD for everything else. Follow the phases
in order. Node-level commands live in `talos/Makefile`
(see [`talos/README.md`](../talos/README.md)); cluster bootstrap lives in the
root `Makefile`.

| Node | IP | Board | Role |
|------|----|-------|------|
| k3s-master | 192.168.7.15 | Pi 5 | control plane + workloads, USB disk (Longhorn) |
| k3s-worker-1 | 192.168.7.11 | Pi 4 | worker |
| k3s-worker-2 | 192.168.7.13 | Pi 4 | worker |

---

## Prerequisites

- [ ] This repository cloned locally
- [ ] Tools: `talosctl` and `helm` at the versions in `talos/versions.env`,
      `sops`, `age`, `kubectl`, `kubeseal`
- [ ] The age private key for SOPS (`~/.config/sops/age/keys.txt`), so
      `talos/secrets.sops.yaml` and `talos/nodes/*.tailscale.sops.yaml` decrypt
- [ ] The backed-up `sealed-secrets-master-key.yaml`, **outside the repo**
      (see `sealed-secrets-backup.md`). Without it every SealedSecret must be resealed.
- [ ] Backblaze B2 credentials and restic passwords (VolSync, CNPG/barman)
- [ ] A recent etcd snapshot if you are recovering the existing cluster state
      (`make -C talos etcd-backup` output)

---

## Phase 0 — Data on the USB disk

The Talos `UserVolumeConfig longhorn` only locates a Talos-created partition
or provisions a new one; it cannot adopt an existing filesystem.

- **Migrating from k3s:** image (`dd`/`ddrescue`) or copy the old disk off and
  verify the copy **before** reflashing. Longhorn re-adopting old replicas is
  unverified; plan to restore from backups.
- **Rebuilding Talos with the same disk:** the existing `u-longhorn` partition
  is found again by serial; nothing is wiped.

---

## Phase 1 — Flash and configure the nodes

```bash
make -C talos schematic-check images   # flash the printed metal-arm64.raw.xz images
```

Boot each Pi from its SD card (USB disk unplugged on a first install). The
nodes come up in maintenance mode. Check on a trusted LAN:

```bash
talosctl get disks --insecure -n 192.168.7.15   # mmcblk0 = SD card; note the USB serial
talosctl get links --insecure -n 192.168.7.15   # NIC is end0
```

The USB serial goes into `talos/nodes/k3s-master.yaml` (replace
`REPLACE_WITH_USB_SERIAL`; `lsblk -o NAME,SERIAL` on another machine shows the
same value). `make apply` and `make upgrade` refuse to run while the
placeholder is present.

Then either step by step (see `talos/README.md` "Day 0"), or in one go:

```bash
make restore KEY=/path/outside/repo/sealed-secrets-master-key.yaml
# = talos-up (gen, validate, apply all nodes, bootstrap, kubeconfig, cilium-bootstrap)
#   + bootstrap-argocd + restore-sealed-secrets-key + bootstrap-root
export KUBECONFIG=$PWD/talos/_out/kubeconfig
kubectl get nodes        # all three Ready once Cilium runs
```

To recover the control plane from an etcd snapshot instead of a fresh
cluster: reflash, apply, then
`talosctl -n 192.168.7.15 bootstrap --recover-from=./etcd-<date>.snapshot`,
then `make -C talos cilium-bootstrap` if Cilium is not in that state.

With a **new** Sealed Secrets key use `make day0` instead, then reseal every
SealedSecret and back the new key up.

---

## Phase 2 — Argo CD sync

```bash
kubectl -n argocd get applications -w
```

| Wave | Applications |
|------|--------------|
| -4 | gateway-api-crds |
| -3 | cilium (adopts the release from `cilium-bootstrap`; LB pool + L2 policies) |
| -2 | sealed-secrets |
| -1 | traefik, cert-manager, reflector, longhorn, snapshot-controller |
| 0  | infrastructure, volsync, adguard, authentik, argocd-ingress, external-snapshotter-crds |
| 1+ | renovate, jellyfin, csi-driver-smb, metube, paperless-nfs-ganesha, paperless, ... |

Argo CD UI before TLS is ready:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### LoadBalancer IPs (Cilium LB IPAM + L2 announcements)

Pool `infrastructure-pool` is 192.168.7.200-220; every Service pins its IP
with `lbipam.cilium.io/ips`.

| Service | IP | Announced by |
|---------|----|--------------|
| adguard/adguard-dns | 192.168.7.202 | k3s-master only (`externalTrafficPolicy: Local`) |
| traefik/traefik | 192.168.7.205 | k3s-master only (`externalTrafficPolicy: Local`) |
| nfs-ganesha-lan | 192.168.7.203 | any node |
| samba | 192.168.7.206 | any node |
| paperless-nfs-ganesha | 192.168.7.207 | any node |

```bash
kubectl get svc -A | grep LoadBalancer
kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy
kubectl -n kube-system get leases | grep cilium-l2announce   # holder per Service
```

### Certificates

```bash
kubectl -n cert-manager get certificate -w   # wildcard-hermnet-org READY=True
kubectl -n kube-system get secret wildcard-hermnet-org-tls   # Reflector copy used by the default TLSStore
```

---

## Phase 3 — Storage and data

1. Plug in / confirm the USB disk, then
   `talosctl -n 192.168.7.15 get volumestatus u-longhorn` and
   `talosctl -n 192.168.7.15 get mountstatus` (mounted at `/var/mnt/longhorn`).
   If the disk still holds the old k3s filesystem, wipe it only after Phase 0:
   `talosctl -n 192.168.7.15 wipe disk <dev>` (check `--help` first).
2. Longhorn: the k3s-master Longhorn node must show exactly one schedulable
   disk at `/var/mnt/longhorn`
   (`kubectl -n longhorn-system get nodes.longhorn.io k3s-master -o yaml`).
   Replicas are 1 (single disk, no redundancy).
3. VolSync (adguard, authentik, jellyfin, home-assistant): restore from B2.
   Example for AdGuard:

   ```bash
   kubectl -n adguard scale deployment adguard-home --replicas=0
   kubectl -n adguard delete pvc adguard-config
   kubectl apply -f restore/adguard-restore.yaml
   kubectl -n adguard get replicationdestination adguard-config-restore -w
   RESTORED_PVC=$(kubectl -n adguard get replicationdestination adguard-config-restore \
     -o jsonpath='{.status.latestImage.name}')
   # set volumeName: $RESTORED_PVC in restore/adguard-pvc-final.yaml, then:
   kubectl apply -f restore/adguard-pvc-final.yaml
   kubectl -n adguard scale deployment adguard-home --replicas=1
   kubectl delete -f restore/adguard-restore.yaml
   ```

4. CNPG databases restore from barman (B2) through Argo.
5. media, metube and paperless-nfs have no VolSync: copy the data from the
   Phase 0 backup into the new PVCs.

---

## Phase 4 — Router DNS

Primary DNS `192.168.7.202` (AdGuard), secondary `1.1.1.1`.

---

## Phase 5 — Verification

- [ ] `talosctl -n 192.168.7.15 health` passes; `kubectl get nodes` shows 3 Ready
- [ ] `talosctl -n <ip> service ext-tailscale` is Running on every node
- [ ] All Argo CD Applications are Synced/Healthy; the cilium DaemonSet was not recreated by the adoption
- [ ] gateway-api-crds is Synced and the CRDs are Established
- [ ] ARP for .202 and .205 is answered only by k3s-master; the other LB IPs answer
- [ ] Real client IPs appear in the AdGuard and Traefik logs
- [ ] Traefik pods are admitted under PSA restricted in the `traefik` namespace
- [ ] The wildcard certificate is served (default TLSStore) at https://argocd.hermnet.org
- [ ] https://hubble.hermnet.org is reachable only through authentik
- [ ] Longhorn UI shows the USB disk; volumes are Healthy
- [ ] `dig @192.168.7.202 hermnet.org` resolves
- [ ] `kubectl get replicationsource -A` shows VolSync running
- [ ] Take an etcd snapshot: `make -C talos etcd-backup`
- [ ] New Sealed Secrets key (day0 only): export and back it up (`sealed-secrets-backup.md`)

---

## Troubleshooting

### Nodes NotReady after bootstrap

No CNI yet: run `make -C talos cilium-bootstrap`. It verifies the chart sha256
from `versions.env` before installing.

### LoadBalancer IP pending or not reachable

```bash
kubectl -n kube-system logs ds/cilium | grep -i -e l2 -e lbipam
kubectl describe ciliumloadbalancerippool infrastructure-pool
```

Services with `externalTrafficPolicy: Local` only answer from a node that runs
their pod; their L2 policy `pinned-k3s-master` must select k3s-master, and the
pods are pinned there with a nodeSelector.

### Longhorn disk missing

```bash
talosctl -n 192.168.7.15 get volumestatus u-longhorn
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=100
```

Check the disk serial in `talos/nodes/k3s-master.yaml`. `node-disk-config.yaml`
reconciles onto the Node CR that Longhorn creates, so it may need a manual
Argo CD sync after Longhorn first starts.

### cert-manager DNS01 failing

```bash
kubectl -n cert-manager describe certificaterequest
kubectl -n cert-manager logs deploy/cert-manager -f
kubectl -n cert-manager get secret cloudflare-api-token
```
