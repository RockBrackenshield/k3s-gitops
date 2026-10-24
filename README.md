# k3s-gitops

GitOps repo for the hermnet homelab: three Raspberry Pis (Pi 5 control plane,
two Pi 4 workers) running Talos Linux, with Cilium (CNI, LoadBalancer IPs via
L2 announcements), Traefik, Longhorn on the Pi 5 USB disk, and Argo CD
reconciling everything under `bootstrap/apps/`. (The repo name predates the
move from k3s to Talos.)

- Nodes: [`talos/README.md`](talos/README.md)
- Rebuild / disaster recovery: [`docs/runbook-restore.md`](docs/runbook-restore.md)
- Sealed Secrets key backup: [`docs/sealed-secrets-backup.md`](docs/sealed-secrets-backup.md)
- Working in the repo (layout, CI, rules): [`AGENTS.md`](AGENTS.md)
