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
good ones. History (a day of results, 200 events per check) is in
`/var/lib/gatus/data.db`. The UI listens on the server's loopback only:

```sh
ssh -N -L 8080:127.0.0.1:8080 <host>   # then http://localhost:8080
```

Deploy: `just server apply <host> gatus`. Gatus has no release binary: the
deploy takes `/gatus` from upstream's image `ghcr.io/twin/gatus` (with
`crane`) at the `GATUS_VERSION` of its line in [`../mod.just`](../mod.just);
bump it by hand.
