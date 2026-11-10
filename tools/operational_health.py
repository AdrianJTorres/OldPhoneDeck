"""Read-only, release-aware network checks for the existing operational health adapter.

No default configuration directory, credentials, deployment paths, lifecycle operations or
policy auto-detection. Callers supply verified release provenance and process liveness.
"""
import base64
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import socket
import ssl
import struct
import time
from urllib.parse import urlencode


class HealthFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise HealthFailure(message)


def _request(host, port, secure, path, token, context, deadline):
    timeout = min(2, max(0.01, deadline - time.monotonic()))
    conn = (http.client.HTTPSConnection(host, port, context=context, timeout=timeout)
            if secure else http.client.HTTPConnection(host, port, timeout=timeout))
    try:
        conn.request('GET', path + ('?' + urlencode({'k': token}) if token is not None else ''))
        if secure:
            require(hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
                    == context.expected_cert, 'HTTPS certificate identity changed')
        response = conn.getresponse()
        # http.client does not follow redirects. Reject before reading/returning a body.
        require(not 300 <= response.status < 400 and response.getheader('Location') is None,
                'Unexpected redirect')
        body = response.read(1024 * 1024 + 1)
        require(len(body) <= 1024 * 1024, 'Health response exceeds bound')
        return response.status, body, response.getheader('Content-Type', '')
    finally:
        conn.close()


def _exact(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count - len(data))
        require(bool(part), 'WSS closed unexpectedly')
        data += part
    return data


def _frame(sock, opcode, payload):
    require(len(payload) < 126, 'Health frame exceeds bound')
    mask = os.urandom(4)
    sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask
                 + bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))


