# The server in front of the cluster (nginx, rathole server, SOCKS5 proxy):
# which apps/<app> run on it, deployed over SSH with `just deploy systemd`,
# and how a new one is provisioned (etc/). Values come from pass. Authelia
# and LLDAP run in the cluster (kubernetes/apps/auth).

set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

# Recipes here run in server/; deploys run from the repo root.
root := justfile_directory()

_default:
	@just --list server --unsorted

# Deploy apps to the server; all of them when none are named. `host` is its
# SSH destination, e.g. an ssh config alias (the repo doesn't name it).
[doc('Deploy apps to the server: just server apply <host> [app...]')]
[script]
apply host *apps:
	# deploy <app> [VAR=val...], unless apps were named and it isn't one.
	deploy() {
		test -z "{{ apps }}" || [[ " {{ apps }} " == *" $1 "* ]] || return 0
		'{{ just_executable() }}' -d "{{ root }}" deploy systemd "$1" {{ host }} "${@:2}"
	}
	deploy rathole-server
	deploy ingress    USE_PACKAGE_MANAGER=1
	deploy microsocks USE_PACKAGE_MANAGER=1

# Provision a fresh server: users, ssh, firewall, etc/ files. The ssh port is
# in pass. `target` is the new machine's first login, e.g. root@<ip>.
[doc('Provision a new server with server/etc: just server setup root@<ip>')]
setup target:
	"{{ root }}/bin/setup-server.sh" --etc etc \
		--ssh-port "$(pass show secretspec/machines/default/SERVER_SSH_PORT)" {{ target }}
