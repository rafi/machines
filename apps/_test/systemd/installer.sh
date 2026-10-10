#!/usr/bin/env sh
set -eu
# App installer.
# Copyright (c) 2024 Rafael Bodill.

# Variables
APP_NAME=test
# CONFIG_DIR=/etc/$APP_NAME
# DATA_DIR=/var/lib/$APP_NAME
# TEMP_DIR=/tmp/$APP_NAME

# Pre-install
intro || . /Users/rafaelb/code/rafi/machines/lib/functions.sh && intro

# DEBUG -------
install_github devmatteini/dra -C /tmp
# echo "Current directory: $(pwd)"
# ls -alF "$CONFIG_DIR"/
# ls -alF "$DATA_DIR"/
# ls -alF "$TEMP_DIR"/
# cat "$TEMP_DIR"/test-foo.txt
# -------------

# Install
if test -n "${USE_PACKAGE_MANAGER:-}"
then
	case "$(get_distro)" in
		ubuntu|debian)  # apt
			echo >&2 'ERROR: Ubuntu/Debian not supported, yet.' && exit 3;;
		alpine)  # apk
			echo >&2 'ERROR: Alpine not supported, yet.' && exit 3;;
		arch)  # pacman
			echo >&2 'ERROR: Arch linux not supported, yet.' && exit 3;;
		fedora|rocky|centos)  # dnf/yum
			echo >&2 'ERROR: Fedora/Rocky/CentOS not supported, yet.' && exit 3;;
		*)
			echo >&2 'ERROR: Unsupported OS.' && exit 1
	esac
else
	# Download and install release from GitHub.
	echo >&2 "ERROR: Unimplemented."
	exit 2
fi

# Post-install
echo ':: Post install'
# reload_service $APP_NAME

# vim: set ts=2 sw=2 tw=80 noet :
