# Kubernetes cluster

A single k3s node (Arch Linux, amd64), managed by Flux from this repo.
Pushing to `master` is the deploy. Values that git doesn't hold come from
`pass` (`secretspec/machines/default/<KEY>`):

| Key | Used by |
|---|---|
| `K3S_TOKEN`, `CLUSTER_NODE_IP`, `CLUSTER_NODE_NAME`, `SECRET_DOMAIN` | `just kube k3s-install` ([k3s/config.yaml](k3s/config.yaml)) |
| `K3S_KUBECONFIG` | `just kube kubeconfig`, `just kube kubeconfig-save` |
| `SECRET_DOMAIN`, `SEERR_HOSTNAME`, `SERVER_HOSTNAME`, `RATHOLE_SERVER_SERVICES_SLSKD_PORT` | Secret `cluster-settings` in every namespace (Flux substitutes them) |
| the keys in `apps/<ns>/<app>/secrets/secretspec.toml` | `just kube secrets`; the backup's (B2, restic) also `just kube restic` |
| `CLOUDFLARE_DNS_TOKEN` | cert-manager's DNS-01: a Cloudflare token with Zone.DNS:Edit and Zone:Read on the domain's zone only |

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

A new install has new certificates:

```sh
just kube kubeconfig-save <node>     # <node>: the node's SSH destination
just kube kubeconfig [name]          # merges it into your kubeconfig as <name> (default: CLUSTER_NODE_NAME)
kubectl get nodes
```

### 3. Secrets and Flux

Before the first start, create the hostPath directories of the apps that
run as 1000:1000 (slskd, LLDAP, Atuin, the CrowdSec web UI):
`ssh <node> sudo install -d -o 1000 -g 1000 /opt/slskd /opt/lldap /opt/atuin /opt/crowdsec-web-ui`.

```sh
just kube bootstrap   # just kube secrets, then Flux Operator + FluxInstance (helm)
just kube sync
just kube failing     # expect nothing; the first sync takes minutes (Helm charts)
just kube routes      # every Gateway and HTTPRoute accepted
```

Secrets go in first, so Flux never reconciles without `cluster-settings`.
The operator installs Flux, which syncs `kubernetes/flux/cluster`. Order is
enforced by `dependsOn`:

- gateway-api → traefik;
- traefik and the `o11y` forward-auth → kube-prometheus-stack →
  kube-prometheus-stack-rules, blackbox-exporter and `flux-system`'s alerts;
- cloudnative-pg → postgres → miniflux and authelia (which also waits for
  lldap);
- crowdsec → its web UI;
- cert-manager → its ClusterIssuers → the wildcard certificate (Secret
  `wildcard-tls` in `traefik`). A rebuild issues a new certificate: Let's
  Encrypt allows 5 for the same names per week.

### 4. Data not in git

The nightly backup (04:00, `apps/backup/restic`) sends restic snapshots,
encrypted with `RESTIC_PASSWORD`, to a B2 bucket, keeping 7 daily, 4 weekly
and 6 monthly; a failed run is reported on Telegram. It holds:

