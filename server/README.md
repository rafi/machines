# The server

The public server in front of the cluster. It runs no containers: each app
is a binary under systemd. Values come from `pass`
(`secretspec/machines/default/<KEY>`); nothing secret is in this repo.

## Create and set up

```sh
bin/create-server.sh <server-name>
just server setup root@<ip>   # etc/ files; ssh port from pass (SERVER_SSH_PORT)
```

## Apps

```sh
just server apply <host>              # every app; <host> is the server's SSH destination
just server apply <host> shadowsocks  # only the named apps
```

Each app is `server/<app>/`: its config in `files/` (rendered with
`server/<app>/secretspec.toml`), systemd units in `units/` and its
`installer.sh`. `mod.just` lists which apps run here and with which installer
options.

| App | What | Config (`files/`) |
|---|---|---|
| [ingress](ingress/README.md) | nginx: 443 passes SSH and TLS untouched to the cluster, 80 redirects to HTTPS | `nginx.conf`, `snippets/stream.nginx` |
| [rathole-server](rathole-server/README.md) | the server end of the cluster's tunnel | `server.toml`, `identity.pfx` (from `RATHOLE_IDENTITY_PFX_B64`) |
| [shadowsocks](shadowsocks/README.md) | slskd's outgoing connections, so peers see the server's address | `config.json`, `server.acl` |
| [gatus](gatus/README.md) | checks the cluster and the public sites from outside; UI on loopback | `config.yaml` |

Authelia and LLDAP run in the cluster (`kubernetes/apps/auth`).

## Rathole TLS

```sh
bin/create-self-signed-cert.sh <password>
```

Store the results in pass: `identity.pfx` base64-encoded on one line as
`RATHOLE_IDENTITY_PFX_B64` (`base64 < identity.pfx | tr -d '\n' | pass insert -m
...`; only this goes to the server), `rootCA.crt` as `RATHOLE_ROOT_CA_CRT` (the
cluster trusts it), `rootCA.key` as `RATHOLE_ROOT_CA_KEY` (never deployed).
