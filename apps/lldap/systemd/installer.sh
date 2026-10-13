#!/usr/bin/env sh
set -eux
# LLDAP installer.
# Copyright (c) 2026 Rafael Bodill.

# Variables
APP_NAME=lldap
LLDAP_VERSION="0.5.0"
LLDAP_DEB_URL="https://download.opensuse.org/repositories/home:/Masgalor:/LLDAP/xUbuntu_23.04/amd64/lldap_${LLDAP_VERSION}-1+3.1_amd64.deb"
LLDAP_IMAGE="lldap/lldap:2024-08-08-debian"
# bootstrap.sh isn't in the 0.5.0 release; this is the last version before
# the image above. Newer ones expect newer lldap servers.
LLDAP_BOOTSTRAP_REF=b33d56a4594e

CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# Pre-install
intro

# Install (the package creates the lldap user and $CONFIG_DIR). The package
# repository is gone (404), so only a host without lldap downloads it.
if ! dpkg-query -W lldap >/dev/null 2>&1; then
	wget --no-verbose -O /tmp/lldap.deb "${LLDAP_DEB_URL}"
	sudo dpkg -i /tmp/lldap.deb
fi

# Files and directories. groups.json is the group; every other *.json is a
# user (bind_user.json and any more). The cleanup below removes these dirs.
sudo install -d "$CONFIG_DIR" "$DATA_DIR"/user-configs "$DATA_DIR"/group-configs
sudo mv -f "$TEMP_DIR"/config.toml "$CONFIG_DIR"/
sudo mv -f "$TEMP_DIR"/groups.json "$DATA_DIR"/group-configs/
for f in "$TEMP_DIR"/*.json; do
	if test -e "$f"; then sudo mv -f "$f" "$DATA_DIR"/user-configs/; fi
done
sudo chown -R lldap:lldap "$CONFIG_DIR" "$DATA_DIR"
# sudo chmod -R o-rwx "$CONFIG_DIR" "$DATA_DIR"

curl -fsSL "https://github.com/lldap/lldap/raw/${LLDAP_BOOTSTRAP_REF}/scripts/bootstrap.sh" \
	| sudo tee "$DATA_DIR"/bootstrap.sh >/dev/null

# Copy lldap_set_password out of the image without running it (no TTY here).
sudo docker pull "${LLDAP_IMAGE}"
sudo docker rm -f lldap-tmp >/dev/null 2>&1 || true
sudo docker create --name lldap-tmp "${LLDAP_IMAGE}" >/dev/null
sudo docker cp lldap-tmp:/app/lldap_set_password "$DATA_DIR"/lldap_set_password
sudo docker rm -f lldap-tmp >/dev/null

# Post-install

# Service
sudo chown -R lldap:lldap "$DATA_DIR"
sudo chmod 755 "$DATA_DIR"/bootstrap.sh "$DATA_DIR"/lldap_set_password
[ -f "$CONFIG_DIR"/lldap_config.toml ] && \
	sudo mv "$CONFIG_DIR"/lldap_config.toml \
		"$CONFIG_DIR"/lldap_config.docker_template.toml

sudo mv "$TEMP_DIR"/lldap.service /usr/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lldap

load_env "$TEMP_DIR"/.env
export LLDAP_URL=http://127.0.0.1:${LLDAP_HTTP_PORT}
export LLDAP_HTTP_URL=http://127.0.0.1:${LLDAP_HTTP_PORT}
export LLDAP_SET_PASSWORD_PATH="$DATA_DIR"/lldap_set_password
export USER_CONFIGS_DIR="$DATA_DIR"/user-configs
export GROUP_CONFIGS_DIR="$DATA_DIR"/group-configs
export DO_CLEANUP=true

# Bootstrapping users and groups.
sudo systemctl restart lldap
sudo -E -u lldap "$DATA_DIR"/bootstrap.sh

# Cleanup
sudo rm -rf \
	/tmp/lldap.deb \
	"$TEMP_DIR" \
	"$DATA_DIR"/bootstrap.sh \
	"$DATA_DIR"/lldap_set_password \
	"$DATA_DIR"/user-configs/ \
	"$DATA_DIR"/group-configs/

# vim: set ts=2 sw=2 tw=80 noet :
