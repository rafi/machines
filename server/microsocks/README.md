# microsocks

[microsocks](https://github.com/rofl0r/microsocks) SOCKS5 proxy with
username/password authentication, for slskd's outgoing connections.

Deploy: `just server apply <host> microsocks`. With `USE_PACKAGE_MANAGER=1`
(as `server/mod.just` passes) the installer uses the Debian/Ubuntu package;
otherwise it builds `APP_VERSION` from source (needs `make` and a C compiler on
the host). It opens `MICROSOCKS_PORT` with `ufw`.

Keys are in [`secretspec.toml`](secretspec.toml); values come from pass.
