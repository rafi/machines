# Kubernetes cluster

A single k3s node (Arch Linux, amd64, k3s `v1.37.1+k3s1`), managed by Flux
from this repo. Pushing to `master` is the deploy. Values that git doesn't
hold come from `pass` (`secretspec/machines/default/<KEY>`):

| Key | Used by |
|---|---|
| `K3S_TOKEN`, `CLUSTER_NODE_IP`, `CLUSTER_NODE_NAME`, `SECRET_DOMAIN` | `just kube k3s-install` ([k3s/config.yaml](k3s/config.yaml)) |
| `K3S_KUBECONFIG` | `just kube kubeconfig`, `just kube kubeconfig-save` |
| `SECRET_DOMAIN`, `SEERR_HOSTNAME`, `FLUX_TELEGRAM_CHAT_ID`, `RATHOLE_SERVER_SERVICES_SLSKD_PORT` | Secret `cluster-settings` in every namespace (Flux substitutes them) |
| the keys in `apps/<ns>/<app>/secrets/secretspec.toml` | `just kube secrets`; the backup's (B2, restic) also `just kube restic` |
| `CLOUDFLARE_DNS_TOKEN` | cert-manager's DNS-01 (`apps/cert-manager/cert-manager/secrets`): a Cloudflare token with Zone.DNS:Edit and Zone:Read on the domain's zone only |

## Rebuild from scratch

### 1. k3s, from the workstation

```sh
ssh -t <node> sudo /usr/local/bin/k3s-uninstall.sh   # only when reinstalling
just kube k3s-install <node> [version]
ssh <node> systemctl status k3s
```

The recipe runs [k3s/install.sh](k3s/install.sh) on the node over SSH. It
stops on a host without the config's `bind-address` or with Arch's `k3s-bin`.
k3s's own Traefik, Helm controller, Gateway API CRDs, servicelb and
RuntimeClasses are disabled: Flux installs Traefik and the CRDs, and
nothing is a LoadBalancer (Traefik is reached through rathole only).
`K3S_TOKEN` only has to be kept to join more nodes.

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
postgres, then miniflux and authelia (which also waits for lldap); crowdsec,
then its web UI;
cert-manager, then its ClusterIssuers, then the wildcard certificate (Secret
`wildcard-tls` in `traefik`). A rebuild issues a new certificate: Let's
Encrypt allows 5 for the same names per week.

The CrowdSec web UI and Atuin run as 1000:1000 on a hostPath, like slskd and
LLDAP: before their first start,
`ssh <node> sudo install -d -o 1000 -g 1000 /opt/crowdsec-web-ui /opt/atuin`.

### 4. Data not in git

