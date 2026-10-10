# Generic deploy recipes, imported by the root justfile.
#
# A target is a directory inside apps/<app>/: kube/kubectl, compose, systemd.
# `.env` lives at the app root and is never committed.

# Deploy: `just deploy kube|compose|systemd <app> [host] [VAR=val...]`
deploy target app host='' *vars:
	#!/usr/bin/env bash
	set -euo pipefail
	dir="apps/{{ app }}"
	# Extra VAR=val args go to the remote installer (systemd), e.g.
	# USE_PACKAGE_MANAGER=1.
	fail() { echo "{{ app }}: $1" >&2; exit 1; }
	case "{{ target }}" in
	kube)
		# --load-restrictor lets the secretGenerator read ../../.env.
		entry="$dir/kube/kubectl"
		test -f "$entry/kustomization.yaml" || fail "no kube/kubectl target"
		kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$entry" \
			| kubectl apply -f -
		;;
	compose)
		test -f "$dir/compose/compose.yaml" || fail "no compose target"
		docker compose -f "$dir/compose/compose.yaml" up
		;;
	systemd)
		test -f "$dir/systemd/installer.sh" || fail "no systemd target"
		test -n "{{ host }}" || fail "systemd needs a host"
		# Flat copy of systemd/files, systemd/tls and .env into /tmp/<app>.
		srcs=()
		for d in "$dir/systemd/files/" "$dir/systemd/tls/"; do
			test -d "$d" && srcs+=("$d")
		done
		for s in "${srcs[@]}"; do
			rsync -hlrtWxz --exclude .gitignore "$s" "{{ host }}:/tmp/{{ app }}/"
		done
		rsync -hlrtWxz --ignore-missing-args "$dir/.env" "{{ host }}:/tmp/{{ app }}/"
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
