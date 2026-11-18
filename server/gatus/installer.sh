#!/usr/bin/env sh
set -eux
# Gatus installer: the binary staged by `just server apply` (taken from
# upstream's image, GATUS_VERSION in server/mod.just).
# Copyright (c) 2026 Rafael Bodill.

# variables
APP_NAME=gatus
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/gatus

# pre-install
intro

id -u $APP_NAME >/dev/null 2>&1 \
	|| sudo useradd --system --user-group --no-create-home --home-dir "$DATA_DIR" \
		--shell /usr/sbin/nologin $APP_NAME
sudo install -d -m 750 -o $APP_NAME -g $APP_NAME "$DATA_DIR"

sudo install -m 755 -o root -g root "$TEMP_DIR"/gatus /usr/local/bin/gatus

# post-install
# No ufw port: the UI listens on loopback (ssh -L 8080:127.0.0.1:8080).
sudo install -d -m 750 -o root -g $APP_NAME "$CONFIG_DIR"
sudo install -m 640 -o root -g $APP_NAME "$TEMP_DIR"/config.yaml "$CONFIG_DIR"/config.yaml
sudo mv -vf "$TEMP_DIR"/gatus.service /etc/systemd/system/
sudo rm -rf "$TEMP_DIR"

reload_service $APP_NAME
sleep 2
sudo systemctl is-active --quiet $APP_NAME || {
	sudo journalctl -u $APP_NAME --no-pager -n 30
	exit 1
}

# vim: set ts=2 sw=2 tw=80 noet :
