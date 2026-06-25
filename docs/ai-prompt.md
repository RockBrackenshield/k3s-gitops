<!-- k3s-gitops/docs/ai-prompt.md -->
# AI Prompt — k3s-gitops Repository Generator

This file is a verbatim copy of the prompt used to generate this repository.
Paste it into a new Claude conversation to regenerate or extend the repo.

---

You are generating a complete GitOps repository for a K3s homelab cluster. Generate every file completely — no placeholders, no omitted sections, no comments saying "add your values here". Every file must be immediately usable.

## Cluster Overview

- **Distribution:** Stock K3s: built-in Traefik, CoreDNS, and flannel.
- **Domain:** domain.org (actual: hermnet.org)
- **Internal subnet:** 192.168.7.0/24
- **MetalLB pool:** 192.168.7.200-192.168.7.220
- **Reserved IPs:**
  - 192.168.7.202 — AdGuard Home (dedicated LoadBalancer, router DNS target)
  - 192.168.7.205 — Traefik (all HTTP/HTTPS ingress)
- **K3s control plane node:** k3s-master at 192.168.7.15
- **K3s worker nodes:** k3s-worker-1 at 192.168.7.11, k3s-worker-2 at 192.168.7.13
- **USB storage node:** k3s-master
- **USB mount path:** /mnt/longhorn-usb
- **USB device UUID:** PLACEHOLDER-UUID (leave as a clearly named placeholder — this is hardware specific)
- **Backblaze B2 endpoint:** s3://s3.us-east-005.backblazeb2.com
- **Backblaze B2 bucket:** hermnet-restic-private
- **Cloudflare zone:** hermnet.org
- **Let's Encrypt email:** admin@hermnet.org

## Stack Components

| Component      | Version      | Purpose                              | Installation method                |
|----------------|--------------|--------------------------------------|------------------------------------|
| K3s            | v1.29.0+k3s1 | Kubernetes distribution              | Ansible                            |
| ArgoCD         | stable       | GitOps reconciliation                | Ansible bootstrap                  |
| MetalLB        | 0.14.5       | Bare metal load balancer             | ArgoCD → Helm                      |
| Sealed Secrets | 2.15.0       | Secret encryption                    | ArgoCD → Helm                      |
| Traefik        | K3s built-in | Ingress, TLS termination             | K3s built-in, HelmChartConfig only |
| cert-manager   | v1.14.0      | TLS certificate lifecycle            | ArgoCD → Helm                      |
| Reflector      | 7.1.0        | Mirror TLS secrets across namespaces | ArgoCD → Helm                      |
| Longhorn       | 1.6.0        | Distributed persistent storage       | ArgoCD → Helm                      |
| VolSync        | 0.9.0        | PVC backup to Backblaze B2           | ArgoCD → Helm                      |
| AdGuard Home   | latest       | DNS, ad blocking, internal rewrites  | ArgoCD → manifests                 |
| etcd backup    | n/a          | Cluster state snapshots              | ArgoCD → CronJob                   |

## Non-Negotiable File Standards

### Naming
- All filenames lowercase, hyphen-separated
- One Kubernetes resource kind per file, named after that kind
- Exception: two Services for AdGuard — service-dns.yaml and service-http.yaml
- Sealed secret files always named sealed-\<name>-secret.yaml
- ArgoCD Application manifests always named \<component>.yaml under bootstrap/apps/
- Restore manifests named \<component>-restore.yaml under restore/

### Every Kubernetes resource must include
- `namespace:` field explicitly set
- `argocd.argoproj.io/sync-wave` annotation
- No omitted fields — if a field is relevant to the resource, include it

### Sync wave assignments

| Wave | Components                                                 |
|------|------------------------------------------------------------|
| -3   | Namespaces                                                 |
| -2   | MetalLB, Sealed Secrets                                    |
| -1   | Traefik HelmChartConfig, cert-manager, Reflector, Longhorn |
| 0    | VolSync, wildcard certificate, AdGuard                     |
| 1+   | Applications                                               |

### ArgoCD Application defaults
Every Application manifest must include:
- `syncOptions: [CreateNamespace=true]`
- `automated.prune: true` and `automated.selfHeal: true` for infrastructure
- `automated.prune: false` and `automated.selfHeal: true` for stateful components (AdGuard, etcd-backup)
- `repoURL: https://github.com/RockBrackenshield/k3s-gitops`
- `targetRevision: HEAD`

### PVC standards
- Always use `storageClassName: longhorn-usb`
- Always use `reclaimPolicy: Retain`
- Always specify explicit `storage:` capacity
- Always use `accessModes: [ReadWriteOnce]`

