#!/usr/bin/env bash
# Install new workstation.
set -euo pipefail

function usage() {
	echo "Usage: $0 [--pub-key path|--user name] <host>..." >&2
}

function die() {
	echo "$0: $1" >&2
	exit 1
}

function backup() {
	if test -f "$1"; then
		cp -p "$1" "$1.backup-$(date +'%Y%m%d%H%M%S')"
	fi
}

function safecopy() {
	if ! cmp -s "$1" "$2"; then
		test -f "$2" && backup "$2"
		cp "$1" "$2"
	fi
}

function select_pubkey() {
	local key
	key="$( (cd ~/.ssh && find . -type f -name '*.pub') | fzf -0)"
	if [ -z "$key" ]; then
		die 'No public key selected.'
	fi
	cat "$HOME/.ssh/$key"
}

function main() {
	local hosts=()
	local ADMIN_USER=rafi SSH_PORT=22 PUB_KEY='' EXECUTE=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
			-u|--user) shift; ADMIN_USER="$1"; shift ;;
			-p|--ssh-port) shift; SSH_PORT="$1"; shift ;;
			-k|--pub-key) shift; PUB_KEY="${1}"; shift ;;
			--run-here) EXECUTE=1; shift ;;
			-*) echo "Warning, unrecognized option ${1}" >&2; shift ;;
			*) hosts+=("$1"); shift ;;
		esac
	done
	set -- "${hosts[@]}"

	if [ "$EXECUTE" -eq 1 ]; then
		_setup
		return
	fi

	# Validate
	if [ -z "${1+set}" ]; then
		echo "Usage: $0 [--pub-key path|--user name] <host>..." >&2
		exit 1
	fi

	if [ -z "$PUB_KEY" ]; then
		PUB_KEY="$(printf %q "$(select_pubkey)")"
	elif [ -f "" ]; then
		PUB_KEY="$(cat "$PUB_KEY")"
	fi

	SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

	for host
	do
		echo ":: [${host}] copy etc files to remote…"
		if ! rsync -rlt "$SCRIPT_DIR"/../etc "$host":./.setup/
		then
			die "[ERROR] failed to copy files to '${host}'"
		fi

		echo ":: [${host}] start setup on remote…"
		if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$host" \
			bash -s -- --run-here --user "$ADMIN_USER" --ssh-port "$SSH_PORT" \
				--pub-key "$PUB_KEY" < "$0"
		then
			die "[ERROR] failed to run setup on '${host}'"
		fi
		echo ':: completed successfully'
	done
}

