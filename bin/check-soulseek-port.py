#!/usr/bin/env python3
"""Check that Soulseek peers can reach slskd on its incoming port.

slskd runs at home behind CGNAT, so peers must be sent to the server
instead: slskd logs in to Soulseek through the server's microsocks, so the
Soulseek server records the server's address, and the server's port is
carried by rathole to slskd. The checks follow that path:

  1. What Soulseek tells peers: slskd's API asks the Soulseek server for
     our own user's address, which must be the server's address and port
     (not the home one). Needs the cluster; the kubeconfig comes from pass
     when kubectl doesn't reach it already.
  2. Soulseek's own port test, requested through microsocks so it probes
     the server's address, as a peer would.
  3. A peer handshake from this machine: PeerInit, then a user info
     request, which only slskd itself can answer.
  4. The slskd and rathole-client deployments are ready.

Values come from pass and are never printed. Standard library only.

  bin/check-soulseek-port.py
"""

import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

PORT_TEST = ('tools.slsknet.org', 80, '/porttest.php?port={port}')


class CheckFailed(Exception):
    """A check's failure, with the reason to print."""


def value(key):
    """A value from pass (secretspec/machines/default/<key>)."""
    return subprocess.run(['pass', 'show', f'secretspec/machines/default/{key}'],
                          check=True, capture_output=True, text=True).stdout.rstrip('\n')


def recv_exact(sock, n, closed_reason):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise CheckFailed(closed_reason)
        data += chunk
    return data


def kube_reachable(env):
    return subprocess.run(['kubectl', 'get', '--request-timeout=5s', 'namespace', 'default'],
                          env=env, capture_output=True).returncode == 0


def advertised_address(env, host, port):
    """Port-forward to slskd's Service, log in to its API and look up our own
    Soulseek user: the answer is the address the Soulseek server gives peers."""
    pf = subprocess.Popen(['kubectl', '-n', 'default', 'port-forward', 'svc/slskd', ':80'],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        # kubectl prints "Forwarding from 127.0.0.1:<port> -> 5030" when ready.
        match = re.search(r'127\.0\.0\.1:(\d+)', pf.stdout.readline())
        if not match:
            raise CheckFailed('no port-forward to svc/slskd')
        api = f'http://127.0.0.1:{match[1]}/slsk/api/v0'

        def call(path, body=None, token=None):
            req = urllib.request.Request(api + path, data=body and json.dumps(body).encode(),
                                         headers={'Content-Type': 'application/json'})
            if token:
                req.add_header('Authorization', 'Bearer ' + token)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)

        try:
            token = call('/session', {'username': value('SLSKD_USERNAME'),
                                      'password': value('SLSKD_PASSWORD')})['token']
            server = call('/server', token=token)
            if not server.get('isLoggedIn'):
                raise CheckFailed(f"slskd is not logged in to Soulseek (state: {server.get('state')})")
            user = urllib.parse.quote(value('SLSKD_SLSK_USERNAME'))
            ep = call(f'/users/{user}/endpoint', token=token)
        except OSError as e:
            raise CheckFailed(f"slskd's API: {e}")
    finally:
        pf.terminate()
        pf.wait()

    wrong = []
    if ep['address'] != socket.gethostbyname(host):
        wrong.append("a different address than the server's (is slskd's proxy on?)")
    if int(ep['port']) != port:
        wrong.append(f"port {ep['port']} instead of the rathole port")
    if wrong:
        raise CheckFailed('Soulseek gives peers ' + ' and '.join(wrong))
    return "the server's address and port"


def socks5_connect(proxy, user, password, target):
    """A TCP connection to target through a SOCKS5 proxy with a username and
    password (RFC 1928, RFC 1929); the proxy resolves the target's name."""
    sock = socket.create_connection(proxy, timeout=30)
    closed = 'the proxy closed the connection'
    try:
        sock.sendall(b'\x05\x01\x02')  # version 5, one method: username/password
        if recv_exact(sock, 2, closed) != b'\x05\x02':
            raise CheckFailed('the proxy refused username/password authentication')
        u, p = user.encode(), password.encode()
        sock.sendall(b'\x01' + bytes([len(u)]) + u + bytes([len(p)]) + p)
        if recv_exact(sock, 2, closed)[1] != 0:
            raise CheckFailed('the proxy rejected the login')
        name = target[0].encode()
        sock.sendall(b'\x05\x01\x00\x03' + bytes([len(name)]) + name + struct.pack('>H', target[1]))
        reply = recv_exact(sock, 4, closed)
        if reply[1] != 0:
            raise CheckFailed(f'the proxy could not connect to {target[0]} (reply {reply[1]})')
        # The bound address: IPv4, a name, or IPv6, then the port.
        size = {1: 4, 4: 16}.get(reply[3]) or recv_exact(sock, 1, closed)[0]
        recv_exact(sock, size + 2, closed)
        return sock
    except BaseException:
        sock.close()
        raise


