# Kubernetes cluster

A single k3s node, managed by Flux from this repo. Pushing to `master` is the
deploy. Values that git doesn't hold come from `pass`
(`secretspec/machines/default/<KEY>`):

| Key | Used by |
|---|---|
| `K3S_TOKEN`, `CLUSTER_NODE_IP`, `CLUSTER_NODE_NAME`, `SECRET_DOMAIN` | `just kube k3s-install` ([k3s/config.yaml](k3s/config.yaml)) |
| `K3S_KUBECONFIG` | `just kube kubeconfig`, `just kube kubeconfig-save` |
| `SECRET_DOMAIN`, `SERVER_HOSTNAME`, `FLUX_TELEGRAM_CHAT_ID`, `RATHOLE_SERVER_SERVICES_SLSKD_PORT`, `MICROSOCKS_PORT` | Secret `cluster-settings` in every namespace (Flux substitutes them) |
| the keys in `apps/<ns>/<app>/secrets/secretspec.toml` | `just kube secrets`; the backup's (B2, restic) also `just kube restic` |
| `CLOUDFLARE_DNS_TOKEN` | cert-manager's DNS-01 (`apps/cert-manager/cert-manager/secrets`): a Cloudflare token with Zone.DNS:Edit and Zone:Read on the domain's zone only |

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

### 3. Secrets and Flux

```sh
just kube bootstrap   # just kube secrets, then Flux Operator + FluxInstance (helm)
just kube sync
just kube failing     # expect nothing; the first sync takes minutes (Helm charts)
just kube routes      # every Gateway and HTTPRoute accepted
```

Secrets go in first, so Flux never reconciles without `cluster-settings`.
The operator installs Flux, which syncs `kubernetes/flux/cluster`. Order is
enforced by `dependsOn`: gateway-api, then traefik; cloudnative-pg, then
postgres, then miniflux; cert-manager, then its ClusterIssuers, then the
wildcard certificate (Secret `wildcard-tls` in `traefik`). A rebuild issues
a new certificate: Let's Encrypt allows 5 for the same names per week.

### 4. Data not in git

Flux restores manifests; Secrets come from `pass`. The rest comes from the
nightly backup (04:00, `apps/backup/restic`): restic, encrypted with
`RESTIC_PASSWORD`, to a B2 bucket. It holds a `pg_dump` of the miniflux
database and `/opt/slskd` without `downloads/` and `incomplete/`; 7 daily, 4
weekly and 6 monthly snapshots. The media folders slskd shares are not backed
up. A failed run is reported on Telegram.

```sh
just kube restic snapshots                 # needs `brew install restic`

# miniflux, once postgres runs again
just kube restic dump latest /dump/miniflux.dump > /tmp/miniflux.dump
kubectl -n db exec -i postgres-1 -c postgres -- \
  pg_restore --clean --if-exists --no-owner --role=usrminiflux -d miniflux < /tmp/miniflux.dump
kubectl -n default rollout restart deploy/miniflux

# slskd's state
kubectl -n default scale deploy/slskd --replicas=0
just kube restic restore latest --include /data/slskd --target /tmp/restore
rsync -a --rsync-path='sudo rsync' /tmp/restore/data/slskd/ <node>:/opt/slskd/
kubectl -n default scale deploy/slskd --replicas=1
```

Run a backup now: `kubectl -n backup create job --from=cronjob/restic restic-manual`.

## Upgrades

Renovate (`.renovaterc.json5`) opens a PR for each new version of the items
below, labelled `type/major`, `type/minor`, `type/patch` or `type/digest`, and
the Check workflow builds it. Read the release notes before merging. The
labels are defined in `.github/labels.yaml`; the Label Sync workflow deletes
any other. By hand:

- **Flux:** `distribution.version` in
  `apps/flux-system/flux-instance/app/helmrelease.yaml` (2.9.x: patches apply
  on their own).
- **Charts:** `ref.tag` in the app's `app/ocirepository.yaml`.
- **Images:** `image.tag` in the app's `app/helmrelease.yaml`.
- **Gateway API CRDs:** `ref.tag` in
  `apps/kube-system/gateway-api/app/gitrepository.yaml`.

`just kube check` builds everything locally. Every HelmRelease gets the same
install, upgrade and rollback settings from `cluster-apps`
(`flux/cluster/ks.yaml`): a failed upgrade is retried twice and rolled back.

## Values shared with the server

- **The Soulseek port** is one pass key, `RATHOLE_SERVER_SERVICES_SLSKD_PORT`:
  the server's rathole and `ufw`, the rathole client's
  `[client.services.slskd]`, and slskd's Service and `listen_port` all read it.
  After changing it: `just server apply <host> rathole-server`,
  `just kube secrets`, `just kube sync`, then `bin/check-soulseek-port.py`.
  slskd is at home behind CGNAT, so peers must be sent to the server: the
  script checks the address Soulseek gives peers (the server's, not the
  home one), Soulseek's port test through the proxy, a peer handshake with
  slskd through the server's port, and the slskd and rathole-client pods.
- **The SOCKS5 proxy port** is `MICROSOCKS_PORT`, read by microsocks and by
  slskd's proxy settings.
- **SOCKS5 proxy credentials:** `SLSKD_SLSK_PROXY_*` equal `MICROSOCKS_*`.

## Troubleshooting

```sh
just kube failing
just kube routes
just kube events
just kube logs
just kube tree
just kube ui          # Flux web UI on http://localhost:9080, read-only
kubectl -n flux-system get fluxinstance flux
```

- A Kustomization fails with an unset variable: `cluster-settings` is
  missing in its namespace, or a literal `${` needs to be `$${`. Run
  `just kube secrets`.
- Pods read Secrets at start. Reloader restarts those annotated
  `reloader.stakater.com/auto: "true"` (miniflux, slskd, rathole-client)
  when `just kube secrets` changes a Secret they use; any other pod needs
  `kubectl -n <ns> rollout restart deploy/<app>`.
- The certificate isn't Ready: `kubectl -n traefik describe certificate wildcard`,
  then the `challenges` it lists (`kubectl get challenges -A`). A Cloudflare
  error there is usually the token (expired, or missing Zone.DNS:Edit);
  after replacing it in pass, `just kube secrets cert-manager`. To test
  without Let's Encrypt's production limits, point the Certificate's
  `issuerRef` at `letsencrypt-staging`.
