#!/usr/bin/env bash
# Tests for scripts/check-versions.sh (offline part). Each case mutates a temp
# copy of the files the check reads.
# Usage: scripts/tests/check-versions_test.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

fresh() {
  rm -rf "$tmp/w"; mkdir -p "$tmp/w/bootstrap/apps" "$tmp/w/.github/workflows"
  cp -r "$repo/talos" "$repo/scripts" "$tmp/w/"
  cp "$repo/.github/workflows/validate.yml" "$tmp/w/.github/workflows/"
  cp "$repo/bootstrap/apps/cilium.yaml" "$tmp/w/bootstrap/apps/"
}

# expect <want-rc> <description> <sed-expr> <file>
expect() {
  local want=$1 desc=$2 expr=$3 file=$4 got
  fresh
  [ -n "$expr" ] && sed -i -E "$expr" "$tmp/w/$file"
  set +e; (cd "$tmp/w" && scripts/check-versions.sh >/dev/null 2>&1); got=$?; set -e
  if [ "$got" -eq "$want" ]; then echo "ok   - $desc"; pass=$((pass + 1))
  else echo "FAIL - $desc (want $want, got $got)"; failed=$((failed + 1)); fi
}

expect 0 "repo as committed is in sync" "" talos/versions.env
expect 1 "CILIUM_VERSION bump without the Argo app fails" 's/^CILIUM_VERSION=.*/CILIUM_VERSION=1.20.5/' talos/versions.env
expect 1 "Argo app bump without versions.env fails" '/chart: cilium/,/targetRevision/ s/targetRevision: .*/targetRevision: 1.20.5/' bootstrap/apps/cilium.yaml
expect 1 "Argo cilium app with a range instead of an exact version fails" '/chart: cilium/,/targetRevision/ s/targetRevision: .*/targetRevision: 1.20.*/' bootstrap/apps/cilium.yaml
expect 1 "TALOS_VERSION bump without new installer refs fails" 's/^TALOS_VERSION=.*/TALOS_VERSION=v1.14.5/' talos/versions.env
expect 1 "installer digest drift in rpi4 patch fails" 's/@sha256:9dfd9dcd/@sha256:0000000d/' talos/patches/rpi4.yaml
expect 1 "installer without digest in rpi5 patch fails" 's/@sha256:[0-9a-f]+$//' talos/patches/rpi5.yaml
expect 1 "schematic ID drift fails" 's/^SCHEMATIC_RPI4=.*/SCHEMATIC_RPI4=deadbeef/' talos/versions.env
expect 1 "malformed CILIUM_CHART_SHA256 fails" 's/^CILIUM_CHART_SHA256=.*/CILIUM_CHART_SHA256=abc/' talos/versions.env
expect 1 "KUBERNETES_VERSION bump without validate.yml K8S_VERSION fails" 's/^KUBERNETES_VERSION=.*/KUBERNETES_VERSION=1.36.6/' talos/versions.env
expect 1 "validate.yml K8S_VERSION drift fails" 's/^(  K8S_VERSION: ).*/\11.35.0/' .github/workflows/validate.yml

echo "check-versions tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
