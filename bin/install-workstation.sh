#!/usr/bin/env bash
# Install new workstation.
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)"
source "$SCRIPT_DIR/libinstall.bash"

# Ask for the administrator password upfront
# Keep-alive: update existing `sudo` time stamp until script has finished
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

create_directories
if [ "$(uname)" == "Darwin" ]; then
	install_homebrew
	install_packages_brew
else
	echo 'This script is only for macOS.'
	exit 1
fi
clone_dotfiles
