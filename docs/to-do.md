# To-Do — k3s-gitops

Next steps after the Talos bring-up.

## Items
1. Encrypted etcd backups to Backblaze B2 (first priority): start with
   `make -C talos etcd-backup` + `age` + `rclone`/`restic`; consider the
   siderolabs/talos-backup CronJob once it leaves beta.
2. Longhorn backups for media (backup target + recurring jobs); check B2 cost
   or use a LAN NAS.
3. More disks: USB SSDs on the Pi 4 workers, then replicas 2
   (`talos/README.md` "Adding a disk later").
4. Choose an off-cluster log receiver and enable shipping
   (`talos/patches/common.yaml`, commented out).
5. Digest-pin the remaining images that still use plain tags (see the Talos
   migration PR follow-up list).
6. Optional: Talos ingress firewall for 50000/6443; Traefik Gateway API
   provider pilot.
