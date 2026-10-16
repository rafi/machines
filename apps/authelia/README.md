# authelia

Authelia single sign-on. The one in use runs in the cluster
(`kubernetes/apps/auth/authelia`); these targets are standalone.

## Targets

- `kube/kubectl`: `just deploy kube authelia`
- `systemd`: `just deploy systemd authelia <host>`

## Values

Keys, descriptions and defaults are in [`secretspec.toml`](secretspec.toml);
values come from pass.
