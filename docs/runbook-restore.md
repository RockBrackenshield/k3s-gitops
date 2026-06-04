<!-- k3s-gitops/docs/runbook-restore.md -->
# Cluster Restore Runbook

This runbook covers full disaster recovery for the hermnet.org K3s homelab cluster.
Follow sections in order. Do not skip steps.

---

## Prerequisites

Before starting, confirm you have access to:

- [ ] SSH private key (`~/.ssh/id_ed25519`) for the `ubuntu` user on all nodes
- [ ] The backed-up `sealed-secrets-master-key.yaml` (from your offline storage — see `sealed-secrets-backup.md`)
- [ ] Backblaze B2 credentials (Key ID and Application Key) for `hermnet-restic-private`
- [ ] Restic repository passwords for each component (adguard, jellyfin, etcd)
- [ ] Cloudflare API token for cert-manager DNS01 challenge
- [ ] Physical access to the USB drive (UUID `PLACEHOLDER-UUID`) for Longhorn storage
- [ ] This repository cloned locally: `git clone https://github.com/RockBrackenshield/k3s-gitops`

---

## Phase 1 — Node Preparation

### 1.1 Provision fresh Ubuntu 26.04 nodes

Install Ubuntu 26.04 LTS on all three nodes. Ensure:
- SSH is enabled with your public key in `~/.ssh/authorized_keys` for the `ubuntu` user
- Nodes are reachable at their expected IPs:
  - `k3s-master`: 192.168.7.15
  - `k3s-worker-1`: 192.168.7.11
  - `k3s-worker-2`: 192.168.7.13
- The USB drive is physically attached to `k3s-master` and formatted as ext4

### 1.2 Find the USB drive UUID

SSH into `k3s-master` and run:

```bash
blkid /dev/sdX   # replace sdX with your drive
```

Copy the UUID value. Update the placeholder in:
- `ansible/roles/usb_storage/tasks/main.yaml` (the `fstab` lineinfile line)

### 1.3 Place the Sealed Secrets master key

Copy your backed-up key file into the Ansible role files directory:

```bash
cp /path/to/your/backup/sealed-secrets-master-key.yaml \
  ansible/roles/argocd_bootstrap/files/sealed-secrets-master-key.yaml
```

This file is gitignored and will be deleted from the remote host immediately after use.

---

## Phase 2 — Run the Ansible Restore Playbook

From the repository root on your local machine:

```bash
cd k3s-gitops/ansible
ansible-playbook -i inventory/hosts.yaml restore.yaml
```

This playbook will:
1. Install common packages, disable systemd-resolved, configure resolv.conf
2. Install K3s on `k3s-master` with `--disable servicelb`
3. Install K3s agents on `k3s-worker-1` and `k3s-worker-2`
4. Mount the USB drive via fstab on `k3s-master`
5. Install ArgoCD from the stable upstream manifest
6. Patch ArgoCD server into insecure mode (Traefik terminates TLS)
7. Apply the Sealed Secrets master key to the cluster
8. Apply the root ArgoCD Application

After the playbook completes, a `kubeconfig.yaml` will be written to the repository root.

Set it as your active kubeconfig:

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
kubectl get nodes
```

All three nodes should eventually reach `Ready` status.

---

## Phase 3 — Monitor ArgoCD Infrastructure Sync

### 3.1 Access the ArgoCD UI (temporary, before TLS is ready)

Until the wildcard cert is issued, use port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080` in a browser. Retrieve the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

Login with username `admin` and the printed password.

### 3.2 Watch sync wave progression

ArgoCD will process applications in sync-wave order. Monitor progress:

```bash
kubectl get applications -n argocd -w
```

Expected sync order and timing:

| Wave | Application     | Approximate time |
|------|-----------------|------------------|
| -2   | metallb         | 2–5 minutes      |
| -2   | sealed-secrets  | 1–2 minutes      |
| -1   | traefik         | 1–2 minutes      |
| -1   | cert-manager    | 2–3 minutes      |
| -1   | reflector       | 1 minute         |
| -1   | longhorn        | 5–10 minutes     |
| 0    | volsync         | 2 minutes        |
| 0    | adguard         | 2 minutes        |
| 0    | etcd-backup     | 1 minute         |
| 1    | jellyfin        | 2 minutes        |

### 3.3 Verify MetalLB IP assignments

After metallb syncs, verify the two reserved IPs are assigned:

```bash
kubectl get svc -A | grep LoadBalancer
# Expected:
# adguard   adguard-dns   LoadBalancer   ...   10.10.10.10   53:...
# kube-system traefik     LoadBalancer   ...   10.10.10.20   80:...,443:...
```

### 3.4 Monitor the wildcard certificate

The cert-manager ClusterIssuer will issue the wildcard cert via Cloudflare DNS01.
This typically takes 1–3 minutes but can take up to 10 minutes depending on DNS propagation.

```bash
kubectl get certificate -n cert-manager -w
# Wait for READY=True on wildcard-hermnet-org
```

Once `READY=True`, Reflector will automatically copy the TLS secret to all configured namespaces. Verify:

```bash
kubectl get secret wildcard-hermnet-org-tls -n adguard
kubectl get secret wildcard-hermnet-org-tls -n longhorn-system
kubectl get secret wildcard-hermnet-org-tls -n argocd
```

### 3.5 Apply the ArgoCD IngressRoute

Once the wildcard cert is reflected to the `argocd` namespace, apply the ArgoCD ingress:

```bash
kubectl apply -f bootstrap/argocd-ingress.yaml
```

ArgoCD will now be accessible at `https://argocd.hermnet.org`.

---

## Phase 4 — Update Router DNS

