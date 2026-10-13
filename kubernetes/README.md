# Kubernetes cluster

A single k3s node, managed by Flux from this repo. Pushing to `master` is the
deploy. Values that git doesn't hold come from `pass`
(`secretspec/machines/default/<KEY>`):

| Key | Used by |
|---|---|
| `K3S_TOKEN`, `CLUSTER_NODE_IP`, `CLUSTER_NODE_NAME`, `SECRET_DOMAIN` | `just kube k3s-install` ([k3s/config.yaml](k3s/config.yaml)) |
| `K3S_KUBECONFIG` | `just kube kubeconfig`, `just kube kubeconfig-save` |
| `FLUX_GITHUB_TOKEN` | `just kube bootstrap`: read-only GitHub token, the repo is private |
| `SECRET_DOMAIN`, `SERVER_HOSTNAME` | Secret `cluster-settings` in every namespace (Flux substitutes them) |
| the keys in `apps/<ns>/<app>/secrets/secretspec.toml` | `just kube secrets` |

## Rebuild from scratch

### 1. k3s, on the node

```sh
/usr/local/bin/k3s-uninstall.sh      # only when reinstalling on the same host
just kube k3s-install                # or: just kube k3s-install v1.33.4+k3s1
sudo systemctl status k3s
```

k3s's own Traefik and Helm controller are disabled in the config: Flux
installs Traefik and runs the Helm charts. `K3S_TOKEN` only has to be kept
to join more nodes; a fresh single node may get a new one.

### 2. Kubeconfig, on the workstation

A new install has new certificates. Store its kubeconfig, then use it:

```sh
just kube kubeconfig-save <node>     # <node>: the node's SSH destination
just kube kubeconfig                 # writes ~/.kube/cluster.yaml
set -gx KUBECONFIG ~/.kube/cluster.yaml
kubectl get nodes
```

### 3. Flux and secrets

```sh
just kube bootstrap   # github-token from pass, then Flux from flux/flux-system
just kube secrets     # cluster-settings and every app's Secrets from pass
just kube sync
just kube failing     # expect nothing; the first sync takes minutes (Helm charts)
kubectl get gateway,httproute -A
```

Order is enforced by `dependsOn`: gateway-api, then traefik; cloudnative-pg,
then postgres, then miniflux.

### 4. Data not in git

Flux restores manifests; Secrets come from `pass`. Restore these from backups:

- the postgres volume (PVC `postgres-1` in `db`, k3s local-path storage);
- slskd's state, `/opt/slskd`, and the media folders it shares (hostPaths on
  the node).

## Upgrades

- **Flux:** `flux install --export > kubernetes/flux/flux-system/gotk-components.yaml`.
  The strict-substitution patch is in `flux/flux-system/kustomization.yaml`
  and survives the regeneration.
- **Charts:** `ref.tag` in an app's `app/ocirepository.yaml` (app-template), or
  `chart.spec.version` in `app/helmrelease.yaml` (traefik, cloudnative-pg,
  postgres).
- **Images:** `image.tag` in the app's `app/helmrelease.yaml`.
- **Gateway API CRDs:** `ref.tag` in
  `apps/kube-system/gateway-api/app/gitrepository.yaml`.

Read the release notes first; `just kube check` builds everything locally.

## Values that must match

- **The Soulseek port (30002)** is in four places: the slskd Service and
  `listen_port` in `apps/default/slskd/app/helmrelease.yaml`, the rathole
  client's `[client.services.slskd]` in
  `apps/rathole/rathole-client/secrets/rathole-conf.yaml`, and the server's
  `RATHOLE_SERVER_SERVICES_SLSKD_PORT` (rathole and `ufw` there).
- **SOCKS5 proxy credentials:** `SLSKD_SLSK_PROXY_*` equal `MICROSOCKS_*`.

## Troubleshooting

```sh
just kube failing
just kube events
just kube logs
just kube tree
```

- A Kustomization fails with an unset variable: `cluster-settings` is
  missing in its namespace, or a literal `${` needs to be `$${`. Run
  `just kube secrets`.
- Pods read Secrets at start: after `just kube secrets`, run
  `kubectl -n <ns> rollout restart deploy/<app>`.
