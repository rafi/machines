#!/usr/bin/env bash
# Install new workstation.
set -euo pipefail

function die() {
	echo "$0: $1" >&2
	exit 1
}

pause() {
	read -n 1 -s -r -p 'Press any key to continue...'
}

function backup() {
	if test -f "$1"; then
		cp "$1" "$1.backup-$(date +'%Y%m%d%H%M%S')"
	fi
}

function homebrew_install() {
	if ! hash brew 2>/dev/null; then
		url=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
		/bin/bash -c "$(curl -fsSL "$url")"

		HOMEBREW_PREFIX=/opt/homebrew
		[ "$(uname -m)" = "x86_64" ] && HOMEBREW_PREFIX=/usr/local
		eval "$("$HOMEBREW_PREFIX"/bin/brew shellenv)"
		# export CC="$HOMEBREW_PREFIX/bin/gcc-11"
	else
		echo 'Homebrew already installed.'
	fi
}

function clone_dotfiles() {
	git clone --recursive git@github.com:rafi/.config.git ~/.config
	pushd ~/.config 1>/dev/null
	git remote add srht git@git.sr.ht:~rafib/.config
	git config --local filter.vault.clean 'sed -f ~/.config/clean.sed'
	git config --local filter.vault.smudge 'sed -f ~/docs/config/smudge.sed'

	pushd .. 1>/dev/null
	ln -s .config/bash/bashrc .bashrc
	ln -s .config/bash/profile .profile
	ln -s .config/zsh/.zshrc .zshrc
	ln -s docs/netrc/config .netrc

	git clone --recursive git@github.com:rafi/vim-config.git ~/.config/nvim

	popd 1>/dev/null && popd 1>/dev/null

	if [ "$(uname)" == "Darwin" ]; then
		pushd ~/Library/LaunchAgents 1>/dev/null
		ln -sfv ../../.config/launch/io.rafi.environment.plist .
		launchctl load -w io.rafi.environment.plist
		popd 1>/dev/null
		# ./osx.sh
	fi
}

function create_directories() {
	mkdir -p ~/.cache/{nvim,pacaur,xpanes,zoxide}
	mkdir -p ~/.local/bin
	mkdir -p ~/.local/share/{cargo,fonts,go,krew,lf}
	mkdir -p ~/.local/share/python/{poetry,pyenv}
}

function homebrew_packages_install() {
	brew update
	brew install mas fish
	brew --prefix fish | sudo tee -a /etc/shells
	chsh -s "$(brew --prefix fish)"

	# Install all packages from local Brewfile
	brew bundle install --file ~/.config/Brewfile
}

# Link local Homebrew tap from ~/code/pkg/tap
function homebrew_setup_local_repo() {
	local local_repo_src="$HOME"/code/pkg/tap
	local local_repo_dst="$HOMEBREW_PREFIX"/Library/Taps/rafi

	if [ ! -d "$local_repo_dst" ]; then
		if [ ! -d "$local_repo_src" ]; then
			echo "WARNING! Local Homebrew tap source does not exist: $local_repo_src"
			echo 'Copy now and press any key to continue.'
			pause
		fi
		if [ -d "$local_repo_src" ]; then
			mkdir "$local_repo_dst"
			ln -s "$local_repo_src" "$local_repo_dst"/homebrew-tap
		fi
	else
		echo 'Local Homebrew tap already set up.'
	fi
}

# FIXME: not tested
function pacman_packages_install() {
	if ! hash pacman 2>/dev/null; then
		echo 'This script is only for Arch Linux.'
		exit 1
	fi

	sudo pacman -Syu --noconfirm
	sudo pacman -S --noconfirm base-devel git

	if ! hash yay 2>/dev/null; then
		local tmpdir
		tmpdir="$(mktemp -d)"
		pushd "$tmpdir" || return 1
		git clone https://aur.archlinux.org/yay.git .
		makepkg -si
		pacman -U --noconfirm yay-*.pkg.tar.zst
		popd || return 1
		rm -rf "$tmpdir"
		yay -Syu --noconfirm
	fi

	yay -S --noconfirm - < ~/.config/pkglist.txt
}

function main() {
	# Ask for the administrator password upfront
	# Keep-alive: update existing `sudo` time stamp until script has finished
	# sudo -v
	# while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

	echo '1. Create directories...'
	pause
	create_directories

	if [ "$(uname)" == "Darwin" ]; then
		echo '1. Install Homebrew: https://brew.sh'
		pause
		homebrew_install

		echo '2. Link local Homebrew tap from ~/code/pkg/tap'
		pause
		homebrew_setup_local_repo

		echo '3. Install packages via Homebrew with ~/.config/Brewfile'
		pause
		homebrew_packages_install

		echo '4. Switch to Finder and install any propriety fonts yourself.'
		pause

		echo '5. Please enable "Full Disk Access" for your terminals under System Settings → Privacy & Security → Full Disk Access.'
		pause

	elif [ -f "/etc/arch-release" ]; then
		pacman_packages_install
	elif [ "$(awk -F= '/^ID=/{print $2}' /etc/os-release)" = "ubuntu" ]; then
		echo 'Use bin/setup-server.sh instead.'
	else
		echo 'This script supports macOS and Linux, only.'
		exit 1
	fi

	clone_dotfiles
}

main "$@"
