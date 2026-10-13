# Kubernetes (k3s + Flux). Pushing to git is the deploy; these recipes cover
# what git can't hold (secrets from pass) and local checks.
#
# Layout: apps/<namespace>/<app>/{ks.yaml, app/, secrets/}. Flux applies app/;
# secrets/ holds Secret templates and the secretspec.toml naming their keys.

set shell := ['bash', '-euo', 'pipefail', '-c']

dir := source_directory()

_default:
	@just --list kube --unsorted

# Install k3s on this node; its config holds the cluster token from pass.
[group('bootstrap')]
k3s-install:
	sudo mkdir -p /etc/rancher/k3s
	printf 'token: %s\n' "$(pass show secretspec/machines/default/K3S_TOKEN)" \
		| sudo install -m 600 /dev/stdin /etc/rancher/k3s/config.yaml
	curl -sfL https://get.k3s.io | sh -

# Write the kubeconfig from pass to a file.
[group('bootstrap')]
kubeconfig out="~/.kube/cluster.yaml":
	umask 077; pass show secretspec/machines/default/K3S_KUBECONFIG > {{ out }}
	@echo "export KUBECONFIG={{ out }}"

# --force-conflicts: on a running cluster these objects are owned by Flux's
# kustomize-controller; this takes them over until Flux syncs them again.
[doc('Install or re-point Flux from flux/flux-system; it then syncs this repo')]
[group('bootstrap')]
bootstrap:
	kubectl apply --server-side --force-conflicts -k {{ dir }}/flux/flux-system

# Creates cluster-settings in every app namespace, plus the secrets/*.yaml of
# the named apps (all apps when none are named).
[doc('Create Secrets from pass: cluster-settings + apps/<ns>/<app>/secrets/')]
[group('secrets')]
secrets *apps:
	#!/usr/bin/env bash
	set -euo pipefail
	# Print the Secret templates in a secrets/ dir with ${KEY}s filled from
	# pass. yq substitutes after parsing, so any value stays a valid string.
	# Only the keys of secretspec.toml are in yq's environment: any other
	# $VAR, or an empty value, fails instead of being filled in.
	render() {
		local keys
		keys=$(grep -oE '^[A-Z][A-Z0-9_]* =' "$1/secretspec.toml" | tr -d ' =' | tr '\n' ' ')
		secretspec run -f "$1/secretspec.toml" -- bash -c '
			yq=$(command -v yq); keep=" $1 "; shift
			for v in $(compgen -e); do [[ $keep == *" $v "* ]] || unset "$v" 2>/dev/null || true; done
			exec "$yq" "(.. | select(tag == \"!!str\")) |= envsubst(nu, ne)" "$@"
		' _ "$keys" "$1"/*.yaml
	}
	apply() { kubectl apply -n "$1" -f -; }
	cd "{{ dir }}"
	settings=$(render secrets)
	for d in apps/*/; do
		ns=$(basename "$d")
		kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
		apply "$ns" <<< "$settings"
	done
	for s in apps/*/*/secrets; do
		app=$(basename "$(dirname "$s")")
		if test -n "{{ apps }}" && [[ " {{ apps }} " != *" $app "* ]]; then continue; fi
		ns=$(basename "$(dirname "$(dirname "$s")")")
		render "$s" | apply "$ns"
	done
	echo "Pods read Secrets at start: kubectl rollout restart the apps whose values changed."

# Build every Flux entrypoint and kustomization, as Flux would.
[group('check')]
check:
	#!/usr/bin/env bash
	set -uo pipefail
	cd "{{ dir }}"
	rc=0
	for d in flux apps/* apps/*/*/app; do
		if kustomize build "$d" >/dev/null 2>&1; then echo "ok    $d"
		else echo "FAIL  $d"; rc=1; fi
	done
	exit $rc

# Force Flux to pull and apply now.
[group('flux')]
sync:
	flux reconcile source git flux-system
	flux reconcile kustomization cluster-apps --with-source

# Everything Flux manages.
[group('flux')]
status:
	flux get all -A

# Only what is not Ready.
[group('flux')]
failing:
	flux get all -A --status-selector ready=false
	kubectl get gateway,httproute -A

[group('flux')]
events:
	flux events --all-namespaces --watch

[group('flux')]
logs:
	flux logs --all-namespaces --level=error

[group('flux')]
tree:
	flux tree ks cluster-apps
