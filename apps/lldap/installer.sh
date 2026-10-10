#!/usr/bin/env sh
set -xeu
# LLDAP installer.
# Copyright (c) 2026 Rafael Bodill.

# Variables
LLDAP_VERSION="0.5.0"
LLDAP_DEB_URL="https://download.opensuse.org/repositories/home:/Masgalor:/LLDAP/xUbuntu_23.04/amd64/lldap_${LLDAP_VERSION}-1+3.1_amd64.deb"
LLDAP_IMAGE="lldap/lldap:2024-08-08-debian"

CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# Pre-install
intro

# Files and directories
mv "$TEMP_DIR"/config.toml /etc/lldap/
mv "$TEMP_DIR"/bind_user.json /var/lib/lldap/user-configs/
mv "$TEMP_DIR"/groups.json /var/lib/lldap/group-configs/
mv "$TEMP_DIR"/*.json /var/lib/lldap/user-configs/
sudo chown -R lldap:lldap "$CONFIG_DIR" "$DATA_DIR"
# sudo chmod -R o-rwx "$CONFIG_DIR" "$DATA_DIR"

# Install
wget -qO /tmp/lldap.deb "${LLDAP_DEB_URL}"
sudo dpkg -i /tmp/lldap.deb

# TODO: Once a new release is made, this should be removed.
# https://github.com/lldap/lldap/releases
curl -Lo "$DATA_DIR"/bootstrap.sh \
	https://github.com/lldap/lldap/raw/main/scripts/bootstrap.sh

docker pull "${LLDAP_IMAGE}"
trap "docker rm -f lldap" EXIT
docker run --name lldap --rm -d --entrypoint cat -it "${LLDAP_IMAGE}"
sudo docker cp lldap:/app/lldap_set_password "$DATA_DIR"/lldap_set_password
docker rm -f lldap

# Post-install

# Service
sudo chown -R lldap:lldap "$DATA_DIR"
sudo chmod og+x "$DATA_DIR"/bootstrap.sh "$DATA_DIR"/lldap_set_password
[ -f "$CONFIG_DIR"/lldap_config.toml ] && \
	sudo mv "$CONFIG_DIR"/lldap_config.toml \
		"$CONFIG_DIR"/lldap_config.docker_template.toml

sudo mv "$TEMP_DIR"/lldap.service /usr/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lldap

# shellcheck disable=SC2046
export $(grep -v '^#' "$TEMP_DIR"/.env | xargs)
export LLDAP_URL=http://127.0.0.1:${LLDAP_HTTP_PORT}
export LLDAP_HTTP_URL=http://127.0.0.1:${LLDAP_HTTP_PORT}
export LLDAP_SET_PASSWORD_PATH="$DATA_DIR"/lldap_set_password
export USER_CONFIGS_DIR="$DATA_DIR"/user-configs
export GROUP_CONFIGS_DIR="$DATA_DIR"/group-configs
export DO_CLEANUP=true

# Bootstrapping users and groups.
sudo systemctl restart lldap
sudo -E -u lldap "$DATA_DIR"/bootstrap.sh

# Nginx site
sudo mv -vf "$TEMP_DIR"/*.nginx "$CONFIG_DIR"/
systemctl reload nginx.service

# Cleanup
sudo rm -rf \
	/tmp/lldap.deb \
	"$TEMP_DIR"/.env \
	"$DATA_DIR"/bootstrap.sh \
	"$DATA_DIR"/lldap_set_password \
	"$DATA_DIR"/user-configs/ \
	"$DATA_DIR"/group-configs/

# vim: set ts=2 sw=2 tw=80 noet :
