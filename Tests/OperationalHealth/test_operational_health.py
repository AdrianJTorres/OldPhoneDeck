"""Focused health-policy tests. Native fixture mode is invoked by Swift Testing."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import ssl
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('operational_health', ROOT / 'tools/operational_health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HealthPolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name)
        (self.config / 'tls').mkdir()
        self.document = {'version': 2, 'controls': [{'id': 'key-1'}],
                         'widgets': {'internet': True, 'batteries': True}}
        (self.config / 'config.json').write_text(json.dumps(self.document))
        (self.config / 'token').write_text('synthetic-health-token')
        (self.config / 'tls/ca.pem').write_text('fixture-cert')
        (self.config / 'tls/server.pem').write_text('fixture-cert')
        self.params = dict(config=self.config, document=self.document, web_hash=hashlib.sha256(b'deck').hexdigest(),
                           release='m5.2', revision='synthetic-revision', expected_certificate_sha256=hashlib.sha256(b'cert').hexdigest(),
                           ports={'http': 1, 'https': 2, 'wss': 3}, lan_hosts=['192.0.2.1'], live=lambda: None)

    def fake_request(self, host, port, secure, path, token, context, deadline):
        if secure or self.params['release'] == 'm5.1':
            if path == '/':
                return 200, b'deck', 'text/html'
            if token != 'synthetic-health-token':
                return 403, b'bad token', 'text/plain'
            data = {} if path == '/info' else dict(configuration='unrepresentable', controlsWritable=True,
                controls=self.document['controls'], widgets=self.document['widgets'], revision='synthetic-revision')
            return 200, json.dumps(data).encode(), 'application/json'
        if path in ('/info', '/launcher'):
            return 403, b'HTTPS required', 'text/plain'
        if path == '/oldphonedeck.mobileconfig':
            return 200, plistlib.dumps({'PayloadContent': [{'PayloadContent': b'cert'}]}), 'application/x-apple-aspen-config'
        return 200, b'<a href="/oldphonedeck.mobileconfig">Profile</a><a href="https://fixture/">HTTPS</a>', 'text/html'

    def invoke(self, request=None, websocket=None):
        with patch.object(health.ssl, 'create_default_context', return_value=types.SimpleNamespace()), \
             patch.object(health.ssl, 'PEM_cert_to_DER_cert', return_value=b'cert'), \
             patch.object(health, '_request', side_effect=request or self.fake_request), \
             patch.object(health, '_websocket', side_effect=websocket):
            return health.verify_health(**self.params)

    def test_http_redirect_is_rejected_without_following_or_reading_body(self):
        conn = unittest.mock.MagicMock()
        response = conn.getresponse.return_value
        response.status = 302
        response.getheader.return_value = 'https://untrusted/?k=synthetic'
        with patch.object(health.http.client, 'HTTPConnection', return_value=conn):
            with self.assertRaises(health.HealthFailure):
                health._request('192.0.2.1', 1, False, '/', None, None, health.time.monotonic() + 5)
        conn.request.assert_called_once_with('GET', '/')
        response.read.assert_not_called()
        conn.close.assert_called_once()

    def test_wrong_https_peer_certificate_fails(self):
        conn = unittest.mock.MagicMock()
        conn.sock.getpeercert.return_value = b'wrong-peer'
        context = types.SimpleNamespace(expected_cert='0' * 64)
        with patch.object(health.http.client, 'HTTPSConnection', return_value=conn):
            with self.assertRaises(health.HealthFailure):
                health._request('127.0.0.1', 2, True, '/info', 'synthetic', context, health.time.monotonic() + 5)
        conn.getresponse.assert_not_called()

    def test_http_denial_cannot_mask_failed_https(self):
        with self.assertRaises(health.HealthFailure):
            self.invoke(request=lambda *args: (403, b'HTTPS required', 'text/plain'))

    def test_http_denial_cannot_mask_failed_wss(self):
        with self.assertRaises(health.HealthFailure):
            self.invoke(websocket=health.HealthFailure('WSS unavailable'))

    def test_certificate_mismatch_fails_before_network(self):
        self.params['expected_certificate_sha256'] = '0' * 64
        with self.assertRaises(health.HealthFailure):
            self.invoke()

    def test_unknown_release_never_falls_back_to_m51(self):
        self.params['release'] = 'auto'
        with self.assertRaises(health.HealthFailure):
            self.invoke()

    def test_mapped_loopback_is_not_a_lan_probe(self):
        self.params['lan_hosts'] = ['::ffff:127.0.0.1']
        with self.assertRaises(health.HealthFailure):
            self.invoke()

    def test_https_invalid_token_acceptance_fails(self):
        def unsafe(*args):
            if args[2] and args[3] == '/info':
                return 200, b'{}', 'application/json'
            return self.fake_request(*args)
        with self.assertRaises(health.HealthFailure):
            self.invoke(request=unsafe)

    def test_m52_exposure_is_not_accepted_as_rollback(self):
        def unsafe(*args):
            if not args[2] and args[3] == '/info':
                return 200, b'{}', 'application/json'
            return self.fake_request(*args)
        with self.assertRaises(health.HealthFailure):
            self.invoke(request=unsafe)

    def test_nonprojectable_custom_ids_pass_secure_validation(self):
        # Stop after the authenticated portion, before public/stream probes.
        class SecureChecksPassed(Exception):
            pass
        with self.assertRaises(SecureChecksPassed):
            self.invoke(websocket=SecureChecksPassed())

    def test_m51_retains_http_reads_after_secure_health(self):
        self.params['release'] = 'm5.1'
        calls = []
        def record(*args):
            calls.append((args[2], args[3]))
            if not args[2] and args[3] == '/oldphonedeck.mobileconfig':
                raise StopIteration('rollback HTTP reads passed')
            return self.fake_request(*args)
        with self.assertRaises(StopIteration):
            self.invoke(request=record)
        self.assertIn((False, '/info'), calls)
        self.assertIn((False, '/launcher'), calls)
        self.assertLess(calls.index((True, '/info')), calls.index((False, '/info')))

    def test_lan_probe_never_receives_real_bearer(self):
        def record(*args):
            if args[0] != '127.0.0.1':
                self.assertNotEqual(args[4], 'synthetic-health-token')
                if args[3] == '/':
                    raise StopIteration('LAN denial probes passed')
            return self.fake_request(*args)
        with self.assertRaises(StopIteration):
            self.invoke(request=record)


if __name__ == '__main__':
    if '--fixture' not in sys.argv:
        unittest.main()
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument('--fixture', required=True)
        parser.add_argument('--staged')
        args = parser.parse_args()
        fixture = Path(args.fixture)
        values = json.loads((fixture / 'probe.json').read_text())
        values['web_hash'] = hashlib.sha256(values['web_body'].encode()).hexdigest()
        values['certificate_sha256'] = hashlib.sha256(ssl.PEM_cert_to_DER_cert(
            (fixture / 'tls/server.pem').read_text())).hexdigest()
        if args.staged:
            # Import the staged adapter, never the installed helper. Only the process
            # adapter is fake for this in-process Swift fixture; network and TLS are real.
            sys.path.insert(0, args.staged)
            import legacy
            record = {'pid': 0, 'binary': 'fixture', 'args': [], 'start': 'fixture',
                      'binary_sha256': 'fixture', 'cwd': 'fixture', 'uid': 0, 'gid': 0,
                      'port': values['ports']['http'], 'health_ports': values['ports']}
            legacy.o.identity = lambda *unused: record
            legacy.o.listeners = lambda *unused, **ignored: None
            receipt = legacy.health(record, fixture, values['document'], values['web_hash'],
                True, values['revision'], release=values['release'], lan_hosts=values['lan_hosts'],
                expected_certificate_sha256=values['certificate_sha256'])
        else:
            receipt = health.verify_health(fixture, values['document'], values['web_hash'],
                release=values['release'], revision=values['revision'],
                expected_certificate_sha256=values['certificate_sha256'],
                ports=values['ports'], lan_hosts=values['lan_hosts'], live=lambda: None,
                expected_shortcuts=[])
        print(json.dumps(receipt))
