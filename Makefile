# Cluster bootstrap for hermnet (Talos). Node-level targets live in talos/Makefile.
# All kubectl calls use the kubeconfig written by `make -C talos kubeconfig`.
SHELL       := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
.PHONY: help bootstrap-argocd restore-sealed-secrets-key bootstrap-root talos-up day0 restore

export KUBECONFIG ?= $(CURDIR)/talos/_out/kubeconfig
KUBECTL := kubectl
# Backed-up Sealed Secrets master key, kept OUTSIDE the repo (docs/sealed-secrets-backup.md).
KEY ?=

help:  ## list targets
	@awk -F':.*## ' '/^[a-z0-9-]+:.*## / {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap-argocd:  ## install pinned Argo CD (bootstrap/argocd) and wait for it
	$(KUBECTL) apply --server-side --force-conflicts -k bootstrap/argocd
	$(KUBECTL) -n argocd rollout status deployment/argocd-server --timeout=300s
	$(KUBECTL) -n argocd rollout status deployment/argocd-repo-server --timeout=300s

restore-sealed-secrets-key:  ## KEY=/path/outside/repo.yaml: restore the Sealed Secrets master key (before Argo syncs sealed-secrets)
	@test -n "$(KEY)" || { echo "set KEY=/path/to/sealed-secrets-master-key.yaml (outside the repo)" >&2; exit 1; }
	@test -f "$(KEY)" || { echo "KEY file not found: $(KEY)" >&2; exit 1; }
	@case "$$(realpath "$(KEY)")" in "$(CURDIR)"/*) echo "REFUSING: KEY must live outside the repo" >&2; exit 1;; esac
	@grep -q 'sealedsecrets.bitnami.com/sealed-secrets-key' "$(KEY)" || { echo "$(KEY) has no sealed-secrets-key label; is it the exported key?" >&2; exit 1; }
	$(KUBECTL) create namespace sealed-secrets --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -n sealed-secrets -f "$(KEY)"

bootstrap-root:  ## apply the App of Apps root application
	$(KUBECTL) apply -f bootstrap/root-app.yaml

talos-up:  # gen + validate + apply all nodes (maintenance mode) + bootstrap + kubeconfig + Cilium
	$(MAKE) -C talos gen validate
	for n in k3s-master k3s-worker-1 k3s-worker-2; do $(MAKE) -C talos apply NODE=$$n INSECURE=1; done
	echo "waiting for k3s-master to install and reboot..."
	for i in $$(seq 1 60); do talosctl --talosconfig talos/_out/talosconfig -n 192.168.7.15 version >/dev/null 2>&1 && break; sleep 10; done
	$(MAKE) -C talos bootstrap
	for i in $$(seq 1 60); do $(MAKE) -s -C talos kubeconfig >/dev/null 2>&1 && $(KUBECTL) get --raw=/readyz >/dev/null 2>&1 && break; sleep 10; done
	$(MAKE) -C talos cilium-bootstrap
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=600s

day0:  ## fresh cluster, NEW Sealed Secrets key: talos-up + Argo CD + root app
	$(MAKE) talos-up bootstrap-argocd bootstrap-root
	echo "Fresh Sealed Secrets key: export and back it up now (docs/sealed-secrets-backup.md)."

restore:  ## rebuild with the EXISTING Sealed Secrets key: KEY=/path/outside/repo.yaml
	@test -n "$(KEY)" || { echo "restore needs KEY=/path/to/sealed-secrets-master-key.yaml" >&2; exit 1; }
	$(MAKE) talos-up bootstrap-argocd restore-sealed-secrets-key bootstrap-root KEY="$(KEY)"
	echo "Next: restore volumes per docs/runbook-restore.md."
