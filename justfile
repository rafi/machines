# RAFI MACHINES

[private]
default:
	@just --list --unsorted

setup:
	brew install helm helmfile kustomize
	helm plugin install https://github.com/databus23/helm-diff || true

check-ignored:
	git check-ignore */*

apply-cluster:
	kubectl apply -k cluster/kube/rathole/
	kubectl apply -k cluster/kube/ingress/
	kubectl apply -k cluster/kube/lldap/
	kubectl apply -k cluster/kube/authelia/

apply-home:
	kubectl apply -k home/kube/rathole/
	kubectl apply -k home/kube/echo/
	kubectl apply -k home/kube/postgres/
	kubectl apply -k home/kube/charm/
	kubectl apply -k home/kube/miniflux/
	kubectl apply -k home/kube/slskd/

	# Nester
	kubectl apply -k home/kube/drone/
	kubectl apply -k home/kube/rasa/

helm-sync:
	helmfile sync

helm-apply app:
	helmfile apply -l app={{ app }}

helm-template app:
	helmfile template -l app={{ app }}
