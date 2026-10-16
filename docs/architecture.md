# Architecture

Two machines, one repository, no secrets in git.

- **The server** is a small public VPS. It forwards traffic into the
  cluster without decrypting it and proxies slskd's outgoing connections.
  Its services run under systemd and are deployed over SSH.
- **The cluster** is a single-node [k3s] cluster at home, behind CGNAT. It
  runs the applications. [Flux] reconciles it from this repository.
- **[pass]** holds every secret and every private value (domain, host names,
  emails, ports). [secretspec] reads them at deploy time; git only holds the
  key names.

```mermaid
flowchart LR
  ws["Workstation<br/>just + pass"]
  gh[("GitHub<br/>this repo")]
  subgraph vps["The server (public)"]
    nginx["nginx"]
    rs["rathole server"]
    socks["microsocks"]
  end
  subgraph home["The cluster (home, CGNAT)"]
    flux["Flux"] --> apps["apps"]
    rc["rathole client"]
    auth["Authelia + LLDAP"]
  end
  ws -- "git push" --> gh
  flux -- "pull" --> gh
  ws -- "just server apply (SSH)" --> vps
  ws -- "just kube secrets" --> home
  rc -- "outbound TLS tunnel" --> rs
```

## Traffic

The cluster has no public address. A [rathole] client inside the cluster
dials out to the server and holds a TLS tunnel open; the server exposes
the tunnel's services on local ports.

```mermaid
flowchart LR
  user(["Client"]) -- ":443" --> stream
  subgraph vps["The server"]
    stream["nginx stream<br/>ssl_preread, PROXY header"] -- "TLS (untouched)" --> rs["rathole server"]
    stream -- "not TLS (SSH)" --> rs
  end
  subgraph home["The cluster"]
    rc["rathole client"] -- ":443 TLS + PROXY" --> gw["Traefik<br/>Gateway (websecure)"] --> route["HTTPRoute"] --> svc["Service"]
    gw -. "ForwardAuth" .-> authelia["Authelia"] -. "LDAP" .-> lldap["LLDAP"]
    rc --> sshd["node sshd"]
  end
  rs == "tunnel (client-initiated)" === rc
```

1. **Port 443 is shared.** nginx's [stream module][ssl_preread] peeks at
   the first bytes of each connection and adds a PROXY protocol header with
   the client's address: SSH goes to the SSH service in the tunnel (the
   header stripped first), TLS untouched through the tunnel to Traefik.
   Port 80 only redirects to HTTPS. SSH uses `s.<domain>`.
   record of its own, like every other host).
2. **TLS ends in the cluster.** Traefik's `websecure` listener holds the
   wildcard certificate from cert-manager and reads the client's address
   from the PROXY header. The server holds no certificate for the sites.
3. **Authentication happens at the Gateway.** Protected routes use the
   `authelia` ForwardAuth Middleware
   ([`kubernetes/components/forward-auth`](../kubernetes/components/forward-auth));
   Authelia checks users against LLDAP and serves its portal at
   `auth.<domain>`.
4. **Routing happens in the cluster.** Each app attaches an `HTTPRoute` to
   `websecure`; `init.` and `req.` are redirect routes.

### Soulseek

[slskd] needs inbound peers and must not advertise the home address:

- **Outbound:** through the [microsocks] SOCKS5 proxy on the server, so peers
  see the server's address.
- **Inbound:** the listen port is a rathole service, so the server accepts
  the connection and the tunnel carries it to slskd.

Both ports come from pass and are shared by the server and the cluster; see
[Values shared with the server](../kubernetes/README.md#values-shared-with-the-server).

## The cluster

| Layer | Component |
|---|---|
| Distribution | [k3s], single node; its bundled Traefik and Helm controller are disabled ([`k3s/config.yaml`](../kubernetes/k3s/config.yaml)) |
| GitOps | [Flux], installed and upgraded by the [Flux Operator] from a `FluxInstance` |
| Ingress | [Traefik] implementing the [Gateway API]; its `websecure` listener terminates TLS for every host with the wildcard certificate |
| Certificates | [cert-manager]: `<domain>` + `*.<domain>` from Let's Encrypt, DNS-01 on Cloudflare with a token limited to the zone's DNS |
| Database | [CloudNativePG] operator and one Postgres cluster |
| Apps | [app-template] HelmReleases: echo, miniflux, slskd, rathole client, [LLDAP], [Authelia] (storage in Postgres) |
| Operations | [Reloader] restarts pods when their Secrets change; [Renovate] opens update PRs; CI runs `just kube check`; Flux errors go to Telegram |
| Backups | Nightly [restic] CronJob: `pg_dump`s of miniflux and authelia, `/opt/slskd` and `/opt/lldap`, encrypted on the node, to Backblaze B2 |

The FluxInstance makes Flux sync [`kubernetes/flux/cluster`](../kubernetes/flux/cluster), whose `cluster-apps`
Kustomization applies every namespace in
[`kubernetes/apps`](../kubernetes/apps), the layout of
[onedr0p/home-ops]:

```
kubernetes/apps/<namespace>/
├── kustomization.yaml     namespace + the apps' ks.yaml
├── namespace.yaml
└── <app>/
    ├── ks.yaml            Flux Kustomization (dependsOn, path)
    ├── app/               HelmRelease + chart source
    └── secrets/           Secret templates, applied by just, never by Flux
```

Dependencies are explicit `dependsOn` edges:

```mermaid
flowchart LR
  gw["gateway-api"] --> traefik --> echo & slskd & miniflux
  cnpg["cloudnative-pg"] --> postgres --> miniflux
  cm["cert-manager"] --> issuers["cert-manager-issuers"] --> certificate
```

Rebuild steps, upgrades and troubleshooting are in
[`kubernetes/README.md`](../kubernetes/README.md).

## Secrets and private values

```mermaid
flowchart LR
  pass[("pass")] --> ss["secretspec<br/>(keys in secretspec.toml)"]
  ss --> s1["just kube secrets<br/>→ Kubernetes Secrets"]
  ss --> s2["just kube secrets<br/>→ cluster-settings"]
  ss --> s3["just server apply<br/>→ rendered files + .env"]
  s2 -. "postBuild substitution" .-> flux["Flux"]
```

- **Nothing secret is in git**, encrypted or not. Each consumer has a
  `secretspec.toml` naming its keys; values live in `pass` under
  `secretspec/machines/default/<KEY>`.
- **Flux substitutes non-secret settings only**: `SECRET_DOMAIN`,
  `SERVER_HOSTNAME`, `SEERR_HOSTNAME`, `FLUX_TELEGRAM_CHAT_ID` (the alert
  chat) and slskd's two ports (`RATHOLE_SERVER_SERVICES_SLSKD_PORT`,
  `MICROSOCKS_PORT`), from the `cluster-settings` Secret in each namespace
  ([post-build substitution][flux-subst]). Strict substitution fails a
  Kustomization on any unknown `${VAR}`.
