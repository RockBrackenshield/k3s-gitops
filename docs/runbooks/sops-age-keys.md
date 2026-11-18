# Runbook: SOPS and age keys (Talos part)

Based on k3s-gitops `main` at `37b7a7c`. File references mean that file at 37b7a7c.

## Purpose, scope, when to use

The Talos node configs need two kinds of secret, both committed **only encrypted** with SOPS and age:
- `talos/secrets.sops.yaml`: the cluster CA and tokens.
- `talos/nodes/<HOST>.tailscale.sops.yaml`: one Tailscale auth key per node.

The decryption rules live in `.sops.yaml`. `talos/Makefile` decrypts them only into a pipe (`SECRETS ?= <(sops -d secrets.sops.yaml)`).

Use this runbook to:
- set up a new workstation;
- edit or create an encrypted file;
- add a break-glass recipient;
- rotate after a suspected leak;
- back up the private key and prove you can restore it.

Out of scope:
- The Sealed Secrets master key: `docs/sealed-secrets-backup.md`.
- The Flux cluster key: see "Flux part", which is TBD.

> **Teaching point:** the age **public** key (the recipient, `age1…`) sits in `.sops.yaml` and is safe to commit. The **private** key (the identity in `keys.txt`) must never be committed; `.gitignore` covers `keys.txt` and `*.agekey`.
>
> If you lose every private key, the running cluster keeps working, but you can no longer render node configs. That blocks every upgrade, every new node and every rebuild.

## Prerequisites

- [ ] `sops` at `SOPS_VERSION=v3.13.3` (`talos/versions.env`) and `age`, installed on the workstation and checked against their published checksums.
- [ ] A repo checkout and bash, needed for process substitution.
- [ ] The private key at `<AGE_PRIVATE_KEY_PATH>`. The repo default is `~/.config/sops/age/keys.txt` (`.sops.yaml` comment, `talos/README.md`).
- [ ] The pre-commit guard installed: `pre-commit install` (`.pre-commit-config.yaml` runs `scripts/check-sops.sh`).

## Task A: set up a workstation that can decrypt

1. Restore the private key so it is never readable by others, not even for a moment:
   ```bash
   umask 077
   mkdir -p -m 700 "$(dirname <AGE_PRIVATE_KEY_PATH>)"
   # paste the keys.txt contents from the password manager into <AGE_PRIVATE_KEY_PATH>
   chmod 600 <AGE_PRIVATE_KEY_PATH>
   ```
   Clear the clipboard afterwards. If the key isn't at the default path, set `export SOPS_AGE_KEY_FILE=<AGE_PRIVATE_KEY_PATH>`.
   **Verify:** `ls -l <AGE_PRIVATE_KEY_PATH>` shows `-rw-------`, and the directory shows `drwx------`.
2. Check the key matches the repo:
   ```bash
   age-keygen -y <AGE_PRIVATE_KEY_PATH>       # prints the public key
   grep -o 'age1[a-z0-9]*' .sops.yaml | sort -u
   ```
   **Verify:** the printed public key is one of the recipients in `.sops.yaml`.
3. Test a decrypt without printing anything:
   ```bash
   sops -d talos/secrets.sops.yaml >/dev/null && echo DECRYPT-OK
   ```
   **Verify:** you see `DECRYPT-OK`. Never send decrypted output to the terminal or to a file in the checkout.

## Task B: edit an existing encrypted file

`sops edit` decrypts into a temporary file. Editors can leave plaintext copies in swap, backup or undo files, so use an editor setting without them, for example:
```bash
export EDITOR='vim -n -i NONE -c "set nobackup nowritebackup noundofile"'
sops edit talos/nodes/k3s-master.tailscale.sops.yaml   # opens decrypted in $EDITOR; re-encrypts on save
scripts/check-sops.sh talos/nodes/k3s-master.tailscale.sops.yaml
```
**Verify:**
- The guard exits 0.
- `git diff` shows only `ENC[...]` values and `sops:` metadata changing.
- `make -C talos gen validate` passes.

