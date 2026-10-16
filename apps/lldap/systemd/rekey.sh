#!/usr/bin/env bash
# Re-keys lldap with the key_seed in $seed and resets the admin password.
# Piped to `bash -s` by `just server lldap-rekey`, which sets seed first.
set -euo pipefail

sudo systemctl stop lldap
sudo install -d -m 700 /var/backups/lldap
sudo cp -a /var/lib/lldap/users.db "/var/backups/lldap/users.db-$(date +%Y%m%d%H%M%S)-rekey"

export LLDAP_KEY_SEED="${seed:?}"
export LLDAP_FORCE_UPDATE_PRIVATE_KEY=true
export LLDAP_FORCE_LDAP_USER_PASS_RESET=true

cd /var/lib/lldap
out="$(sudo --preserve-env=LLDAP_KEY_SEED,LLDAP_FORCE_UPDATE_PRIVATE_KEY,LLDAP_FORCE_LDAP_USER_PASS_RESET \
	-u lldap /opt/lldap/lldap run --config-file /etc/lldap/config.toml 2>&1 || true)"
printf '%s\n' "$out" | grep -iE "private key|admin password|error|restart" || true

# lldap exits with this message once the key and admin password are updated.
grep -q "Restart the server without" <<< "$out"