- **Secret values never pass through Flux.** `just kube secrets` renders the
  templates in `secrets/` and applies them server-side.
- **Rendering is scoped.** [envsubst] only replaces the keys of the
  matching spec, so nginx's `$host` or a shell's `$1` stay intact.
- **Binary secrets** (the rathole TLS identity) are stored base64-encoded;
  a rendered `*.b64` file is decoded with mode `600`.

## The server's apps

Each service on the server is one directory, deployed by `just server
apply` (`server/mod.just`):

```
server/<app>/
├── secretspec.toml     keys the app needs
├── files/              config, rendered at deploy
├── units/              systemd units, copied unrendered
└── installer.sh        runs on the server
```

A deploy:

```mermaid
sequenceDiagram
  participant W as Workstation
  participant P as pass
  participant S as The server
  W->>P: secretspec export --format shell (app's keys) → .env.sh
  W->>W: .env.sh → .env in EnvironmentFile= syntax
  W->>W: stage files/ in a temp dir, render, decode *.b64
  W->>W: add units/ (unrendered)
  W->>S: rsync to /tmp/<app>/
  W->>S: functions.sh + installer.sh over SSH stdin
  S->>S: install, validate config, restart, health check
```

Units stay unrendered: systemd expands their `${VAR}` from an
`EnvironmentFile` (the `.env`, written in systemd's own quoting by
`env_systemd`), so a rendered unit would hold the secret. Installers run with
`set -eux`; [`load_env`](../lib/functions.sh) sources the `.env.sh`, whose
values are single-quoted, with tracing paused.

## Provisioning

| Step | Command | Source |
|---|---|---|
| Create the server | `bin/create-server.sh` | DigitalOcean droplet |
| Harden it | `just server setup root@<ip>` | [`server/etc`](../server/etc): sshd, fail2ban, sysctl, Docker |
| Deploy its apps | `just server apply <host>` | [`server/mod.just`](../server/mod.just) |
| Install k3s | `just kube k3s-install` | [`kubernetes/k3s`](../kubernetes/k3s) |
| Bootstrap Flux | `just kube bootstrap` (runs `just kube secrets` first) | [`kubernetes/apps/flux-system`](../kubernetes/apps/flux-system) |

The server's host name and SSH port never appear in the repository: the
host is an argument (an SSH alias works), the port comes from `pass`.

## Decisions

| Decision | Why | Cost |
|---|---|---|
| Secrets only in `pass` | Nothing to leak from git, even if the repo goes public | Deploys need the workstation's GPG key |
| [just] instead of Ansible/Terraform | Plain shell, readable, no agent or state | Idempotency is each installer's job |
| Edge on a VPS, apps at home | CGNAT; home address stays private | One extra hop; the tunnel is a single point of failure |
| Auth at the Gateway | One login for every site (Traefik ForwardAuth to Authelia) | Cluster-internal traffic is not authenticated |
| Pinned, held packages | Upgrades only after reading release notes | Manual version bumps |

## References

- [k3s] · [Flux] · [Gateway API] · [Traefik] · [cert-manager] · [CloudNativePG] · [app-template] · [Reloader] · [Renovate] · [restic]
- [rathole] · [nginx `ssl_preread`][ssl_preread] · [Authelia] · [LLDAP] · [microsocks]
- [pass] · [secretspec] · [just] · [envsubst] · [Flux post-build substitution][flux-subst]
- [onedr0p/home-ops], whose cluster layout this follows

[app-template]: https://bjw-s-labs.github.io/helm-charts/docs/app-template/
[Authelia]: https://www.authelia.com/integration/proxies/traefik/
[cert-manager]: https://cert-manager.io
[CloudNativePG]: https://cloudnative-pg.io
[envsubst]: https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html
[Flux]: https://fluxcd.io
[Flux Operator]: https://fluxoperator.dev
[flux-subst]: https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution
[Gateway API]: https://gateway-api.sigs.k8s.io
[just]: https://just.systems
[k3s]: https://k3s.io
[LLDAP]: https://github.com/lldap/lldap
[microsocks]: https://github.com/rofl0r/microsocks
[onedr0p/home-ops]: https://github.com/onedr0p/home-ops
[pass]: https://www.passwordstore.org
[Reloader]: https://github.com/stakater/Reloader
[Renovate]: https://docs.renovatebot.com
[rathole]: https://github.com/rapiz1/rathole
[restic]: https://restic.net
[secretspec]: https://secretspec.dev
[slskd]: https://github.com/slskd/slskd
[ssl_preread]: https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html
[Traefik]: https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/