Point your router's DNS server to the AdGuard Home instance:

- **Primary DNS:** `10.10.10.10` (AdGuard's dedicated LoadBalancer IP)
- **Secondary DNS:** `1.1.1.1` (fallback if AdGuard is unreachable)

Log into the AdGuard UI at `https://adguard.hermnet.org` and verify your DNS rewrites and block lists are loaded from the restored config. If AdGuard's config is missing, proceed to Phase 5.

---

## Phase 5 — Restore Application Data from VolSync

If application PVCs are empty (new cluster, no data migration), restore from Backblaze B2 backups.

### 5.1 Re-seal secrets before restoring

The B2 repo secrets must be re-sealed with the current Sealed Secrets controller key. For each component:

```bash
# Example for adguard — repeat for jellyfin, etcd
kubectl create secret generic adguard-b2-repo \
  --namespace adguard \
  --from-literal=RESTIC_REPOSITORY=s3:https://s3.us-east-005.backblazeb2.com/hermnet-restic-private/adguard \
  --from-literal=RESTIC_PASSWORD=YOUR_RESTIC_REPOSITORY_PASSWORD \
  --from-literal=AWS_ACCESS_KEY_ID=YOUR_B2_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=YOUR_B2_APPLICATION_KEY \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
> infrastructure/adguard/sealed-adguard-b2-repo.yaml

# Commit and push, then wait for ArgoCD to sync the new sealed secret
git add infrastructure/adguard/sealed-adguard-b2-repo.yaml
git commit -m "chore: re-seal adguard b2 repo secret after cluster rebuild"
git push
```

### 5.2 Restore AdGuard config PVC

```bash
# Scale down AdGuard
kubectl scale deployment adguard-home -n adguard --replicas=0

# Delete the empty PVC
kubectl delete pvc adguard-config -n adguard

# Apply the VolSync restore manifest
kubectl apply -f restore/adguard-restore.yaml

# Watch for completion
kubectl get replicationdestination adguard-config-restore -n adguard -w
# Wait for STATUS.LAST_SYNC_TIME to populate

# Get the name of the restored PVC
RESTORED_PVC=$(kubectl get replicationdestination adguard-config-restore \
  -n adguard -o jsonpath='{.status.latestImage.name}')
echo "Restored PVC: $RESTORED_PVC"

# Edit restore/adguard-pvc-final.yaml and set volumeName: $RESTORED_PVC
# then apply:
kubectl apply -f restore/adguard-pvc-final.yaml

# Scale AdGuard back up
kubectl scale deployment adguard-home -n adguard --replicas=1

# Clean up the ReplicationDestination
kubectl delete -f restore/adguard-restore.yaml
```

### 5.3 Restore Jellyfin config PVC

Follow the same procedure as AdGuard, substituting `jellyfin` for `adguard` and using the Jellyfin-specific secret name `jellyfin-b2-repo`.

---

## Phase 6 — Post-Restore Verification

Run through this checklist to confirm the cluster is fully operational:

- [ ] All ArgoCD Applications show `Synced` and `Healthy`
- [ ] `kubectl get nodes` shows all three nodes as `Ready`
- [ ] MetalLB has assigned 10.10.10.10 to AdGuard and 10.10.10.20 to Traefik
- [ ] Wildcard certificate is `READY=True` in the `cert-manager` namespace
- [ ] TLS secret is reflected to `adguard`, `longhorn-system`, `argocd`, `volsync-system`, `etcd-backup`
- [ ] `https://argocd.hermnet.org` loads with a valid TLS cert
- [ ] `https://adguard.hermnet.org` loads AdGuard Home UI
- [ ] `https://longhorn.hermnet.org` loads the Longhorn UI showing the USB disk
- [ ] `https://jellyfin.hermnet.org` loads Jellyfin
- [ ] DNS queries to 10.10.10.10 resolve correctly (test: `dig @10.10.10.10 hermnet.org`)
- [ ] VolSync ReplicationSources are running (`kubectl get replicationsource -A`)
- [ ] etcd-backup CronJob is present (`kubectl get cronjob -n etcd-backup`)
- [ ] Back up the NEW Sealed Secrets master key to offline storage (see `sealed-secrets-backup.md`)

---

## Troubleshooting

### cert-manager DNS01 challenge failing

Check the ACME challenge status:
```bash
kubectl describe certificaterequest -n cert-manager
kubectl logs -n cert-manager deploy/cert-manager -f
```

Verify the `cloudflare-api-token` secret was properly decrypted:
```bash
kubectl get secret cloudflare-api-token -n cert-manager
```

### MetalLB not assigning IPs

Ensure MetalLB is fully running before the IPAddressPool is applied. If the IPAddressPool was created before MetalLB CRDs existed, delete and re-sync it:
```bash
kubectl delete ipaddresspool infrastructure-pool -n metallb-system
# Force an ArgoCD sync on the metallb application
```

### Longhorn node disk not appearing

SSH into `k3s-master` and verify the USB is mounted:
```bash
mountpoint /mnt/longhorn-usb && df -h /mnt/longhorn-usb
```

Check Longhorn manager logs:
```bash
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100
```

The `node-disk-config.yaml` Node resource may need a manual sync trigger in ArgoCD since the Longhorn Node resource is auto-created by Longhorn and ArgoCD is reconciling onto it.

### ArgoCD UI not loading after ingress is applied

Check that Traefik received its LoadBalancer IP:
```bash
kubectl get svc traefik -n kube-system
```

If `EXTERNAL-IP` is `<pending>`, MetalLB is not assigning IPs. Check the MetalLB controller logs:
```bash
kubectl logs -n metallb-system -l app=metallb,component=controller
```
