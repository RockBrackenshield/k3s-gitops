# Talos workflow for the hermnet cluster. Run from this directory: make -C talos <target>
# See README.md. Rendered configs in _out/ contain plaintext secrets (gitignored,
# blocked by scripts/check-sops.sh).
include versions.env

SHELL       := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
.PHONY: help schematic-check images gen validate render-test placeholder-check node-check \
        apply bootstrap kubeconfig upgrade cilium-bootstrap etcd-backup

FACTORY  := https://factory.talos.dev
CLUSTER  := $(CLUSTER_NAME)
CP_IP    := 192.168.7.15
ENDPOINT := https://$(CP_IP):6443
NODES    := k3s-master k3s-worker-1 k3s-worker-2
OUT      ?= _out
export TALOSCONFIG := $(CURDIR)/_out/talosconfig

# Per-node IP, board and installer (Pi 5 control plane, Pi 4 workers).
IP_k3s-master      := 192.168.7.15
IP_k3s-worker-1    := 192.168.7.11
IP_k3s-worker-2    := 192.168.7.13
BOARD_k3s-master   := rpi5
BOARD_k3s-worker-1 := rpi4
BOARD_k3s-worker-2 := rpi4
INSTALLER_rpi4 := factory.talos.dev/metal-installer/$(SCHEMATIC_RPI4):$(TALOS_VERSION)@$(INSTALLER_DIGEST_RPI4)
INSTALLER_rpi5 := factory.talos.dev/metal-installer/$(SCHEMATIC_RPI5):$(TALOS_VERSION)@$(INSTALLER_DIGEST_RPI5)

# Inputs for gen; render-test overrides them with throwaway values.
SECRETS  ?= <(sops -d secrets.sops.yaml)
NODE_SRC ?= nodes/$$n.yaml
TS_SRC   ?= <(sops -d nodes/$$n.tailscale.sops.yaml)

PLACEHOLDER := REPLACE_WITH_USB_SERIAL
DUMMY_SERIAL := CI-DUMMY-SERIAL-NOT-A-DISK

GEN := talosctl gen config $(CLUSTER) $(ENDPOINT) --talos-version $(basename $(TALOS_VERSION)) \
  --kubernetes-version $(KUBERNETES_VERSION) \
  --config-patch @patches/common.yaml --config-patch-control-plane @patches/controlplane.yaml

help:  ## list targets
	@awk -F':.*## ' '/^[a-z-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

schematic-check:  ## read-only: ID == sha256(canonical file) and the Factory knows it
	@test "$$(sha256sum < schematics/rpi4.yaml | cut -d' ' -f1)" = "$(SCHEMATIC_RPI4)" || { echo "rpi4 schematic sha != SCHEMATIC_RPI4" >&2; exit 1; }
	@test "$$(sha256sum < schematics/rpi5.yaml | cut -d' ' -f1)" = "$(SCHEMATIC_RPI5)" || { echo "rpi5 schematic sha != SCHEMATIC_RPI5" >&2; exit 1; }
	curl -sfo /dev/null $(FACTORY)/schematics/$(SCHEMATIC_RPI4)
	curl -sfo /dev/null $(FACTORY)/schematics/$(SCHEMATIC_RPI5)
	@echo "schematics OK"

images:  ## print SD-card image URLs and installer refs
	@echo "rpi5 (k3s-master) SD image: $(FACTORY)/image/$(SCHEMATIC_RPI5)/$(TALOS_VERSION)/metal-arm64.raw.xz"
	@echo "rpi4 (workers)    SD image: $(FACTORY)/image/$(SCHEMATIC_RPI4)/$(TALOS_VERSION)/metal-arm64.raw.xz"
	@echo "rpi5 installer: $(INSTALLER_rpi5)"
	@echo "rpi4 installer: $(INSTALLER_rpi4)"

gen:  ## render _out/<node>.yaml + talosconfig (decrypts secrets with sops)
	mkdir -p $(OUT)
	$(GEN) --with-secrets $(SECRETS) -o $(OUT) --force
	for n in $(NODES); do \
	  case $$n in k3s-master) base=controlplane board=rpi5;; *) base=worker board=rpi4;; esac; \
	  talosctl machineconfig patch $(OUT)/$$base.yaml -p @patches/$$board.yaml \
	    -p @$(NODE_SRC) -p @$(TS_SRC) -o $(OUT)/$$n.yaml; \
	done
	talosctl --talosconfig $(OUT)/talosconfig config endpoint $(CP_IP)
	talosctl --talosconfig $(OUT)/talosconfig config node $(CP_IP)

