# rathole-server

The server end of the [rathole](https://github.com/rapiz1/rathole) tunnel the
cluster's rathole client opens. Services: `ssh` (the node's sshd),
`ingress-tls` (Traefik's websecure port) and `slskd` (the Soulseek port).

Deploy: `just server apply <host> rathole-server`. Keys are in
[`secretspec.toml`](secretspec.toml); values come from pass.
