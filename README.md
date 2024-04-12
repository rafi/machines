# RAFI MACHINES

> Orchestrate my haze.

## Pre-requisites

```sh
brew install just

just setup
```

## Scripts

See [./bin](./bin/) directory.

## Deploy

Machine directories:

- [cluster](./cluster/) — Cloud server with public IP.
- [home](./home/) — Home server with ArchLinux

Every machine has a `justfile` with several targets.

### Kustomize

This repository uses [Kustomize](https://kustomize.io/), mostly, to manage
Kubernetes manifests. For larger/complex applications, an official Helm chart
is used.

See [`justfile`](./justfile) and [`helmfile.yaml`](./helmfile.yaml) for an
overview of each deployment.

Kustomize tips:

- Dry-run: `kubectl apply --dry-run=server -k ./kube/<app>/`
- Diff: `kubectl diff -k ./kube/<app>/`
- Deploy: `kubectl apply -k ./kube/<app>/`

## Copyright

2024 © [Rafael Bodill](https://example.com)
