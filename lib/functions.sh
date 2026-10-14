#!/usr/bin/env sh
set -eu
# POSIX compliant helper functions (for installer scripts).
# Copyright (c) 2024 Rafael Bodill.
#
# Functions should be short and sweet, and not contain application logic.
# `install_github()` should stay the most complex function.

# shellcheck disable=SC2155

# Introductory message.
intro() {
	echo "--> Installing '$APP_NAME' on $USER@$(hostname)"
	echo "System information: $(uname -smor)"
}

# Reads /etc/os-release and returns the ID field's value.
get_distro() {
	grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"'
}

# Uses systemctl to restart a service that might have changed configuration, or
# was not enabled.
# Usage: reload_service 'service-name'
reload_service() {
	sudo systemctl daemon-reload
	sudo systemctl enable "$@"
	sudo systemctl restart "$@"
}

# apt-get that never prompts: config files we deploy over a package's own
# (e.g. /etc/nginx/nginx.conf) are kept on upgrades instead of dpkg asking.
# stdin is /dev/null, because an installer's own stdin is the script piped
# over ssh: a prompt would read the rest of the script as its answer.
# needrestart (Ubuntu) is suspended: it would restart an upgraded service
# before the installer has put its config, permissions and environment in
# place, installers restart their services themselves.
# Usage: apt_get install -y nginx
apt_get() {
	sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" </dev/null
}

# Exports the KEY=value lines of a .env file, literally: values are never
# evaluated, so `$`, quotes and spaces in secrets survive. Tracing is paused,
# so installers can run with `set -x` without printing secrets.
# Usage: load_env "$TEMP_DIR"/.env
load_env() {
	case $- in *x*) set +x; _load_env_trace=1 ;; *) _load_env_trace= ;; esac
	while IFS= read -r _load_env_line || [ -n "$_load_env_line" ]; do
		case $_load_env_line in
			''|'#'*) continue ;;
			*=*) export "${_load_env_line%%=*}=${_load_env_line#*=}" ;;
		esac
	done < "$1"
	unset _load_env_line
	if [ -n "$_load_env_trace" ]; then set -x; fi
}

# Get latest tag
# Usage: get_latest_tag 'user/repo'
get_latest_tag() {
	url=https://github.com/"$1"/tags
	curl -Ls "$url" \
		| gawk '/href/&&/releases\/tag/{ print gensub(/^.*href="([^"]+)".*$/, "\\\\1", "g"); exit }' FS='[<>]' \
		| xargs basename
}

# Get latest release's version
# Usage: get_latest_release 'user/repo'
get_latest_release() {
	url=https://github.com/"$1"/releases/latest
	v="$(wget -qSO- --no-cookie --max-redirect 0 "$url" 2>&1 \
		| grep '^\s*Location:')"
	if [ -z "$v" ]; then
		v="$(curl -Ls -o /dev/null -w '%{url_effective}' "$url")"
	fi
	echo "${v##*/}"
}

# Download, extract, and install a release from GitHub.
# Usage: install_github 'user/repo' [-C /path/to/install]
install_github() {
	base=https://api.github.com/repos/"$1"
	assets="$(wget -qO- "$base"/releases/latest \
			--header 'Accept: application/vnd.github.v3+json' \
		| grep browser_download_url \
		| cut -d : -f 2,3 | tr -d \" | sed 's/^\ *//g')"

	dest='.'
	if [ "${2:-}" = "-C" ]; then
		dest="$3"
		[ ! -d "$dest" ] && echo >&2 "ERROR: directory does not exist." && exit 1
	fi
	echo ":: Download $1 to '$dest'"

	# Determine system information to find the correct download.
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	arch=$(uname -p)
	machine="$(uname -m)"
	set -- \
		"$(test "$os" = 'Darwin' && echo apple)" \
		"$os" \
		"$arch" \
		"$machine" \
		"$(test "$machine" = 'arm64' && echo aarch64)" \
		"$([ ! "$os" = 'Darwin' ] && [ "$machine" = 'x86_64' ] && echo musl)" \
		"gnu"

	# Filter assets.
	filtered="$assets"
	for pattern in "$@"; do
		test -z "$pattern" && continue
		out="$(echo "$filtered" | grep "$pattern")"
		[ -n "$out" ] && filtered="$out"
	done

	# Download.
	echo ":: search: $*"
	if [ ! "$(echo "$filtered" | sed -n '=')" = "1" ]; then
		echo ":: Unable to match a download"
		echo "Searched for these patterns: $*"
		echo "Available assets:"
		echo "$assets"
		return 1
	fi
	tempdir="$(mktemp -d)"
	cd "$tempdir" || { echo >&2 "Unable to cd '$tempdir'"; exit 1; }
	wget -q "$filtered"

	filename="${filtered##*/}"
	test -z "$filename" && echo >&2 "Failed to download $filtered" && exit 1

	# Extract.
	case "$filtered" in
		*.tar.gz) tar -xzf "$filename" ;;
		*.tar.xz) tar -xJf "$filename" ;;
		*.zip) unzip -q "$filename" ;;
		*) echo >&2 "Unknown archive format: $filename" && exit 1 ;;
	esac
	cd - 1>/dev/null || { echo >&2 'Unable to cd -'; exit 1; }

	# Find binaries and install them.
	for path in "$tempdir"/*/*; do
		if test -f "$path" && grep -q '[^[:print:][:blank:]]' "$path"; then
			name="${path##*/}"
			mv -f "$path" "$dest/"
			chmod 750 "$dest/$name"
			# echo ':: Installed:' "$name"
		fi
	done

	rm -rf "$tempdir"
}
