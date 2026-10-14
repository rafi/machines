# RAFI MACHINES

# gpg-agent fails some of the parallel pass decryptions secretspec makes by
# default; one at a time is reliable (and faster). Covers lib/deploy.just and
# `just server`, which runs this justfile.
export SECRETSPEC_PROVIDER_CONCURRENCY := "1"

import 'lib/deploy.just'

# Kubernetes cluster (Flux): `just kube`
mod kube 'kubernetes'

# The server (systemd over SSH): `just server`
mod server 'server'

_default:
	@just --list --unsorted

setup:
	brew install helm kustomize
	helm plugin install https://github.com/databus23/helm-diff --verify=false || true

check-ignore:
	find . -not -path './.git/*' | git check-ignore --stdin
