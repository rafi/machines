# Kubernetes (k3s + Flux). Pushing to git is the deploy; these recipes cover
# what git can't hold (secrets from pass) and local checks.
#
# Layout: apps/<namespace>/<app>/{ks.yaml, app/, secrets/}. Flux applies app/;
# secrets/ holds Secret templates and the secretspec.toml naming their keys.

set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

# Recipes run in kubernetes/. SECRETSPEC_PROVIDER_CONCURRENCY comes from the
# root justfile.

_default:
	@just --list kube --unsorted

# Install k3s on this node, with its config rendered from k3s/config.yaml
# and pass. `version` pins a release (e.g. v1.33.4+k3s1); empty takes stable.
# Reinstalling on the same host: run /usr/local/bin/k3s-uninstall.sh first.
[doc('Install k3s on this node, config from pass: just kube k3s-install [version]')]
[group('bootstrap')]
[script]
k3s-install version='':
	spec=k3s/secretspec.toml
	vars=$(grep -oE '^[A-Z][A-Z0-9_]* =' "$spec" | tr -d ' =' | sed 's/.*/${&}/' | tr '\n' ' ')
	sudo mkdir -p /etc/rancher/k3s
	secretspec run -f "$spec" -- envsubst "$vars" < k3s/config.yaml \
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
[script]
kubeconfig-save host:
	ip="$(pass show secretspec/machines/default/CLUSTER_NODE_IP)"
	ssh {{ host }} sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed "s#https://127.0.0.1:6443#https://$ip:6443#" \
		| pass insert -m -f secretspec/machines/default/K3S_KUBECONFIG >/dev/null
	echo "K3S_KUBECONFIG updated in pass; run: just kube kubeconfig"

# Push the Secrets, then install the Flux Operator and FluxInstance with helm
# from apps/flux-system; their HelmReleases then adopt both.
[doc('Secrets from pass, then the Flux Operator and FluxInstance; Flux then syncs this repo')]
[group('bootstrap')]
[script]
bootstrap: secrets
	cd apps/flux-system
	# --force-conflicts: re-runs override helm-controller's fields.
	for app in flux-operator flux-instance; do
		yq '.spec.values' "$app/app/helmrelease.yaml" \
			| helm upgrade --install "$app" "$(yq '.spec.url' "$app/app/ocirepository.yaml")" \
				--version "$(yq '.spec.ref.tag' "$app/app/ocirepository.yaml")" \
				--namespace flux-system --create-namespace --wait --force-conflicts --values -
	done
	kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m

# Creates cluster-settings in every app namespace, plus the secrets/*.yaml of
# the named apps (all apps when none are named).
[doc('Create Secrets from pass: cluster-settings + apps/<ns>/<app>/secrets/')]
[group('secrets')]
[script]
secrets *apps:
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
	# Server-side, under its own field manager: no last-applied annotation, and
	# it takes over Secrets first created by something else (e.g. old Flux).
	apply() { kubectl apply --server-side --field-manager=just-kube-secrets --force-conflicts -n "$1" -f -; }
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

# Run restic against the backup repository on B2, credentials from pass,
# e.g. `just kube restic snapshots` or `just kube restic restore latest --target /tmp/restore`.
[doc('restic on the B2 backup repository: just kube restic <args>')]
[group('backup')]
[positional-arguments]
[no-exit-message]
restic *args:
	secretspec run -f apps/backup/restic/secrets/secretspec.toml -- \
		sh -c 'AWS_ACCESS_KEY_ID="$B2_KEY_ID" AWS_SECRET_ACCESS_KEY="$B2_APPLICATION_KEY" exec restic "$@"' restic "$@"

# Build every Flux entrypoint and kustomization, as Flux would.
[group('check')]
[script('bash', '-uo', 'pipefail')]
check:
	rc=0
	for d in flux/cluster apps/* apps/*/*/app; do
		if kustomize build "$d" >/dev/null 2>&1; then echo "ok    $d"
		else echo "FAIL  $d"; rc=1; fi
	done
	# An Alert can't select all namespaces: each needs its own event sources.
	alert=apps/flux-system/alerts/app/alert.yaml
	for ns in apps/*/; do
		ns=$(basename "$ns")
		for kind in Kustomization HelmRelease OCIRepository; do
			yq -e ".spec.eventSources[] | select(.kind == \"$kind\" and .namespace == \"$ns\")" "$alert" >/dev/null 2>&1 \
				|| { echo "FAIL  $alert: no $kind events from $ns"; rc=1; }
		done
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

[doc('Flux web UI on http://localhost:9080 (port-forward)')]
[group('flux')]
ui:
	kubectl -n flux-system port-forward svc/flux-operator 9080:9080
