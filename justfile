# RAFI MACHINES

# `just -d DIR` without --justfile.
set minimum-version := '1.59.0'

# [script] recipes, run as strict bash scripts.
set script-interpreter := ['bash', '-euo', 'pipefail']

# gpg-agent fails some of the parallel pass decryptions secretspec makes by
# default, one at a time is reliable (and faster).
export SECRETSPEC_PROVIDER_CONCURRENCY := "1"

# Kubernetes cluster (Flux): `just kube`
mod kube 'kubernetes'

# The server (systemd over SSH): `just server`
mod server 'server'

_default:
	@just --list --unsorted

setup:
	brew install mise pass gettext
	mise install

check-ignore:
	find . -not -path './.git/*' | git check-ignore --stdin

# Lint the GitHub workflows: actionlint (shellcheck on `run:` scripts) and
# zizmor's security audits, the online ones too when GH_TOKEN is set.
[doc('Lint the GitHub workflows: actionlint (with shellcheck) and zizmor')]
[script]
lint:
	# actionlint 1.7.12 doesn't know the ubuntu-26.04 runner label yet.
	actionlint -ignore 'label "ubuntu-26\.04" is unknown'
	zizmor .github
