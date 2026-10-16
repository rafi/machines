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

# Replace lldap's key_seed. Stored passwords depend on the key, so lldap runs
# once with the new seed to re-key and reset the admin password (to
# LLDAP_ADMIN_PASSWORD); the deploy that follows re-sets bind_user's. Users
# not in apps/lldap/files/*.json would have to set new passwords.
[doc('Rotate lldap key_seed: re-key on the server, then redeploy lldap')]
[confirm('Re-key lldap? Users outside apps/lldap/files must set new passwords.')]
[script]
lldap-rekey host: && (apply host 'lldap')
	seed="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 40)"
	# Runs on the server under bash (whatever the login shell). The script,
	# seed included, goes over ssh's stdin, never into a command line.
	remote='set -euo pipefail
		sudo systemctl stop lldap
		sudo install -d -m 700 /var/backups/lldap
		sudo cp -a /var/lib/lldap/users.db "/var/backups/lldap/users.db-$(date +%Y%m%d%H%M%S)-rekey"
		export LLDAP_KEY_SEED="$seed" LLDAP_FORCE_UPDATE_PRIVATE_KEY=true LLDAP_FORCE_LDAP_USER_PASS_RESET=true
		cd /var/lib/lldap
		out="$(sudo --preserve-env=LLDAP_KEY_SEED,LLDAP_FORCE_UPDATE_PRIVATE_KEY,LLDAP_FORCE_LDAP_USER_PASS_RESET \
			-u lldap /opt/lldap/lldap run --config-file /etc/lldap/config.toml 2>&1 || true)"
		printf "%s\n" "$out" | grep -iE "private key|admin password|error|restart" || true
		# lldap exits with this message once the key and admin password are updated.
		grep -q "Restart the server without" <<< "$out"'
	{
		printf "seed=\$(cat <<'SEED'\n%s\nSEED\n)\n" "$seed"
		printf '%s\n' "$remote"
	} | ssh {{ host }} bash -s
	# The server has the new key now: keep pass in step before deploying.
	printf '%s' "$seed" | pass insert -m -f secretspec/machines/default/LLDAP_KEY_SEED >/dev/null
	echo "LLDAP_KEY_SEED updated in pass; deploying lldap with it"
