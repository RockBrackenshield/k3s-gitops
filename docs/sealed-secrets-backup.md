<!-- k3s-gitops/docs/sealed-secrets-backup.md -->
# Sealed Secrets Backup Strategy

Sealed Secrets is the single most critical piece of data in this cluster.
Every application secret is encrypted with the Sealed Secrets controller's
master key pair. If you rebuild the cluster without restoring this key,
every `SealedSecret` in the repository becomes permanently undecryptable
and you must re-create every credential from scratch.

This document tells you what to back up, where, and how.

---

## What You Must Back Up

### 1. The Sealed Secrets Master Key

The Sealed Secrets controller generates a TLS key pair on first boot.
This key pair is stored as a Kubernetes `Secret` in the `sealed-secrets` namespace.

**Export it immediately after initial cluster bootstrap and after any key rotation:**

```bash
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > sealed-secrets-master-key.yaml
```

The exported file contains a `tls.crt` and `tls.key` encoded in base64.
This file is **the only thing that can decrypt your sealed secrets**.

### 2. Restic Repository Passwords

Each VolSync backup repository uses a unique restic password. These passwords
are stored inside sealed secrets, meaning if you lose the Sealed Secrets master
key, you also lose access to your restic passwords and therefore your backups.

Store restic passwords independently, in plaintext in your password manager:
- `adguard` restic password
- `jellyfin` restic password
- `etcd-backup` restic password

### 3. Backblaze B2 Credentials

Store these in your password manager:
- B2 Key ID
- B2 Application Key

These allow you to verify and manually access backups even outside of VolSync.

### 4. Cloudflare API Token

The cert-manager Cloudflare token is sealed. Store it in your password manager
so you can re-seal it after a cluster rebuild.

---

## Where to Store the Master Key

Use at least **two** of the following storage methods. One method must be
completely offline (no internet connection required to access it).

### Method A — Encrypted Password Manager (Required)

Store the contents of `sealed-secrets-master-key.yaml` as a secure note in
your password manager (Bitwarden, 1Password, etc.). Most password managers
allow file attachments — use that.

**Pros:** Fast to retrieve, encrypted at rest, accessible from anywhere.
**Cons:** Cloud-dependent, subject to account lockout.

### Method B — Printed Hard Copy in a Fireproof Safe (Strongly Recommended)

Print the `sealed-secrets-master-key.yaml` file (or its base64 key values) and
store it in a fireproof safe or safe-deposit box.

**Pros:** Completely offline, survives disasters that destroy digital storage.
**Cons:** Requires physical access; key must be typed back in if no digital backup survives.

### Method C — Encrypted USB Drive in a Separate Physical Location

Encrypt a USB drive (LUKS on Linux or VeraCrypt) and copy the file to it.
Store the USB at a secondary location (parent's home, workplace, bank vault).

**Pros:** Easy to retrieve digitally, truly offline.
**Cons:** USB drives can fail; store at least two.

### Method D — QR Code on Laminated Card

Convert the `tls.key` base64 value to a QR code using a tool like `qrencode`.
Print it on card stock, laminate it, and store with your physical documents.

```bash
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.key}' | qrencode -o sealed-secrets-key.png
```

---

## When to Update Your Backup

Update all offline backups any time the Sealed Secrets master key changes:

- **After initial cluster bootstrap** — the key is generated at first controller startup
- **After intentional key rotation** — Sealed Secrets supports multiple keys; always export the active key after rotation
- **After cluster rebuilds** — if you rebuild without restoring the old key, a new key is generated and all existing sealed secrets must be re-sealed

To check the active key age:
```bash
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].metadata.creationTimestamp}'
```

---

## How to Verify Your Backup Is Usable

Test your backup by decrypting a sealed secret offline:

```bash
# 1. Export a known SealedSecret from the cluster
kubectl get sealedsecret cloudflare-api-token -n cert-manager -o yaml > test-sealed.yaml

# 2. Restore your backup key to a test cluster or use kubeseal's --recovery-private-key flag
kubeseal --recovery-private-key sealed-secrets-master-key.yaml \
         --dump-certificate > /dev/null && echo "Key is valid and readable"

# 3. Attempt to decrypt the sealed secret
cat test-sealed.yaml | kubeseal \
  --recovery-private-key sealed-secrets-master-key.yaml \
  --recovery-unseal \
  -o yaml
```

If this outputs the original plaintext secret, your backup is valid.
Run this test at least once after every key rotation or cluster rebuild.

---

## Security Checklist

- [ ] `sealed-secrets-master-key.yaml` is listed in `.gitignore` (never committed to git)
- [ ] The file has been exported and stored in at least two offline locations
- [ ] All restic repository passwords are stored in your password manager independently of the cluster
- [ ] All B2 credentials are stored in your password manager
- [ ] The backup was verified usable using the kubeseal recovery method above
- [ ] The backup date is recorded and a calendar reminder is set to review backups every 90 days

---

## Quick Reference — Key Commands

```bash
# Export the active Sealed Secrets master key
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > ansible/roles/argocd_bootstrap/files/sealed-secrets-master-key.yaml

# Re-seal any secret after a cluster rebuild
kubectl create secret generic <name> \
  --namespace <namespace> \
  --from-literal=KEY=VALUE \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
> path/to/sealed-<name>-secret.yaml

# Check which Sealed Secrets are deployed in the cluster
kubectl get sealedsecret -A

# Rotate the Sealed Secrets key (generates a new key; old key remains for decryption)
kubectl annotate secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  sealedsecrets.bitnami.com/sealed-secrets-key=compromised
# Restart the controller to generate a new key
kubectl rollout restart deployment sealed-secrets-controller -n sealed-secrets
# Then immediately export and store the new key
```
````
