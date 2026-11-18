# shadowsocks

[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
`ssserver` for slskd's outgoing connections: they leave from the server's
address, so the Soulseek server advertises it (not the home one behind
CGNAT). slskd talks plain SOCKS5 to an `sslocal` container in its pod, which
carries each connection here encrypted (`2022-blake3-aes-256-gcm`, a shared
key); without the key the port answers nothing useful.

Outbound connections reach the internet only: never the server's loopback
(rathole's tunnel ports, Gatus) or private and link-local networks, also
when a domain resolves to them. Two layers: the ACL
[`files/server.acl`](files/server.acl) and the unit's `IPAddressDeny=`,
which the kernel enforces. The latter blocks the local resolver too, so
ssserver resolves names at Cloudflare (`"dns"` in `files/config.json`).

Deploy: `just server apply <host> shadowsocks`. The installer downloads the
pinned release (`APP_VERSION`, default in `installer.sh`), opens
`SHADOWSOCKS_PORT` with `ufw` and hands the config, which holds the key, to
the unprivileged service as a systemd credential.

Keys are in [`secretspec.toml`](secretspec.toml); values come from pass and
are shared with the cluster (`kubernetes/apps/default/slskd/secrets`).
