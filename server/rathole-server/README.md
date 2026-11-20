# rathole-server

The server end of the [rathole](https://github.com/rapiz1/rathole) tunnel the
cluster's rathole client opens. Services: `ssh` (the node's sshd),
`ingress-tls` (Traefik's websecure port), `slskd` (the Soulseek port),
`osewa` and `osewa-quic` (the node's osewa, TCP and UDP on one public port)
and `alertmanager` (Alertmanager, on the server's loopback
`127.0.0.1:32093` only, for Gatus).

Deploy: `just server apply <host> rathole-server`. Keys are in
[`secretspec.toml`](secretspec.toml); values come from pass.
