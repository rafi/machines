#!/usr/bin/env sh
set -eux
# Authelia installer: the Debian package from Authelia's APT repository, its
# systemd unit plus our environment file, and the configuration.
# Copyright (c) 2024 Rafael Bodill.

# Variables
APP_NAME=authelia
# Bump to upgrade, after reading the release notes and validating the config.
AUTHELIA_VERSION="4.39.28-1"
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# User variables
load_env "$TEMP_DIR"/.env  # AUTHELIA_* for validate-config

# Pre-install
intro

# Install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)
			# A new version migrates the database on first start: back it up first.
			installed="$(dpkg-query -W -f '${Version}' authelia 2>/dev/null || true)"
			if [ "$installed" != "$AUTHELIA_VERSION" ] && sudo test -f "$DATA_DIR"/db.sqlite3; then
				sudo install -d -m 700 /var/backups/authelia
				sudo cp -a "$DATA_DIR"/db.sqlite3 "/var/backups/authelia/db.sqlite3-${installed:-none}-$(date +%Y%m%d%H%M%S)"
			fi
			# https://www.authelia.com/integration/deployment/bare-metal/#apt-repository
			apt_get install -y ca-certificates curl
			sudo curl -fsSL https://www.authelia.com/keys/authelia-security.gpg \
				-o /usr/share/keyrings/authelia-security.gpg
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/authelia-security.gpg] https://apt.authelia.com stable main" \
				| sudo tee /etc/apt/sources.list.d/authelia.list >/dev/null
			# The repository's old location and globally trusted key.
			sudo rm -f /etc/apt/sources.list.d/authelia-stable-debian.list \
				/etc/apt/trusted.gpg.d/authelia.asc
			apt_get update
			# Held, so `apt upgrade` doesn't move it past the pinned version.
			apt_get install -y --allow-change-held-packages authelia="$AUTHELIA_VERSION"
			sudo apt-mark hold authelia
			;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
fi

# Post-install
echo ':: Post install'

# The package's unit runs as user authelia (created by the package since
# 4.39). Data and config belong to it; the env file stays root's, systemd
# reads it before switching user.
sudo install -d -m 750 -o authelia -g authelia "$DATA_DIR" "$DATA_DIR"/config "$DATA_DIR"/config/assets
sudo chown -R authelia:authelia "$DATA_DIR"
sudo install -m 600 -o root -g root "$TEMP_DIR"/.env "$DATA_DIR"/env
sudo install -m 440 -o authelia -g authelia "$TEMP_DIR"/configuration.yml "$CONFIG_DIR"/configuration.yml
sudo install -D -m 644 "$TEMP_DIR"/environment.conf /etc/systemd/system/authelia.service.d/environment.conf
sudo rm -rf "$TEMP_DIR"

# Refuse to restart into a config this version rejects (set -e stops here).
sudo -E -u authelia authelia validate-config --config "$CONFIG_DIR"/configuration.yml

# Service
reload_service authelia

# Wait for the server (and a database migration).
i=0
until curl -fs -o /dev/null http://127.0.0.1:9091/api/health; do
	i=$((i + 1))
	if [ "$i" -ge 60 ]; then
		sudo journalctl -u authelia --no-pager -n 30
		exit 1
	fi
	sleep 1
done
authelia --version

# vim: set ts=2 sw=2 tw=80 noet :
