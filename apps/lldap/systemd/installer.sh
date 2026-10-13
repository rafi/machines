#!/usr/bin/env sh
set -eux
# LLDAP installer: the release tarball from GitHub (binaries and web UI), then
# users and groups from the JSON files with lldap's bootstrap.sh.
# Copyright (c) 2026 Rafael Bodill.

# Variables
APP_NAME=lldap
INSTALL_DIR=/opt/$APP_NAME
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/lldap

# User variables
load_env "$TEMP_DIR"/.env  # LLDAP_* for bootstrap.sh, optional APP_VERSION
APP_VERSION=${APP_VERSION:-0.6.3}

# Pre-install
intro

case "$(uname -m)" in
	x86_64) arch=amd64 ;;
	aarch64) arch=aarch64 ;;
	armv7l) arch=armhf ;;
	*) echo >&2 "ERROR: Unsupported architecture $(uname -m)." && exit 1
esac

# bootstrap.sh needs curl, jq and jo.
case "$(get_distro)" in
	ubuntu|debian) sudo apt-get install -y curl jq jo ;;
	*) echo >&2 'ERROR: Unsupported OS.' && exit 1
esac

# A new version migrates the database on first start, and the old package's
# removal might touch /var/lib/lldap: back the database up first, outside it.
installed="$(cat "$INSTALL_DIR"/VERSION 2>/dev/null || true)"
if [ "$installed" != "$APP_VERSION" ] && sudo test -f "$DATA_DIR"/users.db; then
	sudo systemctl stop lldap || true
	sudo install -d -m 700 /var/backups/lldap
	sudo cp -a "$DATA_DIR"/users.db "/var/backups/lldap/users.db-$(date +%Y%m%d%H%M%S)"
fi

# Old installs came from a Debian package (its repository is gone). Remove it;
# config and data stay, the unit moves to /etc/systemd/system.
if dpkg-query -W lldap >/dev/null 2>&1; then
	sudo systemctl stop lldap || true
	sudo apt-get remove -y lldap
	sudo rm -f /usr/lib/systemd/system/lldap.service
fi
if ! id lldap >/dev/null 2>&1; then
	sudo useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin lldap
fi

# Install the release when the version changes.
if [ "$installed" != "$APP_VERSION" ]; then
	wget --no-verbose -O /tmp/lldap.tar.gz \
		"https://github.com/lldap/lldap/releases/download/v${APP_VERSION}/${arch}-lldap.tar.gz"
	rm -rf /tmp/"${arch}"-lldap
	tar -xzf /tmp/lldap.tar.gz -C /tmp
	echo "$APP_VERSION" > /tmp/"${arch}"-lldap/VERSION
	sudo rm -rf "$INSTALL_DIR"
	sudo mv /tmp/"${arch}"-lldap "$INSTALL_DIR"
	sudo chown -R root:root "$INSTALL_DIR"
	rm -f /tmp/lldap.tar.gz
fi

# Files and directories. groups.json is the group; every other *.json is a
# user (bind_user.json and any more). The cleanup below removes these dirs.
sudo install -d -o lldap -g lldap "$CONFIG_DIR" "$DATA_DIR"
sudo install -d -o lldap -g lldap "$DATA_DIR"/user-configs "$DATA_DIR"/group-configs \
	"$DATA_DIR"/user-schemas "$DATA_DIR"/group-schemas
sudo install -m 600 -o lldap -g lldap "$TEMP_DIR"/config.toml "$CONFIG_DIR"/
sudo mv -f "$TEMP_DIR"/groups.json "$DATA_DIR"/group-configs/
for f in "$TEMP_DIR"/*.json; do
	if test -e "$f"; then sudo mv -f "$f" "$DATA_DIR"/user-configs/; fi
done
sudo chown -R lldap:lldap "$DATA_DIR"

# The bootstrap script of the same release.
curl -fsSL "https://github.com/lldap/lldap/raw/v${APP_VERSION}/scripts/bootstrap.sh" \
	| sudo install -m 755 -o lldap -g lldap /dev/stdin "$DATA_DIR"/bootstrap.sh

# Service
sudo mv -f "$TEMP_DIR"/lldap.service /etc/systemd/system/
reload_service lldap

export LLDAP_URL=http://127.0.0.1:${LLDAP_HTTP_PORT}
export LLDAP_SET_PASSWORD_PATH="$INSTALL_DIR"/lldap_set_password
export USER_CONFIGS_DIR="$DATA_DIR"/user-configs
export GROUP_CONFIGS_DIR="$DATA_DIR"/group-configs
export USER_SCHEMAS_DIR="$DATA_DIR"/user-schemas
export GROUP_SCHEMAS_DIR="$DATA_DIR"/group-schemas
export DO_CLEANUP=true

# Wait for the server (and a database migration) before bootstrapping.
i=0
until curl -fsS -o /dev/null "$LLDAP_URL"/health; do
	i=$((i + 1))
	if [ "$i" -ge 60 ]; then
		sudo journalctl -u lldap --no-pager -n 30
		exit 1
	fi
	sleep 1
done

# Bootstrapping users and groups.
sudo -E -u lldap "$DATA_DIR"/bootstrap.sh

# Cleanup
sudo rm -rf \
	"$TEMP_DIR" \
	"$DATA_DIR"/bootstrap.sh \
	"$DATA_DIR"/user-configs/ \
	"$DATA_DIR"/group-configs/ \
	"$DATA_DIR"/user-schemas/ \
	"$DATA_DIR"/group-schemas/

# vim: set ts=2 sw=2 tw=80 noet :