## Task C: create a node's Tailscale file (workers are missing at 37b7a7c)

Only `talos/nodes/k3s-master.tailscale.sops.yaml` exists, and `make gen` reads one per node (`TS_SRC` in `talos/Makefile`).

1. In the Tailscale admin console, create one **tagged** (`tag:talos-node`), pre-approved, **single-use** auth key per node, with a short expiry (`talos/tailscale.example.yaml`). Call it `<TS_AUTHKEY>`.
2. Create the file:
   ```bash
   sops edit talos/nodes/k3s-worker-1.tailscale.sops.yaml
   ```
   Paste the contents of `talos/tailscale.example.yaml`. Set `TS_AUTHKEY=<TS_AUTHKEY>` and `TS_HOSTNAME=talos-k3s-worker-1`, then save. The file matches the `^talos/.*\.sops\.yaml$` rule in `.sops.yaml`, so sops encrypts it.
3. Repeat for k3s-worker-2.

**Verify:** `scripts/check-sops.sh` passes on both files, and `make -C talos gen validate` renders all three nodes. Never create a plaintext `talos/nodes/*.tailscale.yaml`; it is gitignored for a reason.

## Task D: add a second (break-glass) recipient

At 37b7a7c, `.sops.yaml` has **one** recipient. Plan v3 recommends a second, offline one.

1. On an offline or second machine, create the key passphrase-protected, so it never sits on disk in plaintext:
   ```bash
   umask 077
   age-keygen | age -p -o <BREAKGLASS_KEY_PATH>.age   # prints the public key on stderr; age asks for a passphrase
   ```
   Note the public key `<AGE_BREAKGLASS_PUBLIC_KEY>`. Store the passphrase separately from the `.age` file. A hardware token is a valid alternative.
2. Add it to **both** rules in `.sops.yaml`, comma-separated: `age: >- <AGE_PRIMARY_PUBLIC_KEY>,<AGE_BREAKGLASS_PUBLIC_KEY>`. Keep the Talos rules in their current order, since sops uses the first matching rule.
3. Re-wrap the data keys:
   ```bash
   sops updatekeys -y talos/secrets.sops.yaml talos/nodes/*.tailscale.sops.yaml
   ```
   This command is in the comment in `.sops.yaml`.

**Verify:** on the second machine, with *only* the break-glass key, unlock it into RAM, test, and remove it:
```bash
umask 077
age -d -o /dev/shm/breakglass.key <BREAKGLASS_KEY_PATH>.age
SOPS_AGE_KEY_FILE=/dev/shm/breakglass.key sops -d talos/secrets.sops.yaml >/dev/null && echo OK
rm -f /dev/shm/breakglass.key
```
It prints OK, and `ls /dev/shm/breakglass.key` then fails. Commit the change through a PR.

## Task E: remove or rotate a recipient (suspected leak)

1. Remove the compromised public key from both rules in `.sops.yaml`. Add a new primary key first if needed (Task D steps 1–3).
2. Run `sops updatekeys -y` on every `talos/**/*.sops.yaml`, then `sops rotate -i <FILE>` on each one. `updatekeys` only re-wraps the data key; `rotate` makes a new one (rev3 plan, "Secrets" section).
3. If the private key leaked, assume the **contents** leaked as well:
   > **Rotation protects only future commits.** The repository is public, so every earlier encrypted version of `talos/secrets.sops.yaml` and `talos/nodes/*.tailscale.sops.yaml` stays in git history and **still decrypts with the leaked key**. Steps 1–2 do not contain the leak.
   - **Talos secrets bundle:** treat it as **compromised**. It holds the cluster CA and machine tokens, so anyone holding it can mint Talos and Kubernetes admin credentials. Treat the cluster as compromised too.
   - **Contain now:** until Rock decides on CA rotation or a rebuild, restrict the Talos API (TCP 50000) and the Kubernetes API (TCP 6443) to trusted hosts only, for example with router or firewall rules. Confirm from an untrusted host that both ports are closed.
   - TBD: CA rotation or a rebuild (Talos docs, "CA rotation"). Get Rock's decision before you act.
   - **Tailscale:** revoke the node keys in the admin console and issue new single-use keys (Task C).

