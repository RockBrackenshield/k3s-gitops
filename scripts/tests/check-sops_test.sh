#!/usr/bin/env bash
# Tests for scripts/check-sops.sh. Builds throwaway git repos in a temp dir;
# every fixture is fake (no real key material) and nothing is written to this repo.
# Usage: scripts/tests/check-sops_test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$here/check-sops.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

# A file shaped like sops output: values ENC[...], plus sops metadata and a MAC.
encrypted() {
  cat <<'YAML'
cluster:
    id: ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
    secret: ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
certs:
    - ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
sops:
    age:
        - recipient: age1REPLACE_ME
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ZmFrZQ==
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2026-10-23T00:00:00Z"
    mac: ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
    version: 3.13.3
YAML
}

# expect <want-rc> <description> <path-in-repo> <content-fn|-> [extra files...]
expect() {
  local want=$1 desc=$2 path=$3 content=$4 repo got
  repo=$(mktemp -d "$tmp/repo.XXXX")
  git -C "$repo" init -q
  mkdir -p "$repo/$(dirname "$path")"
  if [ "$content" = "-" ]; then cat > "$repo/$path"; else "$content" > "$repo/$path"; fi
  git -C "$repo" add -A
  set +e
  (cd "$repo" && "$guard" >/dev/null 2>&1)
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then
    echo "ok   - $desc (rc=$got)"; pass=$((pass + 1))
  else
    echo "FAIL - $desc (want rc=$want, got rc=$got)"; failed=$((failed + 1))
  fi
}

expect 0 "encrypted talos/secrets.sops.yaml passes" talos/secrets.sops.yaml encrypted
expect 0 "encrypted node tailscale file passes" talos/nodes/k3s-master.tailscale.sops.yaml encrypted
expect 1 "plaintext *.sops.yaml is rejected" talos/secrets.sops.yaml - <<'YAML'
cluster:
    id: plain-value-not-encrypted
YAML
expect 1 "sops block but plaintext nested value is rejected" talos/secrets.sops.yaml - < <(encrypted | sed 's/^    secret: ENC.*/    secret: plain-value/')
expect 1 "sops block but plaintext list item is rejected" talos/secrets.sops.yaml - < <(encrypted | sed 's/^    - ENC.*/    - plain-value/')
expect 1 "ENC values without a MAC are rejected" talos/secrets.sops.yaml - < <(encrypted | grep -v 'mac: ENC')
expect 1 "plaintext top-level value is rejected" talos/x.sops.yaml - < <(echo "token: plain-value"; encrypted)
expect 1 "talosconfig is rejected" talos/talosconfig - <<<"context: x"
expect 1 "kubeconfig is rejected" kubeconfig - <<<"apiVersion: v1"
expect 1 "plaintext secrets.yaml is rejected" talos/secrets.yaml - <<<"cluster: {}"
expect 1 "rendered talos/_out config is rejected" talos/_out/k3s-master.yaml - <<<"version: v1alpha1"
expect 0 "talos/patches/controlplane.yaml is allowed" talos/patches/controlplane.yaml - <<<"kind: KubeProxyConfig"
expect 0 ".sops.yaml (creation rules) is allowed" .sops.yaml - <<<"creation_rules: []"
expect 0 "plain repo file is allowed" README.md - <<<"hello"

# Explicit file arguments (pre-commit passes filenames).
f="$tmp/plain.sops.yaml"; echo "a: b" > "$f"
if "$guard" "$f" >/dev/null 2>&1; then echo "FAIL - explicit plaintext arg accepted"; failed=$((failed + 1)); else echo "ok   - explicit plaintext arg rejected"; pass=$((pass + 1)); fi

echo "check-sops tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
