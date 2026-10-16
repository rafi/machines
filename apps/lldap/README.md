# lldap

LLDAP LDAP server. The one in use runs in the cluster
(`kubernetes/apps/auth/lldap`); these targets are standalone.

## Targets

- `kube/kubectl`: `just deploy kube lldap`
- `systemd`: `just deploy systemd lldap <host>`

## Values

Keys, descriptions and defaults are in [`secretspec.toml`](secretspec.toml);
values come from pass.
