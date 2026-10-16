# The server: nginx, rathole and microsocks (server/<app>/), deployed over
# SSH, and provisioning (etc/). Values come from pass.

set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

# Recipes here run in server/.
root := justfile_directory()

_default:
	@just --list server --unsorted

# Render each app (files/, units/, .env.sh, .env), rsync it to /tmp/<app>/
# and run its installer there. `host` is the server's SSH destination.
[doc('Deploy apps to the server: just server apply <host> [app...]')]
[script]
apply host *apps:
	. "{{ root }}/lib/render.sh"
	# Subshell: the EXIT trap removes the rendered values even on failure.
	deploy() (
		test -z "{{ apps }}" || [[ " {{ apps }} " == *" $1 "* ]] || exit 0
		app=$1
		tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
		stage "$app" "$tmp" "$tmp/.env.sh"
		env_systemd "$tmp/.env.sh" > "$tmp/.env"
		[ ! -d "$app/units" ] || cp -R "$app/units/." "$tmp/"
		rsync -hlrtWxz "$tmp/" "{{ host }}:/tmp/$app/"
		cat "{{ root }}/lib/functions.sh" "$app/installer.sh" | ssh {{ host }} "${*:2}" sh -s
	)
	deploy rathole-server
	deploy ingress    USE_PACKAGE_MANAGER=1
	deploy microsocks USE_PACKAGE_MANAGER=1

# Provision a fresh server; `target` is its first login, e.g. root@<ip>.
[doc('Provision a new server with server/etc: just server setup root@<ip>')]
setup target:
	"{{ root }}/bin/setup-server.sh" --etc etc \
		--ssh-port "$(pass show secretspec/machines/default/SERVER_SSH_PORT)" {{ target }}
