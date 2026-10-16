#!/usr/bin/env sh
set -eux
# shadowsocks-rust server installer: ssserver from the GitHub release.
# Copyright (c) 2026 Rafael Bodill.

# variables
APP_NAME=shadowsocks
CONFIG_DIR=/etc/$APP_NAME
TEMP_DIR=/tmp/shadowsocks

# user variables
load_env "$TEMP_DIR"/.env.sh  # for SHADOWSOCKS_PORT and APP_VERSION
APP_VERSION=${APP_VERSION:-1.25.0}

# pre-install
intro

# Install the release when the version changes.
installed="$(/usr/local/bin/ssserver --version 2>/dev/null | awk '{print $2}' || true)"
if [ "$installed" != "$APP_VERSION" ]; then
	url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${APP_VERSION}/shadowsocks-v${APP_VERSION}.x86_64-unknown-linux-gnu.tar.xz"
	rm -rf /tmp/shadowsocks-release && mkdir /tmp/shadowsocks-release
	wget -qO- "$url" | tar -xJ -C /tmp/shadowsocks-release ssserver
	sudo install -m 755 -o root -g root /tmp/shadowsocks-release/ssserver /usr/local/bin/ssserver
	rm -rf /tmp/shadowsocks-release
fi

# post-install
sudo ufw allow "$SHADOWSOCKS_PORT"/tcp
sudo ufw show added

sudo install -d -m 700 "$CONFIG_DIR"
sudo install -m 600 -o root -g root "$TEMP_DIR"/config.json "$CONFIG_DIR"/config.json
sudo mv -vf "$TEMP_DIR"/shadowsocks.service /etc/systemd/system/
sudo rm -rf "$TEMP_DIR"

reload_service $APP_NAME
sleep 2
sudo systemctl is-active --quiet $APP_NAME || {
	sudo journalctl -u $APP_NAME --no-pager -n 30
	exit 1
}
/usr/local/bin/ssserver --version

# vim: set ts=2 sw=2 tw=80 noet :
