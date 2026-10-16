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

# Render k3s/config.yaml from pass and run k3s/install.sh on the node.
# Keep `version` equal to the one in kubernetes/README.md.
[doc('Install k3s on the node over SSH, config from pass: just kube k3s-install <host> [version]')]
[group('bootstrap')]
[script]
k3s-install host version='v1.37.1+k3s1':
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

# Replace lldap's key_seed. With lldap scaled down, a one-off pod runs lldap
# on its data (/opt/lldap, after a copy of users.db there) with the new seed
# and the force flags: it re-keys, resets the admin password from lldap-env,
# and exits. Then the seed goes to pass, `just kube secrets lldap` applies
# it, and lldap starts again. The seed reaches the cluster through a
# temporary Secret, never a command line. Users not in the bootstrap Secret
# must set new passwords.
[doc("Rotate lldap's key_seed in the cluster")]
[group('secrets')]
[confirm('Re-key lldap? Users outside the bootstrap Secret must set new passwords.')]
[script]
lldap-rekey:
	hr=apps/auth/lldap/app/helmrelease.yaml
	image="$(yq '.spec.values.controllers.lldap.containers.app.image | .repository + ":" + .tag' "$hr")"
	seed="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 40)"
	k() { kubectl -n auth "$@"; }
	# On any failure lldap comes back with its current seed.
	trap 'k delete pod/lldap-rekey secret/lldap-rekey --ignore-not-found >/dev/null; k scale deploy/lldap --replicas=1 >/dev/null' EXIT
	printf 'LLDAP_KEY_SEED=%s\nLLDAP_FORCE_UPDATE_PRIVATE_KEY=true\nLLDAP_FORCE_LDAP_USER_PASS_RESET=true\n' "$seed" \
		| k create secret generic lldap-rekey --from-env-file=/dev/stdin >/dev/null
	k scale deploy/lldap --replicas=0
	while [[ -n "$(k get pods -l app.kubernetes.io/name=lldap,app.kubernetes.io/controller=lldap -o name)" ]]; do sleep 2; done
	k apply -f - <<-EOF
		apiVersion: v1
		kind: Pod
		metadata:
		  name: lldap-rekey
		spec:
		  restartPolicy: Never
		  containers:
		    - name: lldap
		      image: $image
		      command: [sh, -c, 'cp -a /data/users.db "/data/users.db-\$(date +%Y%m%d%H%M%S)-rekey" && exec /docker-entrypoint.sh run --config-file /data/lldap_config.toml']
		      env:
		        - { name: LLDAP_DATABASE_URL, value: "sqlite:///data/users.db?mode=rwc" }
		      # The later source wins: lldap-rekey's seed over lldap-env's.
		      envFrom:
		        - secretRef: { name: lldap-env }
		        - secretRef: { name: lldap-rekey }
		      volumeMounts:
		        - { name: data, mountPath: /data }
		  volumes:
		    - name: data
		      hostPath: { path: /opt/lldap, type: Directory }
	EOF
	until phase="$(k get pod lldap-rekey -o jsonpath='{.status.phase}')" && [[ $phase == Succeeded || $phase == Failed ]]; do sleep 2; done
	out="$(k logs lldap-rekey)"
	printf '%s\n' "$out" | grep -iE 'private key|admin password|error|restart' || true
	# lldap exits with this message once the key and admin password are updated.
	grep -q 'Restart the server without' <<< "$out"
	printf '%s' "$seed" | pass insert -m -f secretspec/machines/default/LLDAP_KEY_SEED >/dev/null
	echo "LLDAP_KEY_SEED updated in pass"
	'{{ just_executable() }}' -d '{{ justfile_directory() }}' kube secrets lldap

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
