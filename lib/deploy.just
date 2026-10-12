# Generic deploy recipes, imported by the root justfile.
#
# A target is a directory inside apps/<app>/: kube/kubectl, compose, systemd.
#
# Values come from apps/<app>/secretspec.toml (when present). Files that
# belong to the deployment, not to this repo (keys, certificates, nginx
# configs), come from the paths in $EXTRA_FILES (systemd only): a
# colon-separated list of directories (copied flat) and files. An app
# without secretspec.toml can get its .env this way too; it takes
# precedence over apps/<app>/.env.

# Deploy: `just deploy kube|compose|systemd <app> [host] [VAR=val...]`
deploy target app host='' *vars:
	#!/usr/bin/env bash
	set -euo pipefail
	# Extra VAR=val args go to the remote installer (systemd), e.g.
	# USE_PACKAGE_MANAGER=1.
	dir="apps/{{ app }}"
	spec="$dir/secretspec.toml"
	fail() { echo "{{ app }}: $1" >&2; exit 1; }
	# Run a command with the app's secretspec values in its environment.
	with_secrets() {
		if test -f "$spec"; then secretspec -f "$spec" run -- "$@"; else "$@"; fi
	}
	# Print the app's secretspec values as KEY=value lines (a .env file).
	dotenv() { secretspec -f "$spec" export --format dotenv; }
	# Build envsubst's variable list from KEY=value lines, so `$` in
	# manifests and templates is only touched for known names.
	subst_vars() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*' | sed 's/.*/${&}/' | tr '\n' ' '; }
	case "{{ target }}" in
	kube)
		# --load-restrictor lets the secretGenerator read ../../.env.
		entry="$dir/kube/kubectl"
		test -f "$entry/kustomization.yaml" || fail "no kube/kubectl target"
		build() {
			kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$entry"
		}
		if test -f "$spec"; then
			# .env exists only while applying. Never overwrite one you made.
			test ! -e "$dir/.env" || fail "$dir/.env exists; values come from secretspec.toml, move it away"
			trap 'rm -f "$dir/.env"' EXIT
			dotenv > "$dir/.env"
			vars="$(subst_vars < "$dir/.env")"
			build | with_secrets envsubst "$vars" | kubectl apply -f -
		else
			build | kubectl apply -f -
		fi
		;;
	compose)
		test -f "$dir/compose/compose.yaml" || fail "no compose target"
		with_secrets docker compose -f "$dir/compose/compose.yaml" up
		;;
	systemd)
		test -f "$dir/systemd/installer.sh" || fail "no systemd target"
		test -n "{{ host }}" || fail "systemd needs a host"
		# Everything the installer needs is staged in a temp dir, so rendered
		# secrets never touch the repo, and sent flat to /tmp/<app>.
		stage="$(mktemp -d)"
		trap 'rm -rf "$stage"' EXIT
		test ! -d "$dir/systemd/files" || cp -R "$dir/systemd/files/." "$stage/"
		if test -n "${EXTRA_FILES:-}"; then
			IFS=: read -ra extra <<< "$EXTRA_FILES"
			for p in "${extra[@]}"; do
				if test -d "$p"; then cp -R "$p/." "$stage/"; else cp "$p" "$stage/"; fi
			done
		fi
		rm -f "$stage/.gitignore"
		if test -f "$spec"; then
			dotenv > "$stage/.env"
			vars="$(subst_vars < "$stage/.env")"
			# Render *.example.* templates to their real names.
			for t in "$stage"/*.example.*; do
				test -e "$t" || continue
				with_secrets envsubst "$vars" < "$t" > "${t/.example./.}"
				rm "$t"
			done
		elif test -f "$dir/.env" && test ! -e "$stage/.env"; then
			cp "$dir/.env" "$stage/.env"
		fi
		rsync -hlrtWxz "$stage/" "{{ host }}:/tmp/{{ app }}/"
		cat lib/functions.sh "$dir/systemd/installer.sh" \
			| ssh "{{ host }}" '{{ vars }}' sh -s
		;;
	*)
		fail "unknown target '{{ target }}' (kube, compose, systemd)"
		;;
	esac

# Show which targets each app supports.
list:
	#!/usr/bin/env bash
	set -euo pipefail
	for d in apps/*/; do
		t=()
		for n in kube/flux kube/kubectl compose systemd; do
			test -d "$d/$n" && t+=("$n")
		done
		printf '%-16s %s\n' "$(basename "$d")" "${t[*]:-}"
	done

# Build every kube/flux and kube/kubectl entrypoint.
check:
	#!/usr/bin/env bash
	set -uo pipefail
	rc=0
	for e in apps/*/kube/flux apps/*/kube/kubectl; do
		test -f "$e/kustomization.yaml" || continue
		if kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$e" >/dev/null 2>&1; then
			echo "ok    $e"
		else
			echo "FAIL  $e"; rc=1
		fi
	done
	exit $rc