function _setup() {
	test "$(id -u)" -eq 0 || die 'This script must be run as root.'
	if [ "$(uname)" == "Darwin" ] || [ -f "/etc/arch-release" ]; then
		echo 'This script is for provisioning a new server.'
		echo 'Use bin/setup-workstation.sh instead'
		exit 1
	elif [ ! "$(. /etc/os-release && echo "$NAME")" = "Ubuntu" ]; then
		echo 'This script only supports Ubuntu, for now.'
		exit 1
	fi

	lsb_release -a 2>/dev/null

	set -x

	# Update and upgrade
	export DEBIAN_FRONTEND=noninteractive
	apt-get -y update
	apt-get -y upgrade
	apt-get -y autoremove

	# Install packages
	apt-get -y install sudo apt-transport-https software-properties-common wget \
		dnsutils openssl locales tzdata iptables iproute2 gawk grep sed net-tools \
		cron curl rsync ufw bash bash-completion netcat-openbsd nmap ccze grc \
		wget colordiff htop iotop dstat tree tcpdump unattended-upgrades \
		ca-certificates git ripgrep btop fzf jq just lsd zoxide

	# Install Docker, but first uninstall all conflicting packages.
	if ! dpkg -l | grep -q docker-ce; then
		for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
			apt-get -y remove "$pkg"
		done
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
			-o /etc/apt/keyrings/docker.asc
		chmod a+r /etc/apt/keyrings/docker.asc
		echo \
			"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
			$(grep '^VERSION_CODENAME=' /etc/os-release | head -1 | cut -d'=' -f2) stable" | \
			tee /etc/apt/sources.list.d/docker.list > /dev/null
		apt-get -y update
		sync
		apt-get -y install docker-ce docker-ce-cli containerd.io \
			docker-buildx-plugin docker-compose-plugin
		safecopy .setup/etc/docker/daemon.json /etc/docker/daemon.json
		systemctl restart docker.service
		systemctl enable docker.service
		systemctl enable containerd.service
	fi

	# Timezone and locale
	echo "Etc/UTC" > /etc/timezone
	dpkg-reconfigure -f noninteractive tzdata
	sed -e 's/^# \(C.UTF-8 UTF-8\)/\1/' -i /etc/locale.gen
	export LANG="en_US.UTF-8"
	export LC_ALL="en_US.UTF-8"
	dpkg-reconfigure --frontend=noninteractive locales
	localectl set-locale LANG=en_US.UTF-8
	localectl

	# Unattended upgrades
	# shellcheck disable=SC2016
	sed -e '/-security/! s,^\s*\("\${distro_id}:\${distro_codename}.*\";\)$,// \1,g' \
		-i /etc/apt/apt.conf.d/50unattended-upgrades
	echo -e 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";' \
		> /etc/apt/apt.conf.d/20auto-upgrades

	# Service accounts
	if [ ! "$(getent group remote)" ]; then
		groupadd remote
	fi

	if ! id deploy >/dev/null 2>&1; then
		useradd --comment Service -m -G remote deploy
	fi

	if [ ! -d /home/deploy ]; then
		# `setgid` bit makes created files/directories inherit group ownership
		chmod g+s /home/deploy

		if hash setfacl 2>/dev/null; then
			# ACL inherit group write permission
			setfacl --set u::rwX,g::rwX,o::rX,d:u::rwX,d:g::rwX,d:o::rX /home/deploy
		fi
	fi

	# Admins and users
	if ! id "$ADMIN_USER" >/dev/null 2>&1; then
		useradd --comment Admin -m --shell /bin/bash \
			--no-user-group -G remote -g users "$ADMIN_USER"
		passwd -d "$ADMIN_USER"
		usermod -aG sudo,remote,docker,deploy "$ADMIN_USER"
	fi

	# Authorize admin public key
	set +x
	for user in deploy "$ADMIN_USER"; do
		su - "$user" << EOF
			set -xeu
			if [ ! -d ~/.ssh ]; then
				mkdir -p ~/.ssh
				chmod 700 ~/.ssh
			fi
			if [ ! -f ~/.ssh/authorized_keys ]; then
				touch ~/.ssh/authorized_keys
				chmod 600 ~/.ssh/authorized_keys
			fi
			set +x
			if ! grep -q '$PUB_KEY' ~/.ssh/authorized_keys; then
				echo 'Adding public key to authorized_keys…'
				echo '$PUB_KEY' >> ~/.ssh/authorized_keys
			fi
EOF
	done
	set -x

	# SSH
	safecopy .setup/etc/ssh/sshd_config /etc/ssh/sshd_config
	sed -e "s/^\(ListenStream\)=.*$/\1=$SSH_PORT/" -i /etc/systemd/system/sockets.target.wants/ssh.socket
	systemctl daemon-reload

	# See https://www.cyberciti.biz/faq/linux-kernel-etcsysctl-conf-security-hardening/
	echo 'net.ipv4.tcp_syncookies = 1' >> /etc/sysctl.d/local.conf
	service procps force-reload

	# Fail2ban
	apt-get -yq install fail2ban
	cp .setup/etc/fail2ban/jail.local /etc/fail2ban/
	systemctl enable --now fail2ban.service

	# Uninstall Snap
	apt-get -yq remove --purge snapd
	apt-mark hold snapd

	# Cleanup
	apt-get -y autoremove --purge
	apt-get -y clean
	apt-get -y autoclean

	rm -rf .setup
	truncate -s 0 /var/log/wtmp
	truncate -s 0 /var/log/lastlog
	rm -rf /tmp/*
	rm -rf /var/tmp/*
	sync
	rm -rf /root/.bash_history

	# Lock root
	passwd -l root

	# Restart services
	systemctl status ssh.service
	systemctl restart ssh.service

	# UFW
	sed -ri 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
	ufw allow "$SSH_PORT"/tcp
	ufw default deny incoming	
	ufw default allow outgoing
	ufw show added
	ufw status verbose

	echo "Host $host"
	echo "	Hostname $IP"
	echo "	Port $SSH_PORT"
	echo "	User $ADMIN_USER"

	yes y | ufw enable || true
}

main "$@"
