# shadowsocks

[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
`ssserver` for slskd's outgoing connections: they leave from the server's
address, so the Soulseek server advertises it, not the home one behind
CGNAT. slskd talks SOCKS5 to an `sslocal` container in its pod, which
carries each connection here encrypted with a shared key
(`2022-blake3-aes-256-gcm`).

Outbound connections reach the internet only, never the server's loopback
(rathole's tunnel ports, Gatus) or private and link-local networks, even
through a domain that resolves to them. Two layers: the ACL
[`files/server.acl`](files/server.acl) and the unit's `IPAddressDeny=`. The
latter blocks the local resolver too, so ssserver resolves names at
Cloudflare (`"dns"` in `files/config.json`).

Deploy: `just server apply <host> shadowsocks`. The installer pins the
release (`APP_VERSION` in `installer.sh`) and opens `SHADOWSOCKS_PORT` with
`ufw`. The port and key are shared with slskd
(`kubernetes/apps/default/slskd/secrets`).
