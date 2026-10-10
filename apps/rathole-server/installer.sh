#!/usr/bin/env sh
set -eu
# Rathole server installer.
# Copyright (c) 2026 Rafael Bodill.

# shellcheck disable=SC1091

# variables
APP_NAME=rathole
CONFIG_DIR=/etc/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# user variables
. "$TEMP_DIR"/.env  # for APP_VERSION and RATHOLE_SERVER_BIND_PORT
APP_VERSION=${APP_VERSION:-0.5.0}

# pre-install
intro

if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		arch)
			sudo pacman -S --noconfirm rathole
			;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
else
	# Download and install release from GitHub.
	RATHOLE_URL="https://github.com/rapiz1/rathole/releases/download/v${APP_VERSION}/rathole-x86_64-unknown-linux-gnu.zip"
	wget -qO /tmp/rathole.zip "${RATHOLE_URL}"
	unzip /tmp/rathole.zip -d /tmp/
	rm -f /tmp/rathole.zip
	sudo mv /tmp/rathole /usr/local/bin/
	sudo chown root:root /usr/local/bin/rathole
	sudo chmod 755 /usr/local/bin/rathole
fi

# post-install
sudo ufw allow "$RATHOLE_SERVER_BIND_PORT"/tcp
sudo ufw allow "$RATHOLE_SERVER_SERVICES_SLSKD_PORT"/tcp
sudo ufw show added

sudo mkdir -p "$CONFIG_DIR"/certs
sudo mv -vf "$TEMP_DIR"/server.toml "$CONFIG_DIR"/
sudo mv -vf "$TEMP_DIR"/identity.pfx /etc/rathole/certs/
sudo mv -vf "$TEMP_DIR"/rathole.service /etc/systemd/system/
sudo rm -rf "$TEMP_DIR"

reload_service $APP_NAME

# vim: set ts=2 sw=2 tw=80 noet :
