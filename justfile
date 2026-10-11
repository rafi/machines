# RAFI MACHINES

import 'lib/deploy.just'

_default:
	@just --list --unsorted

setup:
	brew install helm kustomize
	helm plugin install https://github.com/databus23/helm-diff --verify=false || true

check-ignore:
	find . -not -path './.git/*' | git check-ignore --stdin
