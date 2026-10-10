# postgres

CloudNativePG Postgres cluster. Needs the cloudnative-pg operator.

## Targets

- `kube/flux`: Flux `Kustomization` with `path: apps/postgres/kube/flux`. What the consumer must supply is in the header of [`kube/flux/kustomization.yaml`](kube/flux/kustomization.yaml).
