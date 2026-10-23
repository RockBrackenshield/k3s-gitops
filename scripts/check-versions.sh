#!/usr/bin/env bash
# Version-sync check (CI: .github/workflows/talos.yml; locally: run from repo root).
#   offline (always):
#     - talos/versions.env CILIUM_VERSION == cilium chart targetRevision in
#       bootstrap/apps/cilium.yaml (exact version)
#     - CILIUM_CHART_SHA256 is a sha256; schematic IDs are 64-hex
#     - talos/patches/rpi{4,5}.yaml installer == factory ref built from
#       SCHEMATIC_RPIx:TALOS_VERSION@INSTALLER_DIGEST_RPIx
#   --render (network, needs helm):
#     - pull the Cilium chart, verify CILIUM_CHART_SHA256, render it with
#       infrastructure/cilium/values.yaml and require every image to be @sha256
# Usage: scripts/check-versions.sh [--render]
set -euo pipefail

fail=0
err() { echo "ERROR: $*" >&2; fail=1; }
env_file=talos/versions.env
app=bootstrap/apps/cilium.yaml

get() { sed -n "s/^$1=//p" "$env_file" | tail -1; }
TALOS_VERSION=$(get TALOS_VERSION)
CILIUM_VERSION=$(get CILIUM_VERSION)
CILIUM_CHART_SHA256=$(get CILIUM_CHART_SHA256)

# targetRevision of the list item under sources: that has `chart: cilium`.
app_rev=$(awk '
  /^[[:space:]]*- [A-Za-z]+:/ { chart = ""; rev = "" }
  /^[[:space:]]+(- )?chart:[[:space:]]*cilium[[:space:]]*$/ { chart = 1 }
  /^[[:space:]]+(- )?targetRevision:/ { r = $0; sub(/.*targetRevision:[[:space:]]*/, "", r); sub(/[[:space:]]*#.*/, "", r); rev = r }
  chart && rev != "" { print rev; exit }
' "$app")

[[ $CILIUM_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "CILIUM_VERSION '$CILIUM_VERSION' is not an exact x.y.z version"
[[ $app_rev =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "$app chart targetRevision '$app_rev' is not an exact x.y.z version"
[ "$CILIUM_VERSION" = "$app_rev" ] || err "CILIUM_VERSION=$CILIUM_VERSION ($env_file) != targetRevision $app_rev ($app)"
[[ $CILIUM_CHART_SHA256 =~ ^[0-9a-f]{64}$ ]] || err "CILIUM_CHART_SHA256 is not a sha256"
[[ $TALOS_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "TALOS_VERSION '$TALOS_VERSION' is not vX.Y.Z"

for b in 4 5; do
  id=$(get "SCHEMATIC_RPI$b"); dg=$(get "INSTALLER_DIGEST_RPI$b")
  [[ $id =~ ^[0-9a-f]{64}$ ]] || err "SCHEMATIC_RPI$b is not a 64-hex schematic ID"
  [[ $dg =~ ^sha256:[0-9a-f]{64}$ ]] || err "INSTALLER_DIGEST_RPI$b is not sha256:<64 hex>"
  want="factory.talos.dev/metal-installer/$id:$TALOS_VERSION@$dg"
  have=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "talos/patches/rpi$b.yaml" | sed 's/[[:space:]]*#.*//')
  [ "$have" = "$want" ] || err "talos/patches/rpi$b.yaml installer '$have' != '$want' (versions.env)"
done

if [ "${1:-}" = "--render" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  helm pull cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" -d "$tmp"
  if echo "$CILIUM_CHART_SHA256  $tmp/cilium-$CILIUM_VERSION.tgz" | sha256sum -c - >/dev/null; then
    echo "cilium-$CILIUM_VERSION.tgz sha256 OK"
  else
    err "cilium-$CILIUM_VERSION.tgz sha256 != CILIUM_CHART_SHA256"
  fi
  helm template cilium "$tmp/cilium-$CILIUM_VERSION.tgz" -n kube-system \
    -f infrastructure/cilium/values.yaml > "$tmp/rendered.yaml"
  mapfile -t images < <(sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$tmp/rendered.yaml" | sort -u)
  [ "${#images[@]}" -gt 0 ] || err "no images found in the rendered Cilium chart"
  for i in "${images[@]}"; do
    [[ $i =~ @sha256:[0-9a-f]{64}$ ]] || err "Cilium image not digest-pinned: $i"
  done
  echo "${#images[@]} Cilium images checked"
fi

[ "$fail" -eq 0 ] && echo "versions in sync (Talos $TALOS_VERSION, Cilium $CILIUM_VERSION)"
exit "$fail"