- `pg_dump`s of the miniflux and authelia databases;
- `/opt/slskd` without `downloads/` and `incomplete/`;
- `/opt/lldap` (LLDAP's users and groups);
- `/opt/atuin` (Atuin's SQLite database, copied live; its clients also keep
  their whole history).

Not backed up, and started over on a rebuild: slskd's shared media,
CrowdSec (its bans rebuild themselves; the web UI's settings), Prometheus's
metrics and Alertmanager's silences.

```sh
just kube restic snapshots                 # restic comes from `mise install`
kubectl -n backup create job --from=cronjob/restic restic-manual   # back up now

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

# A hostPath app: app=slskd ns=default, app=atuin ns=default or
# app=lldap ns=auth (LLDAP's key_seed in pass must be the backup's).
kubectl -n $ns scale deploy/$app --replicas=0
just kube restic restore latest --include /data/$app --target /tmp/restore
rsync -a --chown=1000:1000 --rsync-path='sudo rsync' /tmp/restore/data/$app/ <node>:/opt/$app/
kubectl -n $ns scale deploy/$app --replicas=1
```

## Upgrades

Renovate (`.renovaterc.json5`) opens a labelled PR for each new version;
the Check workflow renders and validates it and shows the rendered diff
against the base branch. Read the release notes before merging. Where
versions live:

- **Flux:** `distribution.version` in
  `apps/flux-system/flux-instance/app/helmrelease.yaml` (2.10.x: patches apply
  on their own).
- **Charts:** `ref.tag` in the app's `app/ocirepository.yaml`.
- **Images:** `image.tag` in the app's `app/helmrelease.yaml`.
- **Gateway API CRDs:** `ref.tag` in
  `apps/kube-system/gateway-api/app/gitrepository.yaml`.
- **Postgres:** `version.postgresql` in `apps/db/postgres/app/helmrelease.yaml`
  (held to 16.x, like the backup's `pg_dump`); a change restarts the instance
  for about a minute. Avoid 04:00 (the backup).
- **k3s:** not tracked by Renovate. Bump `k3s_version` in `mod.just`, then
  `just kube k3s-install <node>`, one minor at a time.

Before pushing: `just kube check` (renders and validates everything
offline), `just kube render hr <name>`, `just kube diff [base]`. A failed
upgrade is retried twice and rolled back (`cluster-apps`,
`flux/cluster/ks.yaml`).

## Values shared with the server

- **The Soulseek port** (`RATHOLE_SERVER_SERVICES_SLSKD_PORT`): the server's
  rathole and `ufw`, the rathole client, and slskd's Service and
  `listen_port`. After changing it: `just server apply <host> rathole-server`,
  `just kube secrets`, `just kube sync`, then `bin/check-soulseek-port.py`
  (checks the whole path from Soulseek's peers to slskd).
- **shadowsocks** (`SHADOWSOCKS_PORT`, `SHADOWSOCKS_PASSWORD`, a
  `2022-blake3-aes-256-gcm` key from `openssl rand -base64 32`): the server's
  `ssserver` and slskd's `sslocal`. After changing either:
  `just server apply <host> shadowsocks`, `just kube secrets slskd`.
- **The tunnel's `alertmanager` service:** the rathole client forwards
  `alertmanager-operated.o11y:9093` to the server's `127.0.0.1:32093`, which
  Gatus queries. After changing either end: `just kube secrets rathole-client`,
  `just server apply <host> rathole-server`.
- **The osewa port** (`OSEWA_PORT`, TCP and UDP): the server's rathole and
  `ufw`, the rathole client, and on the node both osewa, which must listen
  on it (its server advertises its own UDP port for QUIC), and moshi-hook,
  which tells Moshi where to dial. After changing it:
  `just server apply <host> rathole-server`,
  `just kube secrets rathole-client`, `just moshi serve` on the node (then
  `just moshi status`), and `just moshi login` on each laptop that opens
  the node's sessions from its terminal. `serve` picks the port by hostname:
  `OSEWA_PORT` on the node, osewa's default 7322 on a laptop (LAN or tailnet).

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

- **A Kustomization fails with an unset variable:** `cluster-settings` is
  missing in its namespace (run `just kube secrets`), or a literal `${` needs
  to be `$${`.
- **A changed Secret isn't picked up:** pods read Secrets at start. Reloader
  restarts those annotated `reloader.stakater.com/auto: "true"` (miniflux,
  slskd, rathole-client, lldap, authelia, crowdsec-web-ui; authelia also on
  its ConfigMap), and CrowdSec's LAPI and Traefik on their CrowdSec Secrets.
  Alertmanager reads its Telegram Secret at each send. Anything else:
  `kubectl -n <ns> rollout restart deploy/<app>`.
- **The certificate isn't Ready:** `kubectl -n traefik describe certificate wildcard`,
  then the challenges it lists (`kubectl get challenges -A`). A Cloudflare
  error is usually the token (expired, or missing Zone.DNS:Edit); after
  replacing it in pass, `just kube secrets cert-manager`. To test without
  Let's Encrypt's production limits, point the Certificate's `issuerRef` at
  `letsencrypt-staging`.
- **A site answers 403 to one address:** CrowdSec banned it. See why on
  `crowdsec.<domain>` or with
  `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list`;
  lift it with `cscli decisions delete --ip <ip>`. Traefik's bouncer pulls
  the ban list every minute and blocks nothing new while LAPI is down.
  Traefik fetches the bouncer plugin from GitHub at every start: if that
  fails, the new pod doesn't start
  (`kubectl -n traefik logs deploy/traefik -c fetch-crowdsec-bouncer`).
- **`KubeDeploymentReplicasMismatch` or `KubePodNotReady` for
  `crowdsec-agent` after a node reboot:** the pod kept its name and can't
  register it again ("user already exist",
  [helm-charts#252](https://github.com/crowdsecurity/helm-charts/issues/252),
  fixed by the chart's 2.0). Delete its machine, then the pod:
  `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli machines delete <agent pod name>`,
  then `kubectl -n crowdsec delete pod <agent pod name>`.
