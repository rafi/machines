# echo

Echo server for ingress checks.

## Targets

- `kube/flux`: Flux `Kustomization` with `path: apps/echo/kube/flux`. What the consumer must supply is in the header of [`kube/flux/kustomization.yaml`](kube/flux/kustomization.yaml).
- `systemd`: `just deploy systemd echo <host>`
