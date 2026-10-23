#!/usr/bin/env bash
# Encryption guard for SOPS-managed files (pre-commit hook + CI job).
# Fails if:
#   - a *.sops.yaml / *.sops.yml file lacks SOPS metadata (sops: block + MAC),
#     or holds any value outside the sops: block that is not ENC[...];
#   - a Talos/Kubernetes credential file is present (talosconfig, kubeconfig*,
#     plaintext secrets.yaml, rendered talos/_out/*).
# It needs no key: it only inspects structure, never decrypts.
# Usage: scripts/check-sops.sh [file ...]   (no args: all tracked + untracked, non-ignored files)
set -euo pipefail

fail=0
if [ "$#" -eq 0 ]; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard)
else
  files=("$@")
fi

err() { echo "ERROR: $*" >&2; fail=1; }

# Prints the first line (outside the top-level sops: block) whose value is
# not ENC[...]. Keys stay plaintext in SOPS output; values must not.
plaintext_value() {
  awk '
    /^sops:/            { insops = 1; next }
    /^[^[:space:]#-]/   { insops = 0 }
    insops              { next }
    /^[[:space:]]*(#|$)/ { next }
    /^---[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*(- )?/, "", line)            # list item marker
      if (line ~ /^ENC\[/) next                       # "- ENC[...]"
      if (line ~ /^[^:]+:[[:space:]]*$/) next         # "key:" (map/list follows)
      if (line ~ /^[^:]+:[[:space:]]+ENC\[/) next     # "key: ENC[...]"
      print FILENAME ":" NR; exit
    }
  ' "$1"
}

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$f" in
    talos/_out/*|*/talos/_out/*)
      err "$f is a rendered Talos config (talos/_out/ must stay untracked)"; continue ;;
  esac
  case "$base" in
    .sops.yaml) continue ;;                                   # creation rules, public recipients only
    talosconfig|kubeconfig*|secrets.yaml|secrets.yml)
      err "$f is a credential file and must never be committed"; continue ;;
    *.sops.yaml|*.sops.yml)
      if ! grep -qE '^sops:' "$f" || ! grep -qE '^[[:space:]]+mac: ENC\[' "$f"; then
        err "$f is not SOPS-encrypted (missing sops: metadata or MAC)"
      elif bad=$(plaintext_value "$f") && [ -n "$bad" ]; then
        err "$f has an unencrypted value at $bad"
      fi
      ;;
  esac
done
exit "$fail"
