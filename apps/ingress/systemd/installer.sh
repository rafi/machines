#!/usr/bin/env sh
set -eu
# Ingress-nginx installer.
# Copyright (c) 2026 Rafael Bodill.

# variables
APP_NAME=nginx
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/ingress

# pre-install
intro

# install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)
			sudo apt install nginx libnginx-mod-stream certbot python3-certbot-nginx
			sudo ufw allow 80/tcp
			sudo ufw allow 443/tcp
			;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
else
	echo "ERROR: Unimplemented."
	exit 2
fi

# post-install
echo ':: Post install'

sudo mv -vf "$TEMP_DIR"/certbot.sh /usr/local/bin/
sudo mv -vf "$TEMP_DIR"/nginx.conf "$CONFIG_DIR"/
sudo mv -vf "$TEMP_DIR"/snippets "$CONFIG_DIR"/
sudo mv -vf "$TEMP_DIR"/sites-enabled/* "$CONFIG_DIR"/sites-enabled/
sudo rm -rf "$TEMP_DIR"

sudo chmod -R 740 /usr/local/bin/certbot.sh
sudo chmod -R o-rwx "$CONFIG_DIR" "$DATA_DIR"

reload_service $APP_NAME
