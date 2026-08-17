# Sealing the Paperless secrets

Run these from `hermtop` with `kubeseal` pointed at the live cluster, exactly
as you do for the other apps. `printf`, never `echo` — trailing newlines
corrupt the sealed value.

## paperless-samba-creds

```bash
SMB_PASSWORD='choose-a-long-random-password'

printf '%s' 'paperless' | kubeseal --raw --scope strict \
  --name paperless-samba-creds --namespace paperless \
  --from-file=/dev/stdin > /tmp/username.enc   # not actually needed as a
                                                 # separate step - see below

# Easiest path: build the plaintext Secret in-memory and seal the whole
# object in one shot instead of field-by-field:
kubectl create secret generic paperless-samba-creds \
  --namespace paperless \
  --from-literal=username=paperless \
  --from-literal=password="${SMB_PASSWORD}" \
  --dry-run=client -o yaml | kubeseal --format yaml \
  > apps/paperless/base/secrets/sealed-secret-samba-creds.yaml
```

Keep `${SMB_PASSWORD}` in your password manager — you'll need the same value
if you ever want to `smbclient` into the share manually.

## paperless-env

```bash
DJANGO_SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')"
ADMIN_PASSWORD='choose-a-long-random-password'

kubectl create secret generic paperless-env \
  --namespace paperless \
  --from-literal=secret-key="${DJANGO_SECRET_KEY}" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubeseal --format yaml \
  > apps/paperless/base/secrets/sealed-secret-paperless-env.yaml
```

`admin-user`/`admin-password` are only consumed on first start (superuser
bootstrap) — after that, manage users through Paperless itself.

Overwrite the two placeholder files in this directory with the real output
before you let ArgoCD sync this Application.
