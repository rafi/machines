# App deploys (apps/<app>/), imported by the root justfile.
# See docs/architecture.md#apps-and-deploy-targets.

# VAR=val args after the host reach a systemd installer, e.g. USE_PACKAGE_MANAGER=1.
# The child just prints its own errors.
[doc('Deploy an app: just deploy systemd|kube|compose <app> [host] [VAR=val...]')]
[arg('target', pattern='systemd|kube|compose')]
[no-exit-message]
deploy target app *args:
	@'{{ just_executable() }}' -d '{{ justfile_directory() }}' _{{ target }} {{ app }} {{ args }}

# Units ship unrendered: systemd fills their ${VAR} from the installed .env.
# Installers read .env.sh.
[script]
_systemd app host *vars:
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	stage {{ app }} "$tmp" "$tmp/.env.sh"
	env_systemd "$tmp/.env.sh" > "$tmp/.env"
	[ ! -d apps/{{ app }}/systemd/files ] || cp -R apps/{{ app }}/systemd/files/. "$tmp/"
	rsync -hlrtWxz "$tmp/" {{ host }}:/tmp/{{ app }}/
	cat lib/functions.sh apps/{{ app }}/systemd/installer.sh | ssh {{ host }} '{{ vars }}' sh -s

# Builds a temp copy of apps/<app> holding the rendered .env and files/;
# Helm charts come from the repo's .helm cache.
[script]
_kube app:
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	mkdir -p .helm "$tmp/apps" && ln -s "$PWD/.helm" "$tmp/.helm" && cp -R apps/{{ app }} "$tmp/apps/"
	app="$tmp/apps/{{ app }}"
	stage {{ app }} "$app/files" "$app/.env.sh"
	env_kustomize "$app/.env.sh" > "$app/.env"
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$app/kube/kubectl" \
		| subst "$app/.env.sh" | kubectl apply -f -

# Runs a temp copy of apps/<app>: compose.yaml mounts the rendered files/
# and interpolates the app's values from the environment.
[script]
_compose app:
	. lib/render.sh
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	cp -R apps/{{ app }} "$tmp/"
	stage {{ app }} "$tmp/{{ app }}/files" "$tmp/{{ app }}/.env.sh"
	with_env "$tmp/{{ app }}/.env.sh" docker compose -f "$tmp/{{ app }}/compose/compose.yaml" up

# Show which targets each app supports.
[script]
list:
	for d in apps/*/; do
		t=''
		for n in kube/kubectl compose systemd; do
			[ ! -d "$d$n" ] || t="$t $n"
		done
		printf '%-16s %s\n' "$(basename "$d")" "${t# }"
	done

# Build each app from a temp copy with an empty .env and stub files/.
# The Flux cluster is checked by `just kube check`.
[doc('Build every apps/*/kube/kubectl entrypoint')]
[script('bash', '-uo', 'pipefail')]
check:
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
