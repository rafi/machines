# microsocks

[microsocks](https://github.com/rofl0r/microsocks) SOCKS5 proxy with
username/password authentication.

## Targets

- `systemd`: `just deploy systemd microsocks <host> [USE_PACKAGE_MANAGER=1]`

`USE_PACKAGE_MANAGER=1` installs the Debian/Ubuntu package; otherwise
`APP_VERSION` is built from source (needs `make` and a C compiler on the host).
The installer opens `MICROSOCKS_PORT` with `ufw`.

## Values

Keys are listed in [`.env.example`](.env.example). There is no
`secretspec.toml`: the consuming repo supplies the `.env` through
`EXTRA_FILES`.
