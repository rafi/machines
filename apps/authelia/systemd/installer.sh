#!/usr/bin/env sh
set -eux
# Authelia installer.
# Copyright (c) 2024 Rafael Bodill.

# Variables
APP_NAME=authelia
# The version the server runs; bump it to upgrade (check the changelog first).
AUTHELIA_VERSION="4.38.16-1"
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# Pre-install
intro

# Install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)
			# https://www.authelia.com/integration/deployment/bare-metal/#apt-repository
			sudo apt-get install -y ca-certificates curl
			sudo curl -fsSL https://www.authelia.com/keys/authelia-security.gpg \
				-o /usr/share/keyrings/authelia-security.gpg
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/authelia-security.gpg] https://apt.authelia.com stable main" \
				| sudo tee /etc/apt/sources.list.d/authelia.list >/dev/null
			# The repository's old location and globally trusted key.
			sudo rm -f /etc/apt/sources.list.d/authelia-stable-debian.list \
				/etc/apt/trusted.gpg.d/authelia.asc
			sudo apt-get update
			# Held, so `apt upgrade` doesn't move it past the pinned version.
			sudo apt-get install -y --allow-change-held-packages authelia="$AUTHELIA_VERSION"
			sudo apt-mark hold authelia
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
