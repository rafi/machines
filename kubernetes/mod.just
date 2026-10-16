# Kubernetes (k3s + Flux). Pushing to git is the deploy; these recipes cover
# what git can't hold (secrets from pass) and local checks.
#
# Layout: apps/<namespace>/<app>/{ks.yaml, app/, secrets/}. Flux applies app/;
# secrets/ holds Secret templates and the secretspec.toml naming their keys.

set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

# Recipes run in kubernetes/. SECRETSPEC_PROVIDER_CONCURRENCY comes from the
# root justfile.

# The node's k3s release; `check` renders and validates against it.
k3s_version := 'v1.37.1+k3s1'

# flate as the cluster sees it: its Kubernetes version, and the Gateway API
# (offline, app-template would render HTTPRoutes as v1alpha2).
flate_flags := '--path . --kube-version ' + k3s_version + ' --api-versions gateway.networking.k8s.io/v1/HTTPRoute --no-progress'

# Core kinds from kubeconform's default; CRDs from the schemas the manifests'
# headers use (home-operations, then datreeio's catalog for traefik.io).
kubeconform_schemas := "-schema-location default -schema-location 'https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'"

_default:
	@just --list kube --unsorted

# Render k3s/config.yaml from pass and run k3s/install.sh on the node.
# Keep `k3s_version` equal to the one in kubernetes/README.md.
[doc('Install k3s on the node over SSH, config from pass: just kube k3s-install <host> [version]')]
[group('bootstrap')]
[script]
k3s-install host version=k3s_version:
	spec=k3s/secretspec.toml
	vars=$(grep -oE '^[A-Z][A-Z0-9_]* =' "$spec" | tr -d ' =' | sed 's/.*/${&}/' | tr '\n' ' ')
	umask 077
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	secretspec run -f "$spec" -- envsubst "$vars" < k3s/config.yaml > "$tmp/config.yaml"
	cp k3s/install.sh "$tmp/"
	rsync -rtz --chmod=D700,F600 "$tmp/" "{{ host }}:/tmp/k3s-install/"
	ssh -t {{ host }} sh /tmp/k3s-install/install.sh {{ version }}

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

# flate reads Secrets from any file under --path: write a placeholder
# cluster-settings for every namespace of the tree in `dir` (gitignored).
# A key without a placeholder here fails, unless `strict` is false (a diff's
# base may hold keys since removed).
[private]
[script]
_settings dir='.' strict='true':
	export SECRET_DOMAIN=example.com SEERR_HOSTNAME=seerr.example.net \
		RATHOLE_SERVER_SERVICES_SLSKD_PORT=50000 FLUX_TELEGRAM_CHAT_ID=0
	subst='envsubst(nu, ne)'; [[ {{ strict }} == true ]] || subst=envsubst
	for d in '{{ dir }}'/apps/*/; do
		ns=$(basename "$d") yq "(.. | select(tag == \"!!str\")) |= $subst | .metadata.namespace = strenv(ns)" \
			'{{ dir }}/secrets/cluster-settings.yaml'
	done > '{{ dir }}/flate-cluster-settings.yaml'

# Render every Kustomization and HelmRelease offline, as Flux would: charts
# pulled and their values checked against the chart's schema and kubeVersion.
# Then validate what Flux would apply against the Kubernetes and CRD schemas.
[doc('Render the cluster offline with flate and validate it with kubeconform; Alert sources')]
[group('check')]
[script('bash', '-uo', 'pipefail')]
check: _settings
	rc=0
	flate test all {{ flate_flags }} || rc=1
	# A schema already downloaded isn't fetched again (CI restores this
	# directory): a CRD schema host being down doesn't fail the run.
	cache=${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform
	mkdir -p "$cache"
	flate build all {{ flate_flags }} 2>/dev/null \
		| kubeconform -strict -summary -cache "$cache" -kubernetes-version {{ replace_regex(k3s_version, '^v([^+]+).*', '$1') }} {{ kubeconform_schemas }} \
		|| rc=1
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

# Print what Flux would apply: just kube render hr <name>, or all.
[group('check')]
render +args: _settings
	flate build {{ args }} {{ flate_flags }}

# Diff what Flux would apply against `base`, rendered the same way; extra
# flags go to flate (e.g. --output github).
[group('check')]
[script]
diff base='origin/master' *flags: _settings
	tmp=$(mktemp -d)
	trap 'git worktree remove --force "$tmp"' EXIT
	git worktree add -q --detach "$tmp" '{{ base }}'
	'{{ just_executable() }}' -f '{{ source_file() }}' _settings "$tmp/kubernetes" false
	flate diff all --path-orig "$tmp/kubernetes" {{ flate_flags }} {{ flags }}

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

# Gateways and HTTPRoutes, with whether each is accepted.
[group('flux')]
routes:
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
