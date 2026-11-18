# gatus

[Gatus](https://github.com/TwiN/gatus) checks the cluster from outside it
and alerts on Telegram (the cluster's bot and chat) when the cluster can't:

- `cluster-alerting`: the cluster's Alertmanager, through the rathole tunnel
  (`127.0.0.1:32093`), has its always-firing `Watchdog` alert active and not
  silenced. Down when the tunnel, Prometheus or Alertmanager is.
- One endpoint per public app (`auth`, `ldap`, `crowdsec`, `atuin`, `grafana`,
  `home/miniflux`, `home/slsk`): status 200 or 302 (Authelia's login,
  redirects not followed), certificate valid for more than 7 days.

An alert fires after 3 failed checks (1 minute apart) and resolves after 2
good ones. The UI and API listen on loopback only, `127.0.0.1:8080`; history
is in `/var/lib/gatus/data.db` (SQLite).

Gatus has no release binary: `just server apply` takes `/gatus` from
upstream's image `ghcr.io/twin/gatus` (with `crane`) at the `GATUS_VERSION`
of its deploy line in [`../mod.just`](../mod.just). Bump it by hand.

Deploy: `just server apply <host> gatus`. Keys are in
[`secretspec.toml`](secretspec.toml); values come from pass. UI:

```sh
ssh -L 8080:127.0.0.1:8080 <host>   # then http://localhost:8080
```
