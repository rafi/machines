# shadowsocks

[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
`ssserver` for slskd's outgoing connections: they leave from the server's
address, so the Soulseek server advertises it (not the home one behind
CGNAT). slskd talks plain SOCKS5 to an `sslocal` container in its pod, which
carries each connection here encrypted (`2022-blake3-aes-256-gcm`, a shared
key); without the key the port answers nothing useful.

Deploy: `just server apply <host> shadowsocks`. The installer downloads the
pinned release (`APP_VERSION`, default in `installer.sh`), opens
`SHADOWSOCKS_PORT` with `ufw` and hands the config, which holds the key, to
the unprivileged service as a systemd credential.

Keys are in [`secretspec.toml`](secretspec.toml); values come from pass and
are shared with the cluster (`kubernetes/apps/default/slskd/secrets`).
