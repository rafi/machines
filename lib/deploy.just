# App deploys, imported by the root justfile. An app is apps/<app>/: its keys
# in secretspec.toml, the config its targets share in files/, and up to three
# targets. lib/render.sh stages files/ with the app's values in a temp dir.
# See docs/architecture.md#apps-and-deploy-targets.

# VAR=val args after the host reach a systemd installer, e.g. USE_PACKAGE_MANAGER=1.
[doc('Deploy an app: just deploy systemd|kube|compose <app> [host] [VAR=val...]')]
deploy target app *args:
	@'{{ just_executable() }}' -f '{{ source_file() }}' -d '{{ justfile_directory() }}' _{{ target }} {{ app }} {{ args }}

# Units in systemd/files are sent unrendered: systemd expands their ${VAR}
# from the installed .env, and a rendered unit would hold the secret.
[private]
_systemd app host *vars:
	#!/usr/bin/env bash
	set -euo pipefail
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	stage {{ app }} "$tmp" "$tmp/.env"
	[ ! -d apps/{{ app }}/systemd/files ] || cp -R apps/{{ app }}/systemd/files/. "$tmp/"
	rsync -hlrtWxz "$tmp/" {{ host }}:/tmp/{{ app }}/
	cat lib/functions.sh apps/{{ app }}/systemd/installer.sh | ssh {{ host }} '{{ vars }}' sh -s

# kube/kubectl reads ../../.env, ../../files and ../../../../.helm (chartHome).
[private]
_kube app:
	#!/usr/bin/env bash
	set -euo pipefail
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	mkdir -p .helm "$tmp/apps" && ln -s "$PWD/.helm" "$tmp/.helm" && cp -R apps/{{ app }} "$tmp/apps/"
	app="$tmp/apps/{{ app }}"
	stage {{ app }} "$app/files" "$app/.env"
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$app/kube/kubectl" \
		| subst "$app/.env" | kubectl apply -f -

# compose.yaml mounts ../files; the values interpolate it.
[private]
_compose app:
	#!/usr/bin/env bash
	set -euo pipefail
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	cp -R apps/{{ app }} "$tmp/"
	stage {{ app }} "$tmp/{{ app }}/files" "$tmp/{{ app }}/.env"
	with_env "$tmp/{{ app }}/.env" docker compose -f "$tmp/{{ app }}/compose/compose.yaml" up

# Show which targets each app supports.
list:
	@for d in apps/*/; do t=''; for n in kube/kubectl compose systemd; do [ ! -d "$d$n" ] || t="$t $n"; done; printf '%-16s %s\n' "$(basename "$d")" "${t# }"; done

# Rendered files exist only at deploy time: each app builds from a temp copy
# with an empty .env and empty stand-ins for the files/ it references.
# The Flux cluster is checked by `just kube check`.
[doc('Build every apps/*/kube/kubectl entrypoint')]
check:
	#!/usr/bin/env bash
	set -uo pipefail
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	mkdir -p .helm "$tmp/apps" && ln -s "$PWD/.helm" "$tmp/.helm"
	rc=0
	for k in apps/*/kube/kubectl/kustomization.yaml; do
		e="${k%/*}"; a="${e#apps/}"; a="$tmp/apps/${a%%/*}"
		cp -R "${e%/kube/kubectl}" "$tmp/apps/" && : > "$a/.env" && mkdir -p "$a/files"
		for f in $(grep -oE '\.\./\.\./files/[A-Za-z0-9._-]+' "$k"); do touch "$a/${f#../../}"; done
		if kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$a/kube/kubectl" >/dev/null 2>&1
		then echo "ok    $e"; else echo "FAIL  $e"; rc=1; fi
	done
	exit $rc
