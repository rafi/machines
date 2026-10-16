#!/usr/bin/env bash
# Render helpers for `just server apply` (server/mod.just): values come from
# one .env.sh, and envsubst replaces only the app's keys (nginx's $host stays).

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

# Write the app's values to <env.sh> and render its files/ into <dir>.
# Usage: stage <app dir> <dir> <env.sh>
stage() {
	local app="$1" f tmp
	secretspec -f "$app/secretspec.toml" export --format shell > "$3"
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