def port_test(host, port):
    """tools.slsknet.org tests the port of the address that asks, so asking
    through microsocks tests the server's address."""
    proxy = (host, int(value('MICROSOCKS_PORT')))
    name, http_port, path = PORT_TEST
    try:
        with socks5_connect(proxy, value('MICROSOCKS_USER'), value('MICROSOCKS_PASSWORD'),
                            (name, http_port)) as sock:
            sock.sendall(f'GET {path.format(port=port)} HTTP/1.0\r\nHost: {name}\r\n\r\n'.encode())
            page = b''
            while chunk := sock.recv(65536):
                page += chunk
    except OSError as e:
        raise CheckFailed(f"through the server's SOCKS5 proxy: {e}")
    match = re.search(r'Port: \d+/tcp (\w+)', page.decode(errors='replace'), re.I)
    if not match:
        raise CheckFailed('unexpected page')
    if match[1].lower() != 'open':
        raise CheckFailed(f"{match[1].lower()} from the server's address")
    return "open from the server's address"


def string(s):
    b = s.encode()
    return struct.pack('<I', len(b)) + b


def message(code, payload=b''):
    return struct.pack('<I', len(code) + len(payload)) + code + payload


def peer_handshake(host, port):
    """Connect to the server's Soulseek port as a peer and ask for user info.

    Messages are little-endian: uint32 length, then the code (one byte for
    PeerInit, uint32 for peer messages), then the payload; strings are a
    uint32 length and the bytes."""
    try:
        sock = socket.create_connection((host, port), timeout=15)
    except ConnectionRefusedError:
        raise CheckFailed('connection refused: rathole-server is down or its tunnel '
                          'from the cluster is not established')
    except OSError as e:
        raise CheckFailed(f'no connection ({e}): the server or its firewall drops it')

    closed = 'connection accepted, then closed without an answer: rathole is up but slskd did not answer behind it'
    with sock:
        try:
            # PeerInit (code 1): username, connection type "P" (peer messages), token.
            sock.sendall(message(b'\x01', string('machines-port-check') + string('P') + struct.pack('<I', 0)))
            # UserInfoRequest (peer code 15), no payload.
            sock.sendall(message(struct.pack('<I', 15)))
            length, = struct.unpack('<I', recv_exact(sock, 4, closed))
            body = recv_exact(sock, length, closed)
        except socket.timeout:
            raise CheckFailed('connected, but no answer within 15s')
        except OSError as e:
            raise CheckFailed(f'{closed} ({e})')

    code, = struct.unpack_from('<I', body)
    if code != 16:
        raise CheckFailed(f'answered with peer message code {code}, expected 16 (UserInfoResponse)')
    # UserInfoResponse: description, has picture [, picture], upload slots,
    # queue length, has a free slot.
    n, = struct.unpack_from('<I', body, 4)
    pos = 8 + n
    has_picture = body[pos]
    pos += 1
    if has_picture:
        n, = struct.unpack_from('<I', body, pos)
        pos += 4 + n
    slots, queue = struct.unpack_from('<II', body, pos)
    return f'slskd answered ({slots} upload slots, {queue} queued)'


def deployments_ready(env):
    for ns, name in [('default', 'slskd'), ('rathole', 'rathole-client')]:
        ready = subprocess.run(
            ['kubectl', '-n', ns, 'get', 'deploy', name,
             '-o', 'jsonpath={.status.readyReplicas}/{.spec.replicas}'],
            env=env, capture_output=True, text=True).stdout
        yield f'deployment {ns}/{name}', ready == '1/1', ready or 'not found'


def main():
    host = value('SERVER_HOSTNAME')
    port = int(value('RATHOLE_SERVER_SERVICES_SLSKD_PORT'))
    failed = False

    def report(label, check, *args):
        nonlocal failed
        try:
            print(f'ok    {label}: {check(*args)}')
        except CheckFailed as e:
            failed = True
            print(f'FAIL  {label}: {e}')

    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ)
        cluster = kube_reachable(env)
        if not cluster:
            kubeconfig = os.path.join(tmp, 'kubeconfig')
            with open(os.open(kubeconfig, os.O_WRONLY | os.O_CREAT, 0o600), 'w') as f:
                f.write(value('K3S_KUBECONFIG'))
            env['KUBECONFIG'] = kubeconfig
            cluster = kube_reachable(env)

        if cluster:
            report('address given to peers', advertised_address, env, host, port)
        else:
            print("skip  address given to peers: kubectl doesn't reach the cluster")
        report("Soulseek's port test", port_test, host, port)
        report("peer handshake through the server's port", peer_handshake, host, port)
        if cluster:
            for label, ok, state in deployments_ready(env):
                print(f"{'ok  ' if ok else 'FAIL'}  {label}: {'ready' if ok else 'not ready (' + state + ')'}")
                failed |= not ok
        else:
            print("skip  pods: kubectl doesn't reach the cluster")

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
