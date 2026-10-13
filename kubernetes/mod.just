# Kubernetes (k3s + Flux). Pushing to git is the deploy; these recipes cover
# what git can't hold (secrets from pass) and local checks.
#
# Layout: apps/<namespace>/<app>/{ks.yaml, app/, secrets/}. Flux applies app/;
# secrets/ holds Secret templates and the secretspec.toml naming their keys.

set shell := ['bash', '-euo', 'pipefail', '-c']

dir := source_directory()

_default:
	@just --list kube --unsorted

# Install k3s on this node, with its config rendered from k3s/config.yaml
# and pass. `version` pins a release (e.g. v1.33.4+k3s1); empty takes stable.
# Reinstalling on the same host: run /usr/local/bin/k3s-uninstall.sh first.
[doc('Install k3s on this node, config from pass: just kube k3s-install [version]')]
[group('bootstrap')]
k3s-install version='':
	#!/usr/bin/env bash
	set -euo pipefail
	spec="{{ dir }}/k3s/secretspec.toml"
	vars=$(grep -oE '^[A-Z][A-Z0-9_]* =' "$spec" | tr -d ' =' | sed 's/.*/${&}/' | tr '\n' ' ')
	sudo mkdir -p /etc/rancher/k3s
	secretspec run -f "$spec" -- envsubst "$vars" < "{{ dir }}/k3s/config.yaml" \
		| sudo install -m 600 /dev/stdin /etc/rancher/k3s/config.yaml
	curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='{{ version }}' sh -

# Write the kubeconfig from pass to a file.
[group('bootstrap')]
kubeconfig out="~/.kube/cluster.yaml":
	umask 077; pass show secretspec/machines/default/K3S_KUBECONFIG > {{ out }}
	@echo "export KUBECONFIG={{ out }}"

# Store a (re)installed node's kubeconfig in pass, pointed at the node's
# address instead of 127.0.0.1. `host` is the node's SSH destination.
[doc("Store a node's kubeconfig in pass: just kube kubeconfig-save <host>")]
[group('bootstrap')]
kubeconfig-save host:
	#!/usr/bin/env bash
	set -euo pipefail
	ip="$(pass show secretspec/machines/default/CLUSTER_NODE_IP)"
	ssh {{ host }} sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed "s#https://127.0.0.1:6443#https://$ip:6443#" \
		| pass insert -m -f secretspec/machines/default/K3S_KUBECONFIG >/dev/null
	echo "K3S_KUBECONFIG updated in pass; run: just kube kubeconfig"

# Install (or re-point) Flux. The repo is private, so the github-token Secret
# (a read-only GitHub token from pass) is created first.
# --force-conflicts: on a running cluster these objects are owned by Flux's
# kustomize-controller; this takes them over until Flux syncs them again.
[doc('Install or re-point Flux from flux/flux-system; it then syncs this repo')]
[group('bootstrap')]
bootstrap:
	kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
	pass show secretspec/machines/default/FLUX_GITHUB_TOKEN | tr -d '\n' \
		| kubectl create secret generic github-token -n flux-system \
			--from-literal=username=git --from-file=password=/dev/stdin --dry-run=client -o yaml \
		| kubectl apply --server-side --field-manager=just-kube-bootstrap --force-conflicts -f -
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
	# gpg-agent intermittently fails concurrent decryptions (secretspec runs
	# them in parallel), so a failed render is retried; output is only printed
	# once it succeeded.
	render() {
		local keys out i
		keys=$(grep -oE '^[A-Z][A-Z0-9_]* =' "$1/secretspec.toml" | tr -d ' =' | tr '\n' ' ')
		for i in 1 2 3; do
			if out=$(secretspec run -f "$1/secretspec.toml" -- bash -c '
				yq=$(command -v yq); keep=" $1 "; shift
				for v in $(compgen -e); do [[ $keep == *" $v "* ]] || unset "$v" 2>/dev/null || true; done
				exec "$yq" "(.. | select(tag == \"!!str\")) |= envsubst(nu, ne)" "$@"
			' _ "$keys" "$1"/*.yaml); then
				printf '%s\n' "$out"
				return 0
			fi
			echo "$1: reading secrets failed, retrying ($i/3)" >&2
			sleep 2
		done
		return 1
	}
	# Server-side, under its own field manager: no last-applied annotation, and
	# it takes over Secrets first created by something else (e.g. old Flux).
	apply() { kubectl apply --server-side --field-manager=just-kube-secrets --force-conflicts -n "$1" -f -; }
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
