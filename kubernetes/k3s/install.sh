#!/bin/sh
# Run on the node by `just kube k3s-install`: installs config.yaml and k3s $1.
set -eu

dir=$(dirname "$0")
trap 'rm -rf "$dir"' EXIT

# Stop on any host but the node.
ip=$(sed -n 's/^bind-address: *//p' "$dir/config.yaml")
if [ -z "$ip" ] || ! ip -o addr show | grep -qF " $ip/"; then
	echo "this host doesn't have the config's bind-address: not the node" >&2
	exit 1
fi

# The script's k3s would shadow the package's.
if command -v pacman >/dev/null && pacman -Qq k3s-bin >/dev/null 2>&1; then
	echo 'k3s-bin is installed: remove it first (sudo pacman -R k3s-bin)' >&2
	exit 1
fi

sudo install -d /etc/rancher/k3s
sudo install -m 600 "$dir/config.yaml" /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$1" sh -
