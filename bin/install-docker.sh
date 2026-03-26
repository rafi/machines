#!/usr/bin/env sh
set -eu
# Install new workstation.
# Copyright (c) 2024 Rafael Bodill.

if ! dpkg -l | grep -q docker-ce; then
	# Install Docker, but first uninstall all conflicting packages.
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
