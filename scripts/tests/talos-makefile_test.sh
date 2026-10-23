#!/usr/bin/env bash
# Tests for talos/Makefile safety guards, using fake talosctl/helm/sops on PATH
# (nothing touches a real node). Runs against a temp copy of talos/.
# Usage: scripts/tests/talos-makefile_test.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

mkdir -p "$tmp/bin" "$tmp/w/infrastructure/cilium"
cp -r "$repo/talos" "$tmp/w/talos"
rm -rf "$tmp/w/talos/_out"
mkdir -p "$tmp/w/talos/_out"
echo "fake: values" > "$tmp/w/infrastructure/cilium/values.yaml"
for n in k3s-master k3s-worker-1 k3s-worker-2; do echo "fake: $n" > "$tmp/w/talos/_out/$n.yaml"; done
log="$tmp/calls.log"
for tool in talosctl sops; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$tool" "$log" > "$tmp/bin/$tool"
done
# fake helm: `helm pull` writes a tgz whose content is $FAKE_CHART_CONTENT.
cat > "$tmp/bin/helm" <<FAKE
#!/usr/bin/env bash
echo "helm \$*" >> "$log"
if [ "\$1" = pull ]; then
  dest=.; ver=
  while [ \$# -gt 0 ]; do case "\$1" in -d|--destination) dest=\$2; shift;; --version) ver=\$2; shift;; esac; shift; done
  printf '%s' "\${FAKE_CHART_CONTENT:-x}" > "\$dest/cilium-\$ver.tgz"
fi
FAKE
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

# check <want: ok|fail> <description> <grep-pattern-in-log or -> -- make args...
check() {
  local want=$1 desc=$2 pat=$3 rc out; shift 3
  : > "$log"
  set +e
  out=$(make --no-print-directory -C "$tmp/w/talos" "$@" 2>&1)
  rc=$?
  set -e
  local ok=1
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then ok=0; fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then ok=0; fi
  if [ "$pat" != - ]; then
    if [ "${pat:0:1}" = '!' ]; then grep -qE -- "${pat:1}" "$log" && ok=0
    else grep -qE -- "$pat" "$log" || ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then echo "ok   - $desc"; pass=$((pass + 1))
  else echo "FAIL - $desc (rc=$rc)"; printf '       %s\n' "$out"; sed 's/^/  log: /' "$log"; failed=$((failed + 1)); fi
}

# --- while the USB serial placeholder is present -------------------------
check fail "apply refuses while REPLACE_WITH_USB_SERIAL is set" '!talosctl' apply NODE=k3s-master
check fail "apply refuses for a worker too (hard refuse)" '!talosctl' apply NODE=k3s-worker-1
check fail "upgrade refuses while placeholder is set" '!talosctl' upgrade NODE=k3s-worker-1
out=$(make --no-print-directory -C "$tmp/w/talos" apply NODE=k3s-master 2>&1 || true)
if grep -q "REPLACE_WITH_USB_SERIAL" <<<"$out" && grep -q "lsblk -o NAME,SERIAL" <<<"$out"; then
  echo "ok   - refusal names the placeholder and how to fill it"; pass=$((pass + 1))
else echo "FAIL - refusal message unclear: $out"; failed=$((failed + 1)); fi
echo "machine: {match: REPLACE_WITH_USB_SERIAL}" > "$tmp/w/talos/_out/k3s-master.yaml"

# --- after Rock fills in the serial ---------------------------------------
sed -i 's/REPLACE_WITH_USB_SERIAL/S3R1AL-TEST/' "$tmp/w/talos/nodes/k3s-master.yaml"
check fail "apply refuses a stale rendered _out config that still has the placeholder" '!talosctl' apply NODE=k3s-master
echo "fake: k3s-master" > "$tmp/w/talos/_out/k3s-master.yaml"
check ok "apply runs once the serial is set" 'talosctl .*apply-config.*(-n|--nodes) 192\.168\.7\.15.*_out/k3s-master\.yaml' apply NODE=k3s-master
check ok "apply INSECURE=1 uses --insecure (maintenance mode)" 'apply-config.*--insecure' apply NODE=k3s-worker-2 INSECURE=1
check fail "apply requires NODE" '!talosctl' apply
check fail "apply rejects an unknown NODE" '!talosctl' apply NODE=bogus
check ok "upgrade worker uses the rpi4 installer tag@digest" \
  'talosctl .*upgrade.*192\.168\.7\.11.*metal-installer/59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91:v1\.14\.4@sha256:9dfd9dcd' upgrade NODE=k3s-worker-1
check ok "upgrade master uses the rpi5 installer tag@digest" \
  'talosctl .*upgrade.*192\.168\.7\.15.*metal-installer/79b25588d06fc7d187c5b1b6c3321354b156cfc58c8a2c723ab6b398aea2c381:v1\.14\.4@sha256:6156077e' upgrade NODE=k3s-master

# --- cilium-bootstrap verifies the chart digest before installing ----------
export FAKE_CHART_CONTENT=tampered
check fail "cilium-bootstrap refuses a chart with the wrong sha256" '!helm (install|upgrade)' cilium-bootstrap
# Point versions.env at the sha of what the fake pull produces.
export FAKE_CHART_CONTENT=good
good=$(printf good | sha256sum | cut -d' ' -f1)
sed -i "s/^CILIUM_CHART_SHA256=.*/CILIUM_CHART_SHA256=$good/" "$tmp/w/talos/versions.env"
check ok "cilium-bootstrap installs the verified local tgz" 'helm install cilium .*_out/cilium-1\.20\.4\.tgz.*-n kube-system' cilium-bootstrap

echo "talos Makefile tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
