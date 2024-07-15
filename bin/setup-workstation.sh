# Install library helpers for macOS and Linux.

function install_homebrew() {
	if ! hash brew 2>/dev/null; then
		url=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
		/bin/bash -c "$(curl -fsSL "$url")"
	else
		echo 'Homebrew already installed.'
	fi
}

function clone_dotfiles() {
	git clone --recursive git@github.com:rafi/.config.git ~/.config
	cd ~/.config || return 1
	git remote add srht git@git.sr.ht:~rafib/.config
	git config --local filter.vault.clean 'sed -f ~/.config/clean.sed'
	git config --local filter.vault.smudge 'sed -f ~/docs/config/smudge.sed'
	cd ..
	ln -s .config/bash/bashrc .bashrc
	ln -s .config/bash/profile .profile
	ln -s .config/zsh/.zshrc .zshrc
	ln -s docs/netrc/config .netrc

	git clone --recursive git@github.com:rafi/vim-config.git ~/.config/nvim

	if [ "$(uname)" == "Darwin" ]; then
		cd ~/Library/LaunchAgents || return 1
		ln -sfv ../../.config/launch/io.rafi.environment.plist .
		launchctl load -w io.rafi.environment.plist
		# ./osx.sh
	fi
}

function create_directories() {
	mkdir -p ~/.cache/{nvim,pacaur,xpanes,zoxide}
	mkdir -p ~/.local/bin
	mkdir -p ~/.local/share/{cargo,fonts,go,krew,lf}
	mkdir -p ~/.local/share/python/{poetry,pyenv}
}

function install_packages_brew() {
	brew update
	brew install mas
	brew bundle install --file ~/.config/Brewfile

	brew --prefix bash | sudo tee -a /etc/shells
	chsh -s "$(brew --prefix bash)"
}

# FIXME: not tested
function install_packages_pacman() {
	if ! hash pacman 2>/dev/null; then
		echo 'This script is only for Arch Linux.'
		exit 1
	fi

	sudo pacman -Syu --noconfirm
	sudo pacman -S --noconfirm base-devel git

	if ! hash yay 2>/dev/null; then
		local tmpdir; tmpdir="$(mktemp -d)"
		git clone https://aur.archlinux.org/yay.git "$tmpdir"
		cd "$tmpdir" || return 1
		makepkg -si
		pacman -U --noconfirm yay-*.pkg.tar.zst
		cd - || return 1
		rm -rf "$tmpdir"
		yay -Syu --noconfirm
	fi

	yay -S --noconfirm - < ~/.config/pkglist.txt
}