validate:  ## talosctl validate --mode metal --strict on all rendered node configs
	for n in $(NODES); do talosctl validate --mode metal --strict -c $(OUT)/$$n.yaml; done

render-test:  ## CI/offline: render + validate with THROWAWAY secrets and a dummy serial (nothing kept)
	@if grep -q '$(PLACEHOLDER)' nodes/*.yaml; then \
	  msg="talos/nodes still contain $(PLACEHOLDER): validating with a dummy serial; set the real USB serial before 'make apply'"; \
	  if [ -n "$${GITHUB_ACTIONS:-}" ]; then echo "::warning file=talos/nodes/k3s-master.yaml::$$msg"; else echo "WARNING: $$msg" >&2; fi; \
	fi
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	talosctl gen secrets -o "$$tmp/secrets.yaml"; \
	$(MAKE) --no-print-directory gen validate OUT="$$tmp" SECRETS="$$tmp/secrets.yaml" \
	  NODE_SRC='<(sed s/$(PLACEHOLDER)/$(DUMMY_SERIAL)/ nodes/$$$$n.yaml)' \
	  TS_SRC='<(sed s/\<host\>/$$$$n/ tailscale.example.yaml)'

placeholder-check:  ## fail while the USB serial placeholder is still in the configs
	@if grep -l '$(PLACEHOLDER)' nodes/*.yaml $(wildcard _out/k3s-*.yaml) 2>/dev/null; then \
	  echo "REFUSING: the files above still contain $(PLACEHOLDER)." >&2; \
	  echo "Fill in the USB disk serial in nodes/k3s-master.yaml (lsblk -o NAME,SERIAL;" >&2; \
	  echo "cross-check with talosctl get disks), then run 'make gen' again." >&2; \
	  exit 1; \
	fi

node-check:
	@test -n "$(NODE)" || { echo "set NODE=<$(NODES)>" >&2; exit 1; }
	@test -n "$(IP_$(NODE))" || { echo "unknown NODE=$(NODE); use one of: $(NODES)" >&2; exit 1; }

apply: placeholder-check node-check  ## apply _out/$(NODE).yaml (INSECURE=1 for maintenance mode)
	talosctl apply-config $(if $(INSECURE),--insecure) -n $(IP_$(NODE)) --file $(OUT)/$(NODE).yaml

bootstrap:  ## once: bootstrap etcd on k3s-master
	talosctl bootstrap -n $(CP_IP) -e $(CP_IP)

kubeconfig:  ## write _out/kubeconfig
	talosctl kubeconfig $(OUT)/kubeconfig -n $(CP_IP) -e $(CP_IP) --force

upgrade: placeholder-check node-check  ## upgrade $(NODE) to TALOS_VERSION (installer tag@digest)
	talosctl upgrade -n $(IP_$(NODE)) --image $(INSTALLER_$(BOARD_$(NODE)))

cilium-bootstrap:  ## once, right after bootstrap: install pinned+verified Cilium chart (Argo adopts it later)
	# Gateway API CRDs are NOT applied here: Argo's gateway-api-crds app owns them (wave -4).
	mkdir -p $(OUT)
	rm -f $(OUT)/cilium-$(CILIUM_VERSION).tgz
	helm pull cilium --repo https://helm.cilium.io --version $(CILIUM_VERSION) -d $(OUT)
	echo "$(CILIUM_CHART_SHA256)  $(OUT)/cilium-$(CILIUM_VERSION).tgz" | sha256sum -c -
	helm install cilium $(OUT)/cilium-$(CILIUM_VERSION).tgz -n kube-system \
	  -f ../infrastructure/cilium/values.yaml --kubeconfig $(OUT)/kubeconfig

etcd-backup:  ## etcd snapshot to _out/etcd-<date>.snapshot
	talosctl -n $(CP_IP) etcd snapshot $(OUT)/etcd-$$(date +%F).snapshot
