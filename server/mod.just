# The public server in front of the cluster (nginx, Authelia, LLDAP,
# rathole server, SOCKS5 proxy): which apps/<app> run on it, deployed over
# SSH with `just deploy systemd`, and how a new one is provisioned (etc/).
# Values come from pass.

set shell := ['bash', '-euo', 'pipefail', '-c']

dir := source_directory()
root := dir / '..'

_default:
	@just --list server --unsorted

# Deploy apps to the server; all of them when none are named.
[doc('Deploy apps to the server: just server apply <host> [app...]')]
apply host *apps:
	#!/usr/bin/env bash
	set -euo pipefail
	# deploy <app> [VAR=val...], unless apps were named and it isn't one.
	deploy() {
		test -z "{{ apps }}" || [[ " {{ apps }} " == *" $1 "* ]] || return 0
		just --justfile "{{ root }}/justfile" --working-directory "{{ root }}" \
			deploy systemd "$1" {{ host }} "${@:2}"
	}
	deploy rathole-server
	deploy ingress
	deploy lldap
	deploy authelia
	deploy microsocks USE_PACKAGE_MANAGER=1

# Provision a fresh the server: users, ssh, firewall, etc/ files. The ssh port is in pass.
[doc('Provision a new server with server/etc and the ssh port from pass')]
setup host:
	"{{ root }}/bin/setup-server.sh" --etc "{{ dir }}/etc" \
		--ssh-port "$(pass show secretspec/machines/default/SERVER_SSH_PORT)" {{ host }}
