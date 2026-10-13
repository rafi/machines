#!/usr/bin/env sh
set -eux
# Authelia installer.
# Copyright (c) 2024 Rafael Bodill.

# Variables
APP_NAME=authelia
AUTHELIA_VERSION="4.38.17-1"
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# Pre-install
intro

# Install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)  # apt
			apt_trusted=/etc/apt/trusted.gpg.d/authelia.asc
			if [ ! -f "$apt_trusted" ]; then
				curl https://apt.authelia.com/organization/signing.asc | sudo tee "$apt_trusted"
			fi
			source_list=/etc/apt/sources.list.d/authelia-stable-debian.list
			if [ ! -f "$source_list" ]; then
				echo "deb https://apt.authelia.com/stable/debian/debian/ all main" | sudo tee "$source_list"
				sudo apt-get update
			fi

			sudo apt-get install -y authelia="$AUTHELIA_VERSION"
			;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
fi

# Post-install
echo ':: Post install'

# Files and directories
sudo mkdir -p "$DATA_DIR"/config/assets
sudo chown -R root:root "$CONFIG_DIR" "$DATA_DIR"
sudo chmod -R o-rwx "$CONFIG_DIR" "$DATA_DIR"
sudo mv -vf "$TEMP_DIR"/.env "$DATA_DIR"/env
sudo mv -vf "$TEMP_DIR"/authelia.service /usr/lib/systemd/system/
sudo mv -vf "$TEMP_DIR"/configuration.yml "$CONFIG_DIR"/

# Service
sudo systemctl daemon-reload
sudo systemctl enable authelia
sudo systemctl restart authelia

# vim: set ts=2 sw=2 tw=80 noet :