**Verify:**
- Decrypting HEAD with the old key now fails, and the new key works (Task A, step 3).
- Ports 50000 and 6443 refuse connections from an untrusted host.
- The rotation-or-rebuild decision is recorded. Until it is made, the leak is **not** contained.

## Task F: back up the private key and prove a restore

1. Store the full contents of `keys.txt` as a password-manager entry. Also keep **one offline copy**: paper/QR, or an encrypted USB drive stored elsewhere. This follows the rev3 plan; `docs/sealed-secrets-backup.md` has the same pattern.
2. On a **second machine**, restore the key from the backup only, then run Task A steps 2–3.
3. Remove the key from the drill machine unless it is meant to keep it: `rm -f <AGE_PRIVATE_KEY_PATH>`, and clear the clipboard.
4. Record the date and set a 90-day review reminder.

**Verify:** you see DECRYPT-OK on a machine that never had the original key file. After step 3, `ls <AGE_PRIVATE_KEY_PATH>` fails on the drill machine.

## Task G (rare): new cluster secrets bundle

Only for a brand-new cluster, because this replaces the CA. The command is from `talos/README.md`, run in `talos/`:
```bash
umask 077
talosctl gen secrets -o secrets.yaml \
  && sops -e --filename-override secrets.sops.yaml secrets.yaml > secrets.sops.yaml.new \
  && mv secrets.sops.yaml.new secrets.sops.yaml
shred -u secrets.yaml; rm -f secrets.sops.yaml.new
```
This differs from `talos/README.md` on purpose: writing straight to `> secrets.sops.yaml` empties the existing file before `sops` runs, so a failed `sops` leaves an empty bundle. `shred` is unreliable on SSD and copy-on-write filesystems, so run this in a tmpfs or encrypted-disk checkout if you can.
**Verify:** `ls secrets.yaml` fails (the plaintext is gone), `secrets.sops.yaml` is non-empty, and the guard passes.

## Rollback

- **`.sops.yaml` or `updatekeys` changes:** use `git revert` on the PR. That restores files encrypted to the previous recipients. Only do it if those keys are still trusted.
- **A file broken during edit:** `git checkout -- <FILE>`. The previous encrypted version still decrypts.
- **No rollback for a leaked key.** Rotate (Task E).

## Flux part

TBD. Draft this only after go-live (#10), the guard fix (PR-G) and Rock's secrets PR (PR-S) exist. Plan v3 §3 sets these rules:
- A **separate** age key for the cluster, never the Talos key.
- A `sops-age` Secret in `flux-system`, created by Rock, with a key filename ending in `.agekey`.
- A new `.sops.yaml` rule with `encrypted_regex: ^(data|stringData)$` whose `path_regex` cannot match `talos/`.
- A `check-sops.sh` change so Flux Secrets pass the guard.

TBD: the exact secret paths (`flux/secrets/…` in draft #9) and the steps to verify decryption.

## References

- `.sops.yaml`, `.gitignore`, `.pre-commit-config.yaml`
- `scripts/check-sops.sh`, `scripts/tests/check-sops_test.sh`
- `talos/Makefile` (`SECRETS`, `TS_SRC`, `gen`)
- `talos/README.md` ("Before the first make gen")
- `talos/tailscale.example.yaml`, `talos/versions.env`
- `docs/sealed-secrets-backup.md`
- Project notes: `talos-migration-plan-rev3` ("Secrets: SOPS + age runbook"), `project-flux/plan-v3.md` §3
- sops README, age README

## Staleness note (Flux PRs)

- The Talos tasks (A–G) stay valid.
- When PR-G and PR-S land, `.sops.yaml` gains a Flux rule and `check-sops.sh` changes. Re-check the Task D wording ("add to both rules") and the guard output in Task B.
- After the old cluster retires, this runbook plus the Flux part replace `docs/sealed-secrets-backup.md`.
