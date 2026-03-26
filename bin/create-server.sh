#!/usr/bin/env bash
# Digitalocean interactive droplet creation.
set -euo pipefail

get_vpcs() {
	doctl vpcs list --format ID,Name,Description,IPRange,Region,Created
}

get_public_images() {
	doctl compute image list --public --format Slug,Name,Type,Distribution,Public,MinDisk
}

get_regions() {
	doctl compute region list --format Slug,Name,Available
}

get_sizes() {
	doctl compute size list --format Slug,Description,Memory,VCPUs,Disk,PriceMonthly,PriceHourly
}

get_ssh_keys() {
	doctl compute ssh-key list --format ID,Name,FingerPrint
}

die() {
	echo "$@" >&2
	exit 1
}

fzf() {
	command fzf --header-lines=1 --select-1 --exit-0 --reverse \
		--margin 1,5% --border --info=inline-right --height=50% --ansi "$@"
}

main() {
	local MACHINE_NAME="${1:-}"
	[ -z "$MACHINE_NAME" ] && read -rp "Enter droplet name: " MACHINE_NAME
	[ -z "$MACHINE_NAME" ] && die "Machine name is required."

	VPC_ID="$(get_vpcs | fzf --prompt 'Select VPC> ' | awk '{print $1}')"
	[ -z "$VPC_ID" ] && die "Failed to get VPC ID."

	REGION_ID="$(get_regions | fzf --prompt 'Select Region> ' | awk '{print $1}')"
	[ -z "$REGION_ID" ] && die "Failed to get region ID."

	SIZE_ID="$(get_sizes | fzf --prompt 'Select Size> ' | awk '{print $1}')"
	[ -z "$SIZE_ID" ] && die "Failed to get size ID."

	IMAGE_ID="$(get_public_images | fzf --prompt 'Select Image> ' | awk '{print $1}')"
	[ -z "$IMAGE_ID" ] && die "Failed to get image ID."

	SSHKEY_ID="$(get_ssh_keys | fzf --prompt 'Select SSH key> ' | awk '{print $1}')"
	[ -z "$SSHKEY_ID" ] && die "Failed to get SSH key ID."

	# Digitalocean
	CMD=(
		--image "$IMAGE_ID"
		--size "$SIZE_ID"
		--region "$REGION_ID"
		--vpc-uuid "$VPC_ID"
		--ssh-keys "$SSHKEY_ID"
		"$MACHINE_NAME"
	)
	echo -e "\nThis will create a new droplet with these parameters:\n"
	echo -e "${CMD[*]}\n"
	read -p "Are you sure? (y/N) " -n 1 -r
	echo
	if [[ ! $REPLY =~ ^[Yy]$ ]]; then
		echo 'Aborted.'
		exit 1
	fi

	echo 'Creating droplet...'
	result="$(doctl compute droplet create --no-header --wait \
		--format ID,Name,PublicIPv4,PrivateIPv4,Status \
		"${CMD[@]}")"
	echo "$result"

	IP="$(awk '{print $3}' <<< "$result")"

	echo 'Droplet created. To provision the server, run:'
	echo "bin/setup-server.sh --ssh-port <port> root@${IP}"
}

main "$@"
