# The server

The public server in front of the cluster: nginx (port 443 forwarding, port
80 redirect), the rathole server and a SOCKS5 proxy. Values come from
`pass` (`secretspec/machines/default/<KEY>`); nothing secret is in this repo.
Authelia and LLDAP run in the cluster (`kubernetes/apps/auth`). nginx only
forwards: TLS untouched to the cluster, SSH (`s.<domain>`) to the node.

## Create and set up

```sh
bin/create-server.sh <server-name>
just server setup root@<ip>   # etc/ files; ssh port from pass (SERVER_SSH_PORT)
```

## Apps

```sh
just server apply <host>              # every app; <host> is the server's SSH destination
just server apply <host> microsocks   # only the named apps
```

Each app is `server/<app>/`: its config in `files/` (rendered with
`server/<app>/secretspec.toml`), systemd units in `units/` and its
`installer.sh`. `mod.just` lists which apps run here and with which installer
options.

| App | Config (`server/<app>/files/`) | Values that identify the setup |
|---|---|---|
| ingress | `nginx.conf` (port 80 → HTTPS), `snippets/stream.nginx` (443: SSH and TLS passthrough to the cluster) | none |
| rathole-server | `server.toml`, `identity.pfx` (decoded from `RATHOLE_IDENTITY_PFX_B64`) | |
| microsocks | none | |

### microsocks

SOCKS5 proxy for slskd on the cluster. Behind CGNAT the Soulseek server would
advertise the home IP; through this proxy it advertises the server's, where rathole
forwards the listen port back. `MICROSOCKS_USER`/`MICROSOCKS_PASSWORD` must
equal `SLSKD_SLSK_PROXY_*` in pass.

### Authelia and LLDAP

Run in the cluster (`kubernetes/apps/auth`). LLDAP's users and groups, and
how to add one, are in `kubernetes/apps/auth/lldap/secrets/lldap-bootstrap.yaml`.

## Rathole TLS

```sh
bin/create-self-signed-cert.sh <password>
```

Store the results in pass: `identity.pfx` base64-encoded on one line as
`RATHOLE_IDENTITY_PFX_B64` (`base64 < identity.pfx | tr -d '\n' | pass insert -m
...`; only this goes to the server), `rootCA.crt` as `RATHOLE_ROOT_CA_CRT` (the
cluster trusts it), `rootCA.key` as `RATHOLE_ROOT_CA_KEY` (never deployed).
