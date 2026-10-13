# Generic deploy recipes, imported by the root justfile.
#
# An app is apps/<app>/: its values in secretspec.toml (from pass), the
# config its targets share in files/, and the targets themselves:
# systemd (installer.sh, plus systemd/files/ for units), kube/kubectl and
# compose.
#
# A deploy renders files/ in a temp dir, never in the repo: every file goes
# through envsubst limited to the app's secretspec keys (so `$host` in an
# nginx site stays), then *.b64 files are base64-decoded, so binary files
# (e.g. a pfx) can live in pass as text.

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
	# gpg-agent intermittently fails decryptions that run concurrently, and
	# secretspec decrypts a spec's keys in parallel: retry a failed call.
	# Only for idempotent commands (they may run again).
	retry() {
		local i
		for i in 1 2 3; do
			if "$@"; then return 0; fi
			echo "{{ app }}: reading secrets failed, retrying ($i/3)" >&2
			sleep 2
		done
		return 1
	}
	# Print the app's secretspec values as KEY=value lines (a .env file).
	dotenv() { retry secretspec -f "$spec" export --format dotenv; }
	# Build envsubst's variable list from KEY=value lines, so `$` in
	# manifests and templates is only touched for known names.
	subst_vars() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*' | sed 's/.*/${&}/' | tr '\n' ' '; }
	vars=''
	# Render a directory of staged files in place and write the .env: the
	# secretspec values when the app has a spec, else apps/<app>/.env.
	# Sets $vars to the envsubst variable list when secretspec is used.
	# Usage: render <files-dir> <env-file>
	render() {
		if test -f "$spec"; then
			dotenv > "$2"
			vars="$(subst_vars < "$2")"
			# Substitute the spec's keys in every staged file, in subdirectories
			# too, all in one secretspec call. Written back through the same
			# file, so modes stay; the .env is the values themselves.
			local files=()
			mapfile -d '' files < <(find "$1" -type f ! -name .env -print0)
			if ((${#files[@]})); then
				retry with_secrets bash -c '
					set -e; vars=$1; shift
					for f; do envsubst "$vars" < "$f" > "$f.render"; cat "$f.render" > "$f"; rm "$f.render"; done
				' _ "$vars" "${files[@]}"
			fi
		elif test -f "$dir/.env"; then
			cp "$dir/.env" "$2"
		fi
		# Decoded files are usually keys: readable by the owner only.
		local b
		while IFS= read -r -d '' b; do
			(umask 077; base64 -d < "$b" > "${b%.b64}")
			rm "$b"
		done < <(find "$1" -name '*.b64' -print0)
	}
	case "{{ target }}" in
	kube)
		test -f "$dir/kube/kubectl/kustomization.yaml" || fail "no kube/kubectl target"
		# Build from a temp copy of the app, so the rendered files and the .env
		# never land in the repo. .helm is linked for helmGlobals.chartHome
		# (../../../../.helm).
		box="$(mktemp -d)"
		trap 'rm -rf "$box"' EXIT
		mkdir -p .helm "$box/apps"
		ln -s "$PWD/.helm" "$box/.helm"
		cp -R "$dir" "$box/apps/"
		app="$box/apps/{{ app }}"
		mkdir -p "$app/files"
		render "$app/files" "$app/.env"
		# --load-restrictor lets generators read ../../.env and ../../files.
		kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$app/kube/kubectl" \
			| if test -n "$vars"; then with_secrets envsubst "$vars"; else cat; fi \
			| kubectl apply -f -
		;;
	compose)
		test -f "$dir/compose/compose.yaml" || fail "no compose target"
		# From a temp copy too: compose.yaml mounts the rendered ../files.
		box="$(mktemp -d)"
		trap 'rm -rf "$box"' EXIT
		cp -R "$dir" "$box/"
		app="$box/{{ app }}"
		mkdir -p "$app/files"
		render "$app/files" "$app/.env"
		with_secrets docker compose -f "$app/compose/compose.yaml" up
		;;
	systemd)
		test -f "$dir/systemd/installer.sh" || fail "no systemd target"
		test -n "{{ host }}" || fail "systemd needs a host"
		# files/ is staged and rendered in a temp dir, so rendered secrets never
		# touch the repo, and sent to /tmp/<app> with systemd/files/. Units are
		# copied after rendering, as they are: systemd expands their ${VAR}
		# from the EnvironmentFile, and a rendered unit would hold the secret.
		stage="$(mktemp -d)"
		trap 'rm -rf "$stage"' EXIT
		test ! -d "$dir/files" || cp -R "$dir/files/." "$stage/"
		render "$stage" "$stage/.env"
		test ! -d "$dir/systemd/files" || cp -R "$dir/systemd/files/." "$stage/"
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
		for n in kube/kubectl compose systemd; do
			test -d "$d/$n" && t+=("$n")
		done
		printf '%-16s %s\n' "$(basename "$d")" "${t[*]:-}"
	done

# kube/kubectl reads files that only exist at deploy time, so it's built from
# a temp copy of the app with stand-ins: an empty .env, and an empty file for
# each rendered files/<name> the kustomization references.
# The Flux cluster is checked by `just kube check`.
[doc('Build every apps/*/kube/kubectl entrypoint')]
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
		: > "$app/.env"
		for f in $(grep -oE '\.\./\.\./files/[A-Za-z0-9._-]+' "$app/kube/kubectl/kustomization.yaml"); do
			f="${f#../../}"
			mkdir -p "$(dirname "$app/$f")"
			test -e "$app/$f" || : > "$app/$f"
		done
		echo "$app/kube/kubectl"
	}
	for e in apps/*/kube/kubectl; do
		test -f "$e/kustomization.yaml" || continue
		a="${e#apps/}"
		b="$(stand_in "${a%%/*}")"
		if kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$b" >/dev/null 2>&1; then
			echo "ok    $e"
		else
			echo "FAIL  $e"; rc=1
		fi
	done
	exit $rc