Flux restores manifests; Secrets come from `pass`. The rest comes from the
nightly backup (04:00, `apps/backup/restic`): restic, encrypted with
`RESTIC_PASSWORD`, to a B2 bucket. It holds `pg_dump`s of the miniflux and
authelia databases, `/opt/slskd` without `downloads/` and `incomplete/`,
`/opt/lldap` (LLDAP's users and groups) and `/opt/atuin` (Atuin's SQLite
database, copied live; its clients also keep their whole history); 7 daily,
4 weekly and 6 monthly snapshots. The media folders slskd shares are not
backed up. A failed run is reported on Telegram. CrowdSec is not backed up:
its bans and alerts (LAPI's PVCs in `crowdsec`) rebuild themselves, and the
web UI's settings (`/opt/crowdsec-web-ui`) start over.

```sh
just kube restic snapshots                 # restic comes from `mise install`

# miniflux, once postgres runs again
just kube restic dump latest /dump/miniflux.dump > /tmp/miniflux.dump
kubectl -n db exec -i postgres-1 -c postgres -- \
  pg_restore --clean --if-exists --no-owner --role=usrminiflux -d miniflux < /tmp/miniflux.dump
kubectl -n default rollout restart deploy/miniflux

# authelia (WebAuthn devices; the storage encryption key in pass must match)
just kube restic dump latest /dump/authelia.dump > /tmp/authelia.dump
kubectl -n db exec -i postgres-1 -c postgres -- \
  pg_restore --clean --if-exists --no-owner --role=authelia -d authelia < /tmp/authelia.dump
kubectl -n auth rollout restart deploy/authelia

# slskd's state (slskd runs as 1000:1000)
kubectl -n default scale deploy/slskd --replicas=0
just kube restic restore latest --include /data/slskd --target /tmp/restore
rsync -a --chown=1000:1000 --rsync-path='sudo rsync' /tmp/restore/data/slskd/ <node>:/opt/slskd/
kubectl -n default scale deploy/slskd --replicas=1

# LLDAP (runs as 1000:1000; its key_seed in pass must be the one the backup was made with)
kubectl -n auth scale deploy/lldap --replicas=0
just kube restic restore latest --include /data/lldap --target /tmp/restore
rsync -a --chown=1000:1000 --rsync-path='sudo rsync' /tmp/restore/data/lldap/ <node>:/opt/lldap/
kubectl -n auth scale deploy/lldap --replicas=1

# Atuin (runs as 1000:1000)
kubectl -n default scale deploy/atuin --replicas=0
just kube restic restore latest --include /data/atuin --target /tmp/restore
rsync -a --chown=1000:1000 --rsync-path='sudo rsync' /tmp/restore/data/atuin/ <node>:/opt/atuin/
kubectl -n default scale deploy/atuin --replicas=1
```

Run a backup now: `kubectl -n backup create job --from=cronjob/restic restic-manual`.

## Upgrades

Renovate (`.renovaterc.json5`) opens a PR for each new version of the items
below, labelled `type/major`, `type/minor`, `type/patch` or `type/digest`, and
the Check workflow renders and validates it; the run's summary shows the
rendered diff against the base branch. Read the release notes before
merging. The labels are defined in `.github/labels.yaml`; the Label Sync
workflow deletes any other. By hand:

- **Flux:** `distribution.version` in
  `apps/flux-system/flux-instance/app/helmrelease.yaml` (2.9.x: patches apply
  on their own).
- **Charts:** `ref.tag` in the app's `app/ocirepository.yaml`.
- **Images:** `image.tag` in the app's `app/helmrelease.yaml`.
- **Gateway API CRDs:** `ref.tag` in
  `apps/kube-system/gateway-api/app/gitrepository.yaml`.
- **Postgres:** `version.postgresql` in `apps/db/postgres/app/helmrelease.yaml`
  (held to 16.x, like the backup's `pg_dump`); a change restarts the instance
  (about a minute: `smartShutdownTimeout` is 15s, set by a post-renderer).
- **k3s:** not tracked by Renovate. Bump `k3s_version` in `mod.just` and the
  version above, then `just kube k3s-install <node>`, one minor at a time.

`just kube check` renders everything locally with flate, charts checked
against their schema and `kubeVersion` at `k3s_version`, then validates the
render against the Kubernetes and CRD schemas with kubeconform; `just kube
render hr <name>` prints one release, `just kube diff [base]` the change
against a revision. Every HelmRelease gets the same install, upgrade and
rollback settings from `cluster-apps` (`flux/cluster/ks.yaml`): a failed
upgrade is retried twice and rolled back.

## Values shared with the server

- **The Soulseek port** is one pass key, `RATHOLE_SERVER_SERVICES_SLSKD_PORT`:
  the server's rathole and `ufw`, the rathole client's
  `[client.services.slskd]`, and slskd's Service and `listen_port` all read it.
  After changing it: `just server apply <host> rathole-server`,
  `just kube secrets`, `just kube sync`, then `bin/check-soulseek-port.py`.
  slskd is at home behind CGNAT, so peers must be sent to the server: the
  script checks the address Soulseek gives peers (the server's, not the
  home one), Soulseek's port test through slskd's sslocal, a peer handshake
  with slskd through the server's port, and the slskd and rathole-client pods.
- **shadowsocks:** `SHADOWSOCKS_PORT` and `SHADOWSOCKS_PASSWORD` (the
  `2022-blake3-aes-256-gcm` key, `openssl rand -base64 32`) are read by the
  server's `ssserver` (`server/shadowsocks`) and by slskd's `sslocal`
  (Secret `sslocal-config`). After changing either:
  `just server apply <host> shadowsocks`, `just kube secrets slskd`.

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
  `reloader.stakater.com/auto: "true"` (miniflux, slskd, rathole-client, lldap,
  authelia, crowdsec-web-ui; authelia also on its ConfigMap), and CrowdSec's
  LAPI and Traefik on their CrowdSec Secrets
  when `just kube secrets` changes a Secret they use; any other pod needs
  `kubectl -n <ns> rollout restart deploy/<app>`.
- The certificate isn't Ready: `kubectl -n traefik describe certificate wildcard`,
  then the `challenges` it lists (`kubectl get challenges -A`). A Cloudflare
  error there is usually the token (expired, or missing Zone.DNS:Edit);
  after replacing it in pass, `just kube secrets cert-manager`. To test
  without Let's Encrypt's production limits, point the Certificate's
  `issuerRef` at `letsencrypt-staging`.
- A site answers 403 to one address: CrowdSec banned it. See why on
  `crowdsec.<domain>` or with
  `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list`;
  lift it with `cscli decisions delete --ip <ip>`. Traefik's bouncer pulls
  the ban list every minute; when LAPI is down it keeps the last list and
  blocks nothing else. Traefik fetches the bouncer plugin from GitHub at
  every start: if its `fetch-crowdsec-bouncer` init container fails, the new
  pod doesn't start (`kubectl -n traefik logs deploy/traefik -c fetch-crowdsec-bouncer`).
