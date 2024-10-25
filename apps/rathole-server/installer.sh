#!/usr/bin/env bash
set -xeuo pipefail

# variables
APP_NAME=rathole
CONFIG_DIR=/etc/$APP_NAME
TEMP_DIR=/var/local/$APP_NAME

# pre-install
intro
# shellcheck disable=SC1091
source "$TEMP_DIR"/.env  # for RATHOLE_VERSION and FIREWALL_PORT

if test -n "${USE_PKG:-}"
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
	RATHOLE_URL="https://github.com/rapiz1/rathole/releases/download/v${RATHOLE_VERSION}/rathole-x86_64-unknown-linux-gnu.zip"
	wget -qO /tmp/rathole.zip "${RATHOLE_URL}"
	unzip /tmp/rathole.zip -d /tmp/
	rm -f /tmp/rathole.zip
	sudo mv /tmp/rathole /usr/local/bin/
	sudo chown root:root /usr/local/bin/rathole
	sudo chmod 755 /usr/local/bin/rathole
fi

# post-install
sudo ufw allow "$FIREWALL_PORT"/tcp
sudo ufw show added

sudo mkdir -p "$CONFIG_DIR"/certs
sudo mv -vf "$TEMP_DIR"/server.toml "$CONFIG_DIR"/
sudo mv -vf "$TEMP_DIR"/identity.pfx /etc/rathole/certs/
sudo mv -vf "$TEMP_DIR"/rathole.service /etc/systemd/system/
sudo rm -rf "$TEMP_DIR"

reload_service $APP_NAME
