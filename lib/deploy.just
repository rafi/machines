# Generic deploy recipes, imported by the root justfile.
#
# A target is a directory inside apps/<app>/: kube/kubectl, compose, systemd.
#
# Values come from apps/<app>/secretspec.toml (when present). Files that
# belong to the deployment, not to this repo (keys, certificates, nginx
# configs), come from the paths in $EXTRA_FILES (systemd and kube): a
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
	vars=''
	# Stage what an installer or kustomization reads from systemd/files into
	# a temp dir: those files, the $EXTRA_FILES paths (copied flat), the
	# *.example.* templates rendered with the secretspec values, and the .env.
	# Sets $vars to the envsubst variable list when secretspec is used.
	# Usage: stage_files <files-dir> <env-file>
	stage_files() {
		test ! -d "$dir/systemd/files" || cp -R "$dir/systemd/files/." "$1/"
		if test -n "${EXTRA_FILES:-}"; then
			IFS=: read -ra extra <<< "$EXTRA_FILES"
			for p in "${extra[@]}"; do
				if test -d "$p"; then cp -R "$p/." "$1/"; else cp "$p" "$1/"; fi
			done
		fi
		rm -f "$1/.gitignore"
		if test -f "$spec"; then
			dotenv > "$2"
			vars="$(subst_vars < "$2")"
			for t in "$1"/*.example.*; do
				test -e "$t" || continue
				with_secrets envsubst "$vars" < "$t" > "${t/.example./.}"
				rm "$t"
			done
		elif test -f "$dir/.env" && test ! -e "$2"; then
			cp "$dir/.env" "$2"
		fi
	}
	case "{{ target }}" in
	kube)
		test -f "$dir/kube/kubectl/kustomization.yaml" || fail "no kube/kubectl target"
		# Build from a temp copy of the app, so the .env and the files staged
		# in systemd/files never land in the repo. .helm is linked for
		# helmGlobals.chartHome (../../../../.helm).
		box="$(mktemp -d)"
		trap 'rm -rf "$box"' EXIT
		mkdir -p .helm "$box/apps"
		ln -s "$PWD/.helm" "$box/.helm"
		cp -R "$dir" "$box/apps/"
		app="$box/apps/{{ app }}"
		mkdir -p "$app/systemd/files"
		stage_files "$app/systemd/files" "$app/.env"
		# --load-restrictor lets generators read ../../.env and ../../systemd/files.
		kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$app/kube/kubectl" \
			| if test -n "$vars"; then with_secrets envsubst "$vars"; else cat; fi \
			| kubectl apply -f -
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
		stage_files "$stage" "$stage/.env"
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

# kube/kubectl reads files that only exist at deploy time, so it's built from
# a temp copy of the app with stand-ins: .env.example as the .env, and an
# empty file for each missing systemd/files/<name> the kustomization references.
[doc('Build every kube/flux and kube/kubectl entrypoint')]
check:
	#!/usr/bin/env bash
	set -uo pipefail
	rc=0
	box="$(mktemp -d)"
	trap 'rm -rf "$box"' EXIT
	mkdir -p .helm "$box/apps"
	ln -s "$PWD/.helm" "$box/.helm"
	# Copy apps/<app> into the temp dir with stand-ins; print its entrypoint.
	stand_in() {
		cp -R "apps/$1" "$box/apps/"
		local app="$box/apps/$1" f
		test -e "$app/.env" || cp "$app/.env.example" "$app/.env" 2>/dev/null || : > "$app/.env"
		for f in $(grep -oE 'systemd/files/[A-Za-z0-9._-]+' "$app/kube/kubectl/kustomization.yaml"); do
			mkdir -p "$(dirname "$app/$f")"
			test -e "$app/$f" || : > "$app/$f"
		done
		echo "$app/kube/kubectl"
	}
	for e in apps/*/kube/flux apps/*/kube/kubectl; do
		test -f "$e/kustomization.yaml" || continue
		b="$e"
		case "$e" in
			*/kube/kubectl) a="${e#apps/}"; b="$(stand_in "${a%%/*}")" ;;
		esac
		if kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$b" >/dev/null 2>&1; then
			echo "ok    $e"
		else
			echo "FAIL  $e"; rc=1
		fi
	done
	exit $rc
