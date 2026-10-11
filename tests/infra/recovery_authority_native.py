"""Run with pinned Synapse Python, --add-host business-api:127.0.0.1, no network.

Uses real Twisted HTTP and the unmodified Authority/handle methods. Matrix auth
and DB are explicit doubles; real PostgreSQL races run in the separate PG suite.
No production credentials, keyring, database or request are used.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

from twisted.internet import defer, task
from twisted.web import resource, server
from twisted.web.http_headers import Headers

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'third_party/synapse'))
from chatflow_recovery_crypto import canonical, encode
from chatflow_recovery_store import VaultError

source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'third_party/synapse/chatflow_recovery_vault.py'
spec = importlib.util.spec_from_file_location('native_vault_candidate', source)
vault = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vault)


async def run(reactor):
    metadata = dict(matrix_user_id='@synthetic:matrix.test', matrix_device_id='D', family_id='F', generation=1)
    state = dict(mode='ok', calls=0, revoked=False)

    class Business(resource.Resource):
        isLeaf = True

        def render_POST(self, request):
            state['calls'] += 1
            assert request.path == b'/api/v1/auth/matrix-recovery-authorize'
            assert request.getHeader('Authorization') == 'Bearer synthetic-business'
            assert json.loads(request.content.read()) == {k: metadata[k] for k in ('matrix_user_id', 'matrix_device_id')}
            mode = state['mode']
            if mode == 'timeout':
                # Observe cancellation without emitting request/credential diagnostics.
                request.notifyFinish().addErrback(lambda _: None)
                return server.NOT_DONE_YET
            if mode == 'revoked_native':
                state['revoked'] = True
            if mode == 'revoked_business' and state['calls'] == 2:
                request.setResponseCode(403)
                return b'{}'
            if mode in ('401', '403', '409', '429', '500'):
                request.setResponseCode(int(mode))
                return b'{}'
            if mode == 'invalid_json':
                return b'invalid'
            if mode == 'wrong_binding':
                return canonical({**metadata, 'matrix_device_id': 'WRONG'})
            return canonical(metadata)

    site = server.Site(Business())
    site.log = lambda request: None
    listener = reactor.listenTCP(8082, site, interface='127.0.0.1')
    authority = vault.Authority(SimpleNamespace(_hs=SimpleNamespace(get_reactor=lambda: reactor)))

    async def matrix(request):
        if state['revoked']:
            raise VaultError(401, 'M_UNAUTHORIZED')
        expected = {b'Authorization': b'Bearer synthetic-matrix', b'X-StarChat-Session': b'Bearer synthetic-business'}
        for name, value in expected.items():
            if request.requestHeaders.getRawHeaders(name, []) != [value]:
                raise VaultError(401, 'M_UNAUTHORIZED')
        return metadata['matrix_user_id'], metadata['matrix_device_id'], expected[b'X-StarChat-Session']

    authority.matrix = matrix

    def request(missing=None):
        headers = {b'Authorization': [b'Bearer synthetic-matrix'], b'X-StarChat-Session': [b'Bearer synthetic-business']}
        headers.pop(missing, None)
        result = SimpleNamespace(path=(vault.PRIVATE_BASE + '/status').encode(), method=b'GET',
                                 content=io.BytesIO(), requestHeaders=Headers(headers), headers={})
        result.setHeader = lambda key, value: result.headers.update({key: value})
        return result

    checks = 0
    try:
        # This exact request fails against the old8000 constant; no URL rewriting.
        assert await authority.verify(request()) == metadata
        checks += 1
        for missing in (b'Authorization', b'X-StarChat-Session'):
            before = state['calls']
            try:
                await authority.verify(request(missing))
            except VaultError as error:
                assert error.status == 401 and state['calls'] == before
            else:
                raise AssertionError('missing credential accepted')
            checks += 1
        for mode, expected_status in [('401', 403), ('403', 403), ('409', 403), ('429', 429),
                                      ('500', 503), ('invalid_json', 503), ('wrong_binding', 503),
                                      ('revoked_native', 401), ('timeout', 503)]:
            state.update(mode=mode, calls=0, revoked=False)
            start = reactor.seconds()
            try:
                await authority.verify(request())
            except VaultError as error:
                assert error.status == expected_status, (mode, error.status)
                if mode == 'timeout':
                    assert 4.5 <= reactor.seconds() - start <= 7
            else:
                raise AssertionError('dependency fault accepted: ' + mode)
            checks += 1

        with tempfile.TemporaryDirectory(prefix='im-r1-synthetic-') as directory:
            ring = Path(directory) / 'ring.json'
            ring.write_bytes(canonical({'format': 1, 'active': 'test', 'keys': {'test': {
                'key': encode(os.urandom(32)), 'state': 'active_for_writes', 'confirmation': 'a' * 64}}}))
            ring.chmod(0o600)
            module = object.__new__(vault.RecoveryVaultModule)
            module.config = {'enabled': True, 'keyring_path': str(ring)}
            module.authority, module.buckets = authority, {}
            module.store = SimpleNamespace(status=object())

            async def read_only_db(function, owner):
                assert function is module.store.status and owner == metadata['matrix_user_id']
                return {'state': 'absent', 'collection': None}

            module.db = read_only_db
            for mode, expected in [('ok', 200), ('revoked_business', 403)]:
                state.update(mode=mode, calls=0, revoked=False)
                req = request()
                status, body = await module.handle(req)
                assert status == expected and state['calls'] == 2
                assert req.headers[b'Cache-Control'] == b'no-store'
                assert 'private_key' not in body
                checks += 1
        print(json.dumps({'result': 'PASS', 'checks': checks, 'transport': 'real Twisted HTTP',
                          'port': 8082, 'matrix_auth': 'explicit double', 'database': 'explicit read-only double'}))
    finally:
        await listener.stopListening()


if __name__ == '__main__':
    task.react(lambda reactor: defer.ensureDeferred(run(reactor)))
