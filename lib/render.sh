#!/usr/bin/env bash
# Render helpers for lib/deploy.just.
#
# An app's values are decrypted once, into a .env; files are rendered from
# it with envsubst limited to its keys, so any other `$` (nginx's $host)
# stays. Nothing rendered is written to the repo.

# shellcheck source-path=SCRIPTDIR source=functions.sh
. "${BASH_SOURCE[0]%/*}/functions.sh"

# Print a secretspec.toml's values as a .env. gpg-agent intermittently fails
# the parallel decryptions secretspec makes, so a failed read is retried.
# Usage: dotenv <spec> > .env
dotenv() {
	local i out
	for i in 1 2 3; do
		if out="$(secretspec -f "$1" export --format dotenv)"; then
			printf '%s\n' "$out"
			return
		fi
		echo "reading secrets failed, retrying ($i/3)" >&2
		sleep 2
	done
	return 1
}

# Run a command with a .env's values exported, literally (load_env).
# Usage: with_env <env> <command...>
with_env() (
	load_env "$1"
	shift
	exec "$@"
)

# Copy stdin to stdout, substituting only the .env's keys.
# Usage: subst <env> < in > out
subst() {
	with_env "$1" envsubst "$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/${\1}/p' "$1")"
}

# Stage apps/<app>: its values into <env> (or its own .env when it has no
# secretspec.toml), and files/ into <dir>, rendered in place (modes kept).
# Rendered *.b64 files are decoded to their name without .b64, owner-only:
# binary secrets live in pass as base64 text.
# Usage: stage <app> <dir> <env>
stage() {
	local app="apps/$1" f tmp
	if [ -f "$app/secretspec.toml" ]; then
		dotenv "$app/secretspec.toml" > "$3"
	elif [ -f "$app/.env" ]; then
		cp "$app/.env" "$3"
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