### IngressRoute standards
- Always use `entryPoints: [websecure]`
- Always use `tls.secretName: wildcard-hermnet-org-tls`
- Never use `certResolver` — cert-manager manages certificates, not Traefik
- Host rules always use backtick syntax: Host(\`service.hermnet.org\`)

### Sealed Secrets standards
- Every credential must be a sealed secret — never a plain Kubernetes Secret
- Include the exact `kubectl create secret ... | kubeseal` command as a comment at the top of every sealed secret file
- Use PLACEHOLDER values in the sealed secret data fields

### VolSync standards
- Schedule: `"0 2 * * *"` (2am daily)
- Retention: hourly: 6, daily: 7, weekly: 4, monthly: 3
- Backend: restic to Backblaze B2 via S3 API
- copyMethod: Snapshot

## Component-Specific Requirements

### Traefik
- Managed exclusively via HelmChartConfig in infrastructure/traefik/
- Must expose port 53 TCP and UDP as named entrypoints dns-tcp and dns-udp
- externalTrafficPolicy: Local
- The ArgoCD Application for Traefik must include ignoreDifferences for the Traefik Deployment and HelmChart resources to avoid K3s controller conflicts
- Never manage the Traefik Deployment or Helm release directly

### MetalLB
- L2 mode
- One pool: infrastructure-pool (192.168.7.200-192.168.7.220, autoAssign: false)
- Single L2Advertisement covering the pool

### cert-manager
- DNS01 challenge via Cloudflare API token
- Both staging and production ClusterIssuers
- Wildcard certificate for *.hermnet.org and hermnet.org
- dns01RecursiveNameservers: "1.1.1.1:53,8.8.8.8:53"
- dns01RecursiveNameserversOnly: true
- Certificate duration 2160h, renewBefore 360h

### Reflector
- Wildcard cert secret reflected to: adguard, longhorn-system, argocd, volsync-system, etcd-backup
- Annotation-driven reflection on the Certificate's secretTemplate

### Longhorn
- Default StorageClass with annotation `storageclass.kubernetes.io/is-default-class: "true"`
- StorageClass named longhorn-usb
- Default data path /mnt/longhorn-usb
- replicaSoftAntiAffinity: true
- storageMinimalAvailablePercentage: 10
- defaultClassReplicaCount: 2
- Node disk config for k3s-master with disk tag usb and node tag usb-node
- Longhorn UI exposed via IngressRoute at longhorn.hermnet.org

### AdGuard Home
- Two Services: service-dns.yaml (LoadBalancer, IP 192.168.7.202, ports 53 UDP+TCP) and service-http.yaml (ClusterIP, port 80)
- Web UI exposed via IngressRoute at adguard.hermnet.org
- IngressRoute TCP and UDP for DNS traffic via Traefik entrypoints dns-tcp and dns-udp
- PVC: 1Gi for config storage
- VolSync ReplicationSource backing up the config PVC
- Sealed secret for Backblaze B2 restic repository

### VolSync
- Install operator only — no ReplicationSources at the operator level
- ReplicationSources live in each component's own folder

### Ansible
- Target OS: Ubuntu 26.04 LTS
- Disable systemd-resolved on all nodes (conflicts with AdGuard port 53)
- Install open-iscsi and nfs-common on all nodes (Longhorn requirement)
- K3s installed with `--disable servicelb` — MetalLB replaces it
- Sealed Secrets master key restored before ArgoCD root-app is applied
- Kubeconfig fetched to local machine after control plane install
- USB drive mounted via fstab with nofail on k3s-master only

## Example App Structure

Generate a fully worked example application called jellyfin under apps/jellyfin/ that demonstrates the correct pattern for all future applications. This example must include:

**Base manifests (apps/jellyfin/base/):**
- kustomization.yaml
- namespace.yaml
- deployment.yaml — single replica, image jellyfin/jellyfin:10.8.0, resource requests and limits defined
- service.yaml — ClusterIP
- pvc.yaml — 50Gi on longhorn-usb
- ingressroute.yaml — jellyfin.hermnet.org, wildcard TLS secret
- replication-source.yaml — VolSync backup of the PVC
- sealed-jellyfin-b2-repo.yaml — sealed secret for restic repo with generation comment

**Production overlay (apps/jellyfin/overlays/production/):**
- kustomization.yaml — references base, applies patches, pins image to 10.8.0
- patch-replicas.yaml — 1 replica
- patch-resources.yaml — increased memory limit to 1Gi

**Staging overlay (apps/jellyfin/overlays/staging/):**
- kustomization.yaml — references base, applies patches, uses latest image tag
- patch-replicas.yaml — 1 replica

**ArgoCD Application (bootstrap/apps/jellyfin.yaml):**
- Points at apps/jellyfin/overlays/production
- sync-wave: 1
- automated.prune: false, automated.selfHeal: true

## Complete File Tree To Generate

```
k3s-gitops/
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yaml
│   │   └── group_vars/
│   │       ├── all.yaml
│   │       ├── control_plane.yaml
│   │       └── workers.yaml
│   ├── roles/
│   │   ├── common/
│   │   │   ├── tasks/main.yaml
│   │   │   └── handlers/main.yaml
│   │   ├── k3s_server/
│   │   │   └── tasks/main.yaml
│   │   ├── k3s_agent/
│   │   │   └── tasks/main.yaml
│   │   ├── usb_storage/
│   │   │   └── tasks/main.yaml
│   │   └── argocd_bootstrap/
│   │       ├── tasks/main.yaml
│   │       └── files/
│   │           └── sealed-secrets-master-key.yaml
│   ├── bootstrap.yaml
│   └── restore.yaml
├── bootstrap/
│   ├── argocd-install.yaml
│   ├── argocd-ingress.yaml
│   ├── root-app.yaml
│   └── apps/
│       ├── metallb.yaml
│       ├── sealed-secrets.yaml
│       ├── traefik.yaml
│       ├── cert-manager.yaml
│       ├── reflector.yaml
│       ├── longhorn.yaml
│       ├── volsync.yaml
│       ├── adguard.yaml
│       ├── etcd-backup.yaml
│       └── jellyfin.yaml
├── infrastructure/
│   ├── metallb/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── install.yaml
│   │   ├── ip-pool.yaml
│   │   └── l2advertisement.yaml
│   ├── sealed-secrets/
│   │   ├── kustomization.yaml
│   │   └── namespace.yaml
│   ├── traefik/
│   │   ├── kustomization.yaml
│   │   └── helmchartconfig.yaml
│   ├── cert-manager/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── clusterissuer-staging.yaml
│   │   ├── clusterissuer-prod.yaml
│   │   ├── wildcard-cert.yaml
│   │   └── sealed-cloudflare-secret.yaml
│   ├── reflector/
│   │   ├── kustomization.yaml
│   │   └── namespace.yaml
│   ├── longhorn/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── helmrelease.yaml
│   │   ├── node-disk-config.yaml
│   │   ├── storage-class.yaml
│   │   └── ingressroute.yaml
│   ├── volsync/
│   │   ├── kustomization.yaml
│   │   └── namespace.yaml
│   ├── adguard/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service-dns.yaml
│   │   ├── service-http.yaml
│   │   ├── pvc.yaml
│   │   ├── ingressroute.yaml
│   │   ├── ingressroute-tcp.yaml
│   │   ├── ingressroute-udp.yaml
│   │   ├── replication-source.yaml
│   │   └── sealed-adguard-b2-repo.yaml
├── apps/
│   └── jellyfin/
│       ├── base/
│       │   ├── kustomization.yaml
│       │   ├── namespace.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── pvc.yaml
│       │   ├── ingressroute.yaml
│       │   ├── replication-source.yaml
│       │   └── sealed-jellyfin-b2-repo.yaml
│       └── overlays/
│           ├── production/
│           │   ├── kustomization.yaml
│           │   ├── patch-replicas.yaml
│           │   └── patch-resources.yaml
│           └── staging/
│               ├── kustomization.yaml
│               └── patch-replicas.yaml
├── restore/
│   ├── adguard-restore.yaml
│   └── adguard-pvc-final.yaml
└── docs/
    ├── ai-prompt.md
    ├── runbook-restore.md
    └── sealed-secrets-backup.md
```

## Generation Instructions

- Generate files in tree order, top to bottom
- Prefix every file with a comment line showing its full path relative to repo root
- For sealed secret files, include the exact kubeseal generation command as a comment block at the top of the file
- For docs/ files, generate real human-readable markdown content — not placeholders
- For docs/ai-prompt.md, include a perfect, 1:1 copy of this prompt suitable for ongoing use in future conversations
- For docs/runbook-restore.md, write the full step-by-step recovery procedure based on everything in this prompt
- For docs/sealed-secrets-backup.md, write guidance on what to store offline, where, and why
- The ansible/roles/argocd_bootstrap/files/sealed-secrets-master-key.yaml file should contain a clear explanation of what belongs there and how to generate it, formatted as a YAML comment block
- Where exact values are hardware or account specific (UUID, API keys, passwords, bucket names), use clearly named placeholders in SCREAMING_SNAKE_CASE
