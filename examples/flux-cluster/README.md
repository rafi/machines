# Example: Flux consumer repo

Minimal layout of a private GitOps repo that deploys apps from this
repository with [Flux](https://fluxcd.io). All values are placeholders.

```
kustomization.yaml        # source.yaml + apps/
source.yaml               # GitRepository pointing at this repo
apps/
  kustomization.yaml      # one line per enabled app
  slskd/
    kustomization.yaml    # aggregator: slskd.yaml + config/
    slskd.yaml            # Flux Kustomization (path: apps/<app> here)
    config/               # namespace-scoped: Secret, ConfigMap, Namespace
```

Check that it builds (also used to catch drift from the apps):

```sh
kustomize build examples/flux-cluster
```

## Why two `kustomization.yaml` per app

- `slskd/kustomization.yaml` groups the Flux `Kustomization` with its config,
  so `apps/kustomization.yaml` needs one line per app.
- `slskd/config/kustomization.yaml` sets `namespace:` for the cluster objects
  only. Setting it one level up would move the Flux `Kustomization` out of
  `flux-system` and break its `sourceRef`.

## Rules

- Deployment-specific values (hostnames, ports, credentials) live here, never
  in the app definitions. Apps expose them as `${VAR}` placeholders, secrets
  and ConfigMaps by name.
- Each app's `kustomization.yaml` header lists what the consumer must supply.
- Flux resolves `substituteFrom` in the Kustomization's own namespace only.
  Use `substitute` for values that don't need to be secret.
- Substituted values: put numbers only in integer fields. In string fields
  (e.g. env `value`) quote them in the app manifest.
- Resource names can't be hash-linked across repos. Use
  `disableNameSuffixHash` and restart the workload after a change (or run a
  reloader controller).
- Declare a shared Namespace in one app's `config/` only.
- Encrypt Secrets (e.g. sops) before committing; Flux decrypts only
  `kind: Secret`.