def _websocket(port, token, context, deadline, live, invalid=False):
    def timeout():
        remaining = deadline - time.monotonic()
        require(remaining > 0, 'Health deadline exceeded')
        return min(2, remaining)

    with socket.create_connection(('127.0.0.1', port), timeout=timeout()) as raw:
        with context.wrap_socket(raw, server_hostname='127.0.0.1') as sock:
            require(hashlib.sha256(sock.getpeercert(binary_form=True)).hexdigest()
                    == context.expected_cert, 'WSS certificate identity changed')
            key = base64.b64encode(os.urandom(16)).decode()
            sock.sendall(('GET / HTTP/1.1\r\nHost: 127.0.0.1:' + str(port)
                          + '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                          + 'Sec-WebSocket-Key: ' + key
                          + '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
            header = b''
            while not header.endswith(b'\r\n\r\n'):
                sock.settimeout(timeout())
                header += _exact(sock, 1)
                require(len(header) < 16384, 'WSS header exceeds bound')
            require(header.split()[1] == b'101', 'WSS upgrade failed')
            fields = {line.split(b':', 1)[0].lower(): line.split(b':', 1)[1].strip()
                      for line in header.split(b'\r\n')[1:] if b':' in line}
            accept = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            require(fields.get(b'sec-websocket-accept') == accept, 'WSS accept mismatch')
            _frame(sock, 2, b'H' + token.encode())
            if invalid:
                try:
                    response = sock.recv(2)
                except (ssl.SSLEOFError, ConnectionResetError):
                    response = b''
                require(not response or response[0] & 15 == 8, 'WSS invalid token accepted')
                return
            authenticated = time.monotonic()
            while time.monotonic() - authenticated < 5.5:
                live()
                time.sleep(min(0.1, timeout()))
            _frame(sock, 9, b'ready')
            sock.settimeout(timeout())
            require(_exact(sock, 2) == b'\x8a\x05' and _exact(sock, 5) == b'ready',
                    'Authenticated WSS ping failed')
            _frame(sock, 8, struct.pack('!H', 1000))


def verify_health(config, document, web_hash, *, release, revision,
                  expected_certificate_sha256, ports, lan_hosts, live,
                  expected_shortcuts=None, started=None):
    """`release` must come from verified executable provenance, never an HTTP response.

    `live` must recheck process identity/listener ownership. Ports may be ephemeral in
    isolated fixtures; deployed ports are HTTP 8045, HTTPS 8047, WSS 8048.
    No POST/action, migration, repair, retry or credential regeneration is performed.
    """
    require(release in ('m5.1', 'm5.2'), 'Unknown release policy')
    hosts = tuple(lan_hosts)
    require(release != 'm5.2' or bool(hosts), 'M5.2 requires numeric LAN probe addresses')
    addresses = [ipaddress.ip_address(host) for host in hosts]
    require(all(not address.is_loopback and not address.is_unspecified
                and not (getattr(address, 'ipv4_mapped', None) is not None
                         and (address.ipv4_mapped.is_loopback or address.ipv4_mapped.is_unspecified))
                for address in addresses),
            'LAN denial probes require nonloopback numeric addresses')
    require(bool(revision) and bool(expected_certificate_sha256), 'Missing retained identity/revision')
    config = Path(config)
    original = (config / 'config.json').read_bytes()
    require(json.loads(original) == document, 'Stored configuration differs from expected document')
    token = (config / 'token').read_text().strip()
    require(bool(token) and token != 'invalid-health-probe', 'Invalid retained credential')
    context = ssl.create_default_context(cafile=str(config / 'tls/ca.pem'))
    context.expected_cert = expected_certificate_sha256
    current = hashlib.sha256(ssl.PEM_cert_to_DER_cert(
        (config / 'tls/server.pem').read_text())).hexdigest()
    require(current == expected_certificate_sha256, 'Retained certificate identity changed')
    deadline = (started if started is not None else time.monotonic()) + 30
    events = []

    def get(secure, path, credential, host='127.0.0.1'):
        require(time.monotonic() < deadline, 'Health deadline exceeded')
        live()
        return _request(host, ports['https' if secure else 'http'], secure,
                        path, credential, context, deadline)

    def authenticated(secure):
        status, page, _ = get(secure, '/', None)
        require(status == 200 and hashlib.sha256(page).hexdigest() == web_hash,
                'Secure deck resource differs' if secure else 'Rollback HTTP deck resource differs')
        for path in ('/info', '/launcher'):
            status, body, _ = get(secure, path, token)
            require(status == 200, 'Authenticated read endpoint failed')
            value = json.loads(body)
            require(isinstance(value, dict), 'Invalid authenticated response')
            if path == '/launcher':
                # Custom IDs (including key-1) can legitimately be unprojectable to legacy paths.
                require(value.get('configuration') in ('v2', 'unrepresentable')
                        and value.get('controlsWritable') is True, 'V2 controls are not writable')
                require(value.get('controls') == document['controls']
                        and value.get('widgets') == document['widgets']
                        and value.get('revision') == revision, 'Controls/widgets/revision changed')
                if expected_shortcuts is not None:
                    require(value.get('shortcuts') == expected_shortcuts, 'Shortcut catalogue changed')
            for wrong in (None, 'invalid-health-probe'):
                require(get(secure, path, wrong)[0] == 403, 'Invalid read credential accepted')
        events.append('HTTPS authenticated health' if secure else 'M5.1 HTTP compatibility')

    # A denial alone never establishes health: secure identity/data and WSS must pass first.
    authenticated(True)
    _websocket(ports['wss'], token, context, deadline, live)
    _websocket(ports['wss'], 'invalid-health-probe', context, deadline, live, invalid=True)
    events.append('WSS authentication/ping/invalid-token rejection')
    if release == 'm5.1':
        authenticated(False)
    else:
        for host, credential in [('127.0.0.1', token)] + [(host, 'invalid-health-probe') for host in hosts]:
            # Never transmit the real bearer on a LAN HTTP denial probe.
            for path in ('/info', '/launcher'):
                status, body, _ = get(False, path, credential, host)
                require(status == 403 and body == b'HTTPS required', 'HTTP transport denial missing')
        events.append('M5.2 HTTP denial (security result only)')
        for path in ('/', '/index.html'):
            status, body, _ = get(False, path, None, hosts[0])
            require(status == 200 and b'/oldphonedeck.mobileconfig' in body
                    and b'https://' in body and token.encode() not in body
                    and not any(value in body.lower() for value in (b'<script', b'<form', b'<input', b'?k=', b'#k=')),
                    'Credential-free HTTP onboarding failed')
    status, profile, _ = get(False, '/oldphonedeck.mobileconfig', None)
    require(status == 200, 'Public certificate profile unavailable')
    value = plistlib.loads(profile)
    ca_der = ssl.PEM_cert_to_DER_cert((config / 'tls/ca.pem').read_text())
    require(value['PayloadContent'][0]['PayloadContent'] == ca_der, 'Onboarding CA differs')
    events.append('Public certificate onboarding')
    # Read only the MJPEG preamble; the stream is deliberately not consumed to EOF.
    for credential in (None, 'invalid-health-probe', token):
        timeout = min(2, max(0.01, deadline - time.monotonic()))
        conn = http.client.HTTPConnection('127.0.0.1', ports['http'], timeout=timeout)
        try:
            conn.request('GET', '/camera.mjpg' + ('?' + urlencode({'k': credential}) if credential else ''))
            response = conn.getresponse()
            require(response.getheader('Location') is None, 'Unexpected camera redirect')
            if credential != token:
                require(response.status == 403, 'Camera invalid credential accepted')
            else:
                require(response.status == 200 and response.getheader('Content-Type', '').startswith(
                    'multipart/x-mixed-replace; boundary=frame') and response.read(9) == b'--frame\r\n',
                    'Loopback OBS/MJPEG preamble failed')
        finally:
            conn.close()
    events.append('Loopback authenticated OBS/MJPEG')
    live()
    require(time.monotonic() < deadline, 'Health deadline exceeded')
    require((config / 'config.json').read_bytes() == original, 'Configuration changed during health checks')
    return {'result': 'PASS', 'release_policy': release, 'revision': revision, 'events': events}
