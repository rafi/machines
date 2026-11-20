# osewa and Moshi on this machine: install them, run osewa's server where
# Moshi expects it, enroll this machine on the node, check a host.
#
# mode: `local` (osewa's default 7322, for a LAN or tailnet) or `tunnel`
# (OSEWA_PORT from pass: the node, public through the server's rathole).
# Values from pass are only captured or passed on, never printed.

set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

_default:
	@just --list moshi --unsorted

# Print a mode's port; only ever captured by the recipes below.
[private]
[script]
_port mode:
	case "{{ mode }}" in
		local) echo 7322 ;;
		tunnel) pass show secretspec/machines/default/OSEWA_PORT | head -1 ;;
		*) echo >&2 "mode: local or tunnel, not '{{ mode }}'"; exit 2 ;;
	esac

[doc('Install osewa (auto-updating) and moshi-hook where missing; usage and metrics off')]
[script]
install:
	export PATH="$HOME/.local/bin:$PATH"
	command -v osewa >/dev/null || curl -fsSL https://osewa.dev/install.sh | sh
	# Moshi needs the host's build to match the app's: follow releases. osewa
	# has no telemetry; its only outbound call is this release check.
	osewa set auto-update auto
	command -v moshi-hook >/dev/null || curl -fsSL https://getmoshi.app/install.sh | sh
	# Nothing about this machine goes to Moshi beyond what a session needs:
	# no agent usage pulled from account APIs, no CPU/memory/process stream.
	moshi-hook set usage-collection off >/dev/null
	moshi-hook set host-metrics off >/dev/null

# osewa's user service listens on the mode's port, TCP and UDP, and
# moshi-hook tells Moshi the same port. Re-running reinstalls both on it.
[doc('Serve osewa for Moshi on this host: just moshi host [local|tunnel]')]
[script]
host mode='local': install
	export PATH="$HOME/.local/bin:$PATH"
	port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port "{{ mode }}")
	# Its output has no port, and on Linux the linger hint the node needs.
	osewa service install --listen ":$port"
	moshi-hook set osewa-port "$port" >/dev/null
	moshi-hook service restart
	if ! moshi-hook status | grep -E '^status:[[:space:]]+paired' >/dev/null; then
		echo "Pair this host from the Moshi app (Hooks), then run just moshi host {{ mode }} again."
	fi

# Prints yes/no per check, never the port; fails when any is no. Without a
# mode it checks the port moshi-hook is set to (no pass read); with one,
# also that moshi-hook is set to that mode's port.
[doc('Check osewa and moshi-hook on this host: just moshi status [local|tunnel]')]
[script]
status mode='':
	export PATH="$HOME/.local/bin:$PATH"
	status=$(moshi-hook osewa status 2>/dev/null || true)
	field() { printf '%s' "$status" | yq -p json ".$1" 2>/dev/null || true; }
	mode="{{ mode }}"
	if [ -n "$mode" ]; then
		port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port "$mode")
	else
		port=$(field port)
	fi
	# Is osewa listening on the port? proto: tcp or udp. Called through check.
	# shellcheck disable=SC2329
	listens() {
		case "$(uname -s)" in
			Darwin)
				if [ "$1" = tcp ]; then
					lsof -nP -a -c osewa -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
				else
					lsof -nP -a -c osewa -iUDP:"$port" >/dev/null 2>&1
				fi ;;
			*)
				if [ "$1" = tcp ]; then
					ss -tlnpH "sport = :$port" 2>/dev/null | grep '"osewa"' >/dev/null
				else
					ss -ulnpH "sport = :$port" 2>/dev/null | grep '"osewa"' >/dev/null
				fi ;;
		esac
	}
	failed=0
	# Print "<label> yes|no" for a command, in this shell so `failed` sticks.
	check() {
		local label=$1 r=yes
		shift
		"$@" || { r=no; failed=1; }
		printf '%-27s %s\n' "$label:" "$r"
	}
	daemon=$(moshi-hook probe --json 2>/dev/null || true)
	check 'moshi-hook daemon running' test "$(printf '%s' "$daemon" | yq -p json .running 2>/dev/null)" = true
	check 'osewa server running' test "$(field running)" = true
	[ -z "$mode" ] || check 'moshi-hook on the port' test "$(field port)" = "$port"
	check 'osewa on the port, TCP' listens tcp
	check 'osewa on the port, UDP' listens udp
	exit "$failed"

# Enroll this machine on the node through the server: ssh on the server's
# 443 reaches the node's sshd, osewa then dials the server's public osewa
# port. --no-install keeps the node's osewa build, which Moshi must match.
# `name`: the host's name here (default the node's hostname, from pass);
# `target`: any other ssh target for the node (default ssh://$USER@s.<domain>:443).
[doc('Enroll this machine on the node: just moshi enroll [name] [ssh-target]')]
[script]
enroll name='' target='':
	export PATH="$HOME/.local/bin:$PATH"
	pv() { pass show "secretspec/machines/default/$1" | head -1; }
	port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port tunnel)
	# Plain assignments, so set -e stops on a pass failure.
	domain=$(pv SECRET_DOMAIN)
	server=$(pv SERVER_HOSTNAME)
	node=$(pv CLUSTER_NODE_NAME)
	given="{{ name }}"
	name=${given:-$node}
	target="{{ target }}"
	[ -n "$target" ] || target="ssh://$USER@s.$domain:443"
	# osewa prints the address and target (pass values) on success and in
	# errors: drop stdout (also its wrong --service advice for the node) and
	# show stderr with the values replaced.
	redact() {
		while IFS= read -r l; do
			l=${l//"$server"/<server>}; l=${l//"$domain"/<domain>}; l=${l//"$port"/<port>}; l=${l//"$node"/<node>}
			printf '%s\n' "$l"
		done
	}
	{ osewa login "$target" --name "$name" --no-install --addr "$server:$port" 2>&1 >/dev/null; } | redact >&2
	# The node's hostname is a private value: name it, don't print it.
	if [ -n "$given" ]; then echo "enrolled as $given"; else echo "enrolled under the node's hostname (CLUSTER_NODE_NAME)"; fi
