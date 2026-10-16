#!/usr/bin/env sh
set -eux
# microsocks SOCKS5 proxy installer.
# Copyright (c) 2026 Rafael Bodill.

# shellcheck disable=SC1091

# variables
APP_NAME=microsocks
CONFIG_DIR=/etc/$APP_NAME
TEMP_DIR=/tmp/microsocks

# user variables
load_env "$TEMP_DIR"/.env.sh  # for MICROSOCKS_PORT and APP_VERSION
APP_VERSION=${APP_VERSION:-1.0.5}

# pre-install
intro

# install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)
			apt_get install -y microsocks
			;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
else
	# microsocks publishes no binaries; build the release from source.
	wget -qO- "https://github.com/rofl0r/microsocks/archive/refs/tags/v${APP_VERSION}.tar.gz" \
		| tar -xz -C /tmp
	make -C /tmp/microsocks-"$APP_VERSION"
	sudo install -m 755 /tmp/microsocks-"$APP_VERSION"/microsocks /usr/local/bin/
	rm -rf /tmp/microsocks-"$APP_VERSION"
fi

# post-install
echo ':: Post install'
sudo ufw allow "$MICROSOCKS_PORT"/tcp
sudo ufw show added

# systemd reads the credentials from here; only root can read it.
sudo install -d -m 755 "$CONFIG_DIR"
sudo install -m 600 -o root -g root "$TEMP_DIR"/.env "$CONFIG_DIR"/microsocks.env
sudo mv -vf "$TEMP_DIR"/microsocks.service /etc/systemd/system/
sudo rm -rf "$TEMP_DIR"

reload_service $APP_NAME

# vim: set ts=2 sw=2 tw=80 noet :
