#!/usr/bin/env sh
set -eu
# Echoserver installer.
# Copyright (c) 2026 Rafael Bodill.

# variables
APP_NAME=echoserver
ECHOSERVER_VERSION=""
CONFIG_DIR=/etc/$APP_NAME
DATA_DIR=/var/lib/$APP_NAME
TEMP_DIR=/tmp/$APP_NAME

# pre-install
intro

# install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
else
	# Download and install release from GitHub.
	echo "ERROR: Unimplemented."
	exit 2
fi

# post-install
echo ':: Post install'
# reload_service $APP_NAME
