# osewa and Moshi on this machine.
# serve: lets the Moshi app in. The node uses OSEWA_PORT (public via the
# server), everything else uses 7322 on the LAN or a tailnet.
# login: lets a laptop's terminal into the node.
# Values from pass are never printed.
#
# - Skill: https://github.com/rjyo/moshi-skill/tree/main
# - Hooks: https://getmoshi.app/docs/hooks
# - Osewa: https://getmoshi.app/docs/osewa
#
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

_default:
	@just --list moshi --unsorted

# Prints `node` if this machine is the node, else `lan`.
[private]
[script]
_mode:
	# Plain assignment, so a pass failure stops the script.
	node=$(pass show secretspec/machines/default/CLUSTER_NODE_NAME | head -1)
	if [ "$(hostname -s)" = "${node%%.*}" ]; then echo node; else echo lan; fi

# Prints a mode's port. Only ever captured, never shown.
[private]
[script]
_port mode:
	case "{{ mode }}" in
		lan) echo 7322 ;;
		node) pass show secretspec/machines/default/OSEWA_PORT | head -1 ;;
		*) echo >&2 "mode: lan or node, not '{{ mode }}'"; exit 2 ;;
	esac

[doc('Install osewa and moshi-hook if missing, and hook up the AI agents found here')]
[script]
install:
	export PATH="$HOME/.local/bin:$PATH"
	command -v osewa >/dev/null || curl -fsSL https://osewa.dev/install.sh | sh
	# Moshi needs osewa to match the app's build. This update check is the
	# only call osewa makes home.
	osewa set auto-update auto
	# Fresh installs start with usage and host metrics off. Re-runs keep
	# whatever you've changed since.
	if ! command -v moshi-hook >/dev/null; then
		curl -fsSL https://getmoshi.app/install.sh | sh
		moshi-hook set usage-collection off >/dev/null
		moshi-hook set host-metrics off >/dev/null
	fi
	# Hooks every agent CLI it finds, so approvals reach the phone. Re-run
	# after installing a new agent.
	moshi-hook install

# Points osewa and moshi-hook at this machine's port. Safe to re-run.
[doc('Let the Moshi app open sessions on this machine')]
[script]
serve: install
	export PATH="$HOME/.local/bin:$PATH"
	mode=$("{{ just_executable() }}" -f "{{ source_file() }}" _mode)
	port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port "$mode")
	# Let it print. There's no port in it, and the node needs its linger hint.
	osewa service install --listen ":$port"
	moshi-hook set osewa-port "$port" >/dev/null
	moshi-hook service restart
	case "$mode" in
		node) echo "Serving as the node on OSEWA_PORT, public through the server." ;;
		lan) echo "Serving on 7322, for the LAN or a tailnet." ;;
	esac
	if ! moshi-hook status | grep -E '^status:[[:space:]]+paired' >/dev/null; then
		echo "Pair this host from the Moshi app (Hooks), then run just moshi serve again."
	fi

# yes/no per check, never the port. Fails if any check says no.
[doc('Check osewa and moshi-hook on this machine')]
[script]
status:
	export PATH="$HOME/.local/bin:$PATH"
	status=$(moshi-hook osewa status 2>/dev/null || true)
	field() { printf '%s' "$status" | yq -p json ".$1" 2>/dev/null || true; }
	mode=$("{{ just_executable() }}" -f "{{ source_file() }}" _mode)
	port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port "$mode")
	case "$mode" in
		node) printf '%-27s %s\n' 'serves as:' 'the node (OSEWA_PORT)' ;;
		lan) printf '%-27s %s\n' 'serves as:' 'LAN or tailnet (7322)' ;;
	esac
	# Is osewa on the port over $1 (tcp or udp)? Only called via check.
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
	# Runs in this shell so `failed` sticks.
	check() {
		local label=$1 r=yes
		shift
		"$@" || { r=no; failed=1; }
		printf '%-27s %s\n' "$label:" "$r"
	}
	daemon=$(moshi-hook probe --json 2>/dev/null || true)
	check 'moshi-hook daemon running' test "$(printf '%s' "$daemon" | yq -p json .running 2>/dev/null)" = true
	check 'osewa server running' test "$(field running)" = true
	check 'moshi-hook on the port' test "$(field port)" = "$port"
	check 'osewa on the port, TCP' listens tcp
	check 'osewa on the port, UDP' listens udp
	exit "$failed"

# Run once per laptop, and again if OSEWA_PORT or the node's osewa keys
# change. Always goes through the server, even at home.
# --no-install keeps the node's osewa build, which has to match Moshi's.
# name: what to call the node here (default: its hostname).
# target: another ssh target for the node (default: ssh://$USER@s.<domain>:443).
[doc("Let this laptop's terminal open sessions on the node")]
[script]
login name='' target='': install
	export PATH="$HOME/.local/bin:$PATH"
	pv() { pass show "secretspec/machines/default/$1" | head -1; }
	port=$("{{ just_executable() }}" -f "{{ source_file() }}" _port node)
	# Plain assignments, so a pass failure stops the script.
	domain=$(pv SECRET_DOMAIN)
	server=$(pv SERVER_HOSTNAME)
	node=$(pv CLUSTER_NODE_NAME)
	given="{{ name }}"
	name=${given:-$node}
	target="{{ target }}"
	[ -n "$target" ] || target="ssh://$USER@s.$domain:443"
	# osewa prints private values. Drop stdout (it also gives the wrong
	# --service advice here) and redact stderr.
	redact() {
		while IFS= read -r l; do
			l=${l//"$server"/<server>}; l=${l//"$domain"/<domain>}; l=${l//"$port"/<port>}; l=${l//"$node"/<node>}
			printf '%s\n' "$l"
		done
	}
	{ osewa login "$target" --name "$name" --no-install --addr "$server:$port" 2>&1 >/dev/null; } | redact >&2
	# The node's hostname is private, so don't print it.
	if [ -n "$given" ]; then echo "logged in to the node as $given"; else echo "logged in to the node under its hostname (CLUSTER_NODE_NAME)"; fi
