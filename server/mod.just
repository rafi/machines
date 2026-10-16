# The server in front of the cluster (nginx, Authelia, LLDAP, rathole
# server, SOCKS5 proxy): which apps/<app> run on it, deployed over SSH with
# `just deploy systemd`, and how a new one is provisioned (etc/). Values come
# from pass.

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
	deploy lldap
	deploy authelia   USE_PACKAGE_MANAGER=1
	deploy microsocks USE_PACKAGE_MANAGER=1

# Provision a fresh server: users, ssh, firewall, etc/ files. The ssh port is
# in pass. `target` is the new machine's first login, e.g. root@<ip>.
[doc('Provision a new server with server/etc: just server setup root@<ip>')]
setup target:
	"{{ root }}/bin/setup-server.sh" --etc etc \
		--ssh-port "$(pass show secretspec/machines/default/SERVER_SSH_PORT)" {{ target }}

# Replace lldap's key_seed: re-key on the server (apps/lldap/systemd/rekey.sh),
# then redeploy. Users not in apps/lldap/files/*.json must set new passwords.
[doc('Rotate lldap key_seed: re-key on the server, then redeploy lldap')]
[confirm('Re-key lldap? Users outside apps/lldap/files must set new passwords.')]
[script]
lldap-rekey host: && (apply host 'lldap')
	seed="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 40)"
	# The seed goes over ssh's stdin, never into a command line.
	{
		printf "seed=\$(cat <<'SEED'\n%s\nSEED\n)\n" "$seed"
		cat "{{ root }}/apps/lldap/systemd/rekey.sh"
	} | ssh {{ host }} bash -s
	# The server has the new key now: keep pass in step before deploying.
	printf '%s' "$seed" | pass insert -m -f secretspec/machines/default/LLDAP_KEY_SEED >/dev/null
	echo "LLDAP_KEY_SEED updated in pass; deploying lldap with it"
