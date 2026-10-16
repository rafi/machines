#!/usr/bin/env bash
# Render helpers for lib/deploy.just: values come from one .env.sh, and
# envsubst replaces only the app's keys (nginx's $host stays).

# shellcheck source-path=SCRIPTDIR source=functions.sh
. "${BASH_SOURCE[0]%/*}/functions.sh"

# Run a command with a .env.sh's values exported (load_env).
# Usage: with_env <env.sh> <command...>
with_env() (
	load_env "$1"
	shift
	exec "$@"
)

# Print the keys of a .env.sh, one per line.
# Usage: env_keys <env.sh>
env_keys() {
	sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1"
}

# Copy stdin to stdout, substituting only the .env.sh's keys.
# Usage: subst <env.sh> < in > out
subst() {
	with_env "$1" envsubst "$(env_keys "$1" | sed 's/.*/${&}/')"
}

# Print values as systemd EnvironmentFile= lines: KEY="value", with
# \ " ` $ escaped (the only escapes systemd undoes inside quotes).
# Usage: env_systemd <env.sh> > .env
env_systemd() (
	load_env "$1"
	for k in $(env_keys "$1"); do
		v=${!k}
		v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\`/\\\`}; v=${v//\$/\\\$}
		printf '%s="%s"\n' "$k" "$v"
	done
)

# Print values as kustomize envs: lines: KEY=value, taken literally.
# Fails on a newline or trailing CR, which kustomize would cut off.
# Usage: env_kustomize <env.sh> > .env
env_kustomize() (
	load_env "$1"
	for k in $(env_keys "$1"); do
		v=${!k}
		case $v in
			*$'\n'* | *$'\r')
				echo >&2 "$k: kustomize env files can't hold a newline or a trailing CR"
				exit 1 ;;
		esac
		printf '%s=%s\n' "$k" "$v"
	done
)

# Write the app's values to <env.sh> and render files/ into <dir>.
# Without a secretspec.toml, a hand-written .env is used literally.
# Usage: stage <app> <dir> <env.sh>
stage() {
	local app="apps/$1" f tmp
	if [ -f "$app/secretspec.toml" ]; then
		secretspec -f "$app/secretspec.toml" export --format shell > "$3"
	elif [ -f "$app/.env" ]; then
		sed -n "s/'/'\\\\''/g; s/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)\$/export \1='\2'/p" "$app/.env" > "$3"
	else
		: > "$3"
	fi
	mkdir -p "$2"
	[ ! -d "$app/files" ] || cp -R "$app/files/." "$2/"
	tmp="$(mktemp)"
	while IFS= read -r -d '' f; do
		subst "$3" < "$f" > "$tmp"
		cat "$tmp" > "$f"
	done < <(find "$2" -type f ! -path "$3" -print0)
	rm "$tmp"
	while IFS= read -r -d '' f; do
		(umask 077; base64 -d < "$f" > "${f%.b64}")
		rm "$f"
	done < <(find "$2" -name '*.b64' -print0)
}
