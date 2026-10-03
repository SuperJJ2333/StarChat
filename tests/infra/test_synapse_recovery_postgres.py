"""Real PostgreSQL, two independent connections; only task-owned random schema."""
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import uuid

import psycopg
from psycopg import sql
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'third_party/synapse'))
from chatflow_recovery_crypto import ALGORITHM, generate_envelope, unwrap
from chatflow_recovery_migrate import migrate
from chatflow_recovery_store import VaultStore

DSN = os.environ.get('CHATFLOW_RECOVERY_TEST_DSN')
pytestmark = pytest.mark.skipif(not DSN, reason='explicit isolated PostgreSQL DSN required')


class Txn:
    def __init__(self, cursor): self.cursor = cursor
    def execute(self, query, params=()): self.cursor.execute(query.replace('?', '%s'), params)
    def fetchone(self): return self.cursor.fetchone()
    def fetchall(self): return self.cursor.fetchall()
    @property
    def rowcount(self): return self.cursor.rowcount


@pytest.fixture
def database():
    name = 'task_3a_' + uuid.uuid4().hex
    with psycopg.connect(DSN, autocommit=True) as connection:
        connection.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(name)))
    def connect():
        conn = psycopg.connect(DSN)
        conn.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(name)))
        conn.commit()
        return conn
    with connect() as conn: migrate(conn)
    yield connect
    assert name.startswith('task_3a_') and len(name) == 40
    with psycopg.connect(DSN, autocommit=True) as connection:
        connection.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(name)))


def execute(connect, method, *args):
    with connect() as conn:
        with conn.cursor() as cursor:
            return method(Txn(cursor), *args)


def enrollment(connect, operation=None):
    owner = '@a:matrix.test'
    envelope = generate_envelope('matrix.test', owner, str(uuid.uuid4()), 'key', os.urandom(32))
    op = operation or str(uuid.uuid4())
    return execute(connect, VaultStore().enroll, owner, 'DEVICE', 7, op, 'digest', envelope)


def test_two_connections_enroll_one_immutable_owner_and_replay_response_loss(database):
    operation = str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: enrollment(database, operation), range(2)))
    assert sorted(result[0] for result in results) == [200, 201]
    assert results[0][1] == results[1][1]
    assert enrollment(database, operation)[1] == results[0][1]
    from chatflow_recovery_store import VaultError
    with pytest.raises(VaultError) as failed: enrollment(database)
    assert failed.value.code == 'M_VAULT_EXISTS'
    with database() as conn:
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_versions').fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_audit').fetchone()[0] == 1


def test_crash_before_commit_leaves_no_pointer_or_operation(database):
    class Crash(Exception): pass
    owner = '@a:matrix.test'
    with pytest.raises(Crash):
        with database() as conn:
            with conn.cursor() as cursor:
                VaultStore().enroll(Txn(cursor), owner, 'DEVICE', 1, str(uuid.uuid4()), 'digest',
                    generate_envelope('matrix.test', owner, str(uuid.uuid4()), 'k', os.urandom(32)))
                raise Crash()
    with database() as conn:
        for table in ('accounts', 'versions', 'operations', 'audit'):
            assert conn.execute('SELECT count(*) FROM chatflow_recovery_' + table).fetchone()[0] == 0
    assert enrollment(database)[0] == 201


def test_migration_repeat_does_not_touch_synapse_head(database):
    with database() as conn:
        conn.execute('CREATE TABLE schema_version(version BIGINT)')
        conn.execute('INSERT INTO schema_version VALUES (92)')
        conn.commit()
        migrate(conn)
        migrate(conn)
        assert conn.execute('SELECT version FROM schema_version').fetchone() == (92,)
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_migrations').fetchone() == (1,)


def upload_body(public, index=10, expected=0):
    from chatflow_recovery_crypto import encode
    return {'algorithm': ALGORITHM, 'public_key': public, 'sessions': [{
        'room_id': '!room:matrix.test', 'session_id': 'session', 'expected_revision': expected,
        'first_message_index': index, 'forwarded_count': 0, 'is_verified': False,
        'session_data': {'ephemeral': encode(os.urandom(32)), 'mac': encode(os.urandom(8)),
                         'ciphertext': encode(os.urandom(48))}}]}


def test_two_writer_cas_atomic_receipts_idempotency_and_retained_candidates(database):
    from chatflow_recovery_store import VaultError, digest
    _, info = enrollment(database)
    store, owner = VaultStore(), '@a:matrix.test'
    body = upload_body(info['public_key'])
    def upload(body, operation):
        try:
            return execute(database, store.upload, owner, 'DEVICE', 7, info['version'], operation, digest(body), body)
        except VaultError as error:
            return error
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        outcomes = list(pool.map(lambda _: upload(body, str(uuid.uuid4())), range(2)))
    assert sum(isinstance(item, dict) for item in outcomes) == 1
    assert [item.code for item in outcomes if isinstance(item, VaultError)] == ['M_REVISION_CONFLICT']
    op = str(uuid.uuid4())
    body2 = upload_body(info['public_key'], index=0, expected=1)
    accepted = upload(body2, op)
    assert accepted['receipts'][0]['revision'] == 2
    assert upload(body2, op) == accepted  # response lost, exact payload replay
    assert upload(upload_body(info['public_key'], index=1, expected=2), op).code == 'M_IDEMPOTENCY_CONFLICT'
    result = execute(database, store.query, owner, info['version'], [{'room_id': '!room:matrix.test', 'session_id': 'session'}])
    assert [item['first_message_index'] for item in result['candidates']] == [0, 10]
    with database() as conn:
        raw = conn.execute('SELECT receipt FROM chatflow_recovery_operations').fetchall()
        assert all('ciphertext' not in receipt[0] and 'private_key' not in receipt[0] for receipt in raw)


def test_query_pages_are_bounded_omitted_pairs_are_not_missing(database):
    from chatflow_recovery_store import digest
    _, info = enrollment(database)
    store, owner = VaultStore(), '@a:matrix.test'
    for revision in range(18):
        body = upload_body(info['public_key'], index=revision, expected=revision)
        execute(database, store.upload, owner, 'DEVICE', 7, info['version'], str(uuid.uuid4()), digest(body), body)
    query = [{'room_id': '!room:matrix.test', 'session_id': 'session'}, {'room_id': '!room:matrix.test', 'session_id': 'missing'}]
    first = execute(database, store.query, owner, info['version'], query)
    assert len(first['candidates']) == 16 and first['missing'] == []
    last = execute(database, store.query, owner, info['version'], query, first['continuation'])
    assert len(last['candidates']) == 2 and last['missing'] == [query[1]] and last['continuation'] is None


def test_mid_rewrap_crash_and_mixed_backup_restore_same_private_keys(database):
    from chatflow_recovery_crypto import canonical
    store, keys = VaultStore(), {'old': os.urandom(32), 'new': os.urandom(32)}
    originals = {}
    for n in range(3):
        owner = '@%s:matrix.test' % n
        envelope = generate_envelope('matrix.test', owner, str(uuid.uuid4()), 'old', keys['old'])
        originals[owner] = unwrap(envelope, keys)
        execute(database, store.enroll, owner, 'DEVICE', 7, str(uuid.uuid4()), 'digest', envelope)
    assert execute(database, store.rewrap_batch, 'old', 'new', keys, 1) == 1
    class Crash(Exception): pass
    with pytest.raises(Crash):
        with database() as conn:
            with conn.cursor() as cursor:
                store.rewrap_batch(Txn(cursor), 'old', 'new', keys, 1)
                raise Crash()
    with database() as conn:
        backup = conn.execute('SELECT owner,envelope FROM chatflow_recovery_versions').fetchall()
    assert {json.loads(raw)['key_id'] for _, raw in backup} == {'old', 'new'}
    assert {owner: unwrap(json.loads(raw), keys) for owner, raw in backup} == originals


def test_unknown_owner_version_and_quota_preserve_material(database):
    from chatflow_recovery_store import VaultError, digest
    _, info = enrollment(database)
    store, owner = VaultStore(), '@a:matrix.test'
    for who, version in [(owner, str(uuid.uuid4())), ('@b:matrix.test', info['version'])]:
        with pytest.raises(VaultError) as caught:
            execute(database, store.material, who, version)
        assert (caught.value.status, caught.value.code) == (404, 'M_NOT_FOUND')
    store.MAX_CANDIDATES = 0
    body = upload_body(info['public_key'])
    with pytest.raises(VaultError) as caught:
        execute(database, store.upload, owner, 'D', 7, info['version'], str(uuid.uuid4()), digest(body), body)
    assert caught.value.code == 'M_VAULT_QUOTA_EXCEEDED'
    with database() as conn:
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_sessions').fetchone()[0] == 0
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_operations').fetchone()[0] == 1


def test_operation_journal_quota_rolls_back_entire_upload(database):
    from chatflow_recovery_store import VaultError, digest
    _, info = enrollment(database)
    store = VaultStore()
    store.MAX_OPERATIONS = 1
    body = upload_body(info['public_key'])
    with pytest.raises(VaultError) as caught:
        execute(database, store.upload, '@a:matrix.test', 'D', 7, info['version'], str(uuid.uuid4()), digest(body), body)
    assert caught.value.code == 'M_VAULT_QUOTA_EXCEEDED'
    with database() as conn:
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_sessions').fetchone()[0] == 0
        assert conn.execute('SELECT count(*) FROM chatflow_recovery_audit').fetchone()[0] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('route', ('material', 'enrollment', 'upload'))
@pytest.mark.parametrize('fault', ('revoked', 'owner', 'device', None))
async def test_final_business_response_rechecks_matrix_before_release_or_commit(database, monkeypatch, tmp_path, route, fault):
    """Actual verify/handler/crypto/PG; controlled native-auth and HTTP boundaries.

    The second Business response changes Matrix state, after the preceding native
    check. Real HTTP/native logout is an additional isolated Linux acceptance gate.
    Assertions report booleans/counts only, never material or credential values.
    """
    import io
    from types import ModuleType, SimpleNamespace
    from chatflow_recovery_crypto import canonical, encode
    from chatflow_recovery_vault import Authority, RecoveryVaultModule, PRIVATE_BASE

    # Supply only the imported transport interfaces; actual Authority.verify runs.
    class Deferred:
        called = False
        value = None
        error = None
        def callback(self, value): self.called, self.value = True, value
        def errback(self, error): self.called, self.error = True, error
        def addTimeout(self, *args): return self
        def __await__(self):
            async def completed():
                assert self.called
                if self.error: raise self.error
                return self.value
            return completed().__await__()
    def resolved(value):
        pending = Deferred(); pending.callback(value); return pending
    for name in ('synapse', 'synapse.logging', 'synapse.logging.context', 'twisted',
                 'twisted.internet', 'twisted.internet.defer', 'twisted.internet.protocol',
                 'twisted.web', 'twisted.web.client', 'twisted.web.http_headers'):
        module = ModuleType(name); module.__path__ = []
        monkeypatch.setitem(sys.modules, name, module)
    sys.modules['synapse.logging.context'].make_deferred_yieldable = lambda value: value
    sys.modules['twisted.internet.defer'].Deferred = Deferred
    sys.modules['twisted.internet.protocol'].Protocol = object
    sys.modules['twisted.web.client'].FileBodyProducer = lambda value: value
    sys.modules['twisted.web.client'].ResponseDone = type('ResponseDone', (), {})
    sys.modules['twisted.web.http_headers'].Headers = lambda value: value
    owner, device = '@a:matrix.test', 'DEVICE'
    metadata = {'matrix_user_id': owner, 'matrix_device_id': device, 'family_id': 'F', 'generation': 7}
    state = {'business_calls': 0, 'matrix_calls': 0, 'changed': False}
    class NativeAuthError(Exception):
        code = 401
    authority = object.__new__(Authority)
    authority.reactor = object()
    async def matrix(request):
        state['matrix_calls'] += 1
        if state['changed'] and fault == 'revoked': raise NativeAuthError()
        current_owner = '@other:matrix.test' if state['changed'] and fault == 'owner' else owner
        current_device = 'OTHER' if state['changed'] and fault == 'device' else device
        return current_owner, current_device, b'Bearer synthetic'
    authority.matrix = matrix
    class Response:
        code = 200
        def deliverBody(self, reader):
            state['business_calls'] += 1
            if state['business_calls'] == 2: state['changed'] = True
            reader.dataReceived(canonical(metadata))
            reader.connectionLost(SimpleNamespace(check=lambda _: True))
    authority.agent = SimpleNamespace(request=lambda *args: resolved(Response()))

    key = os.urandom(32)
    ring = tmp_path/'synthetic-keyring.json'
    ring.write_bytes(canonical({'format': 1, 'active': 'k', 'keys': {
        'k': {'key': encode(key), 'state': 'active_for_writes', 'confirmation': 'a'*64}}}))
    ring.chmod(0o600)
    envelope = generate_envelope('matrix.test', owner, str(uuid.uuid4()), 'k', key)
    store = VaultStore()
    if route != 'enrollment':
        execute(database, store.enroll, owner, device, 7, str(uuid.uuid4()), 'initial', envelope)
    def snapshot():
        with database() as conn:
            counts = tuple(conn.execute('SELECT count(*) FROM chatflow_recovery_'+table).fetchone()[0]
                for table in ('accounts', 'versions', 'heads', 'sessions', 'operations', 'audit'))
            accounts = conn.execute('SELECT revision,stored_bytes,candidate_count FROM chatflow_recovery_accounts').fetchall()
        return counts, accounts
    before = snapshot()
    operation = str(uuid.uuid4())
    body = ({'version': envelope['version']} if route == 'material' else
            {'algorithm': ALGORITHM} if route == 'enrollment' else upload_body(envelope['public_key']))
    suffix = '/material' if route == 'material' else '/enrollments/'+operation if route == 'enrollment' else '/sessions/'+envelope['version']+'/'+operation
    class Request:
        path = (PRIVATE_BASE+suffix).encode()
        method = b'POST' if route == 'material' else b'PUT'
        content = io.BytesIO(canonical(body))
        headers = {}
        requestHeaders = SimpleNamespace(getRawHeaders=lambda name, default:
            [operation.encode()] if name == b'Idempotency-Key' else [b'*'] if name == b'If-None-Match' else default)
        def setHeader(self, key, value): self.headers[key] = value
    class Api:
        server_name = 'matrix.test'
        async def run_db_interaction(self, name, fn, *args): return execute(database, fn, *args)
    module = object.__new__(RecoveryVaultModule)
    module.config = {'enabled': True, 'keyring_path': str(ring)}
    module.api, module.store, module.authority, module.buckets = Api(), store, authority, {}
    request = Request()
    status, response = await module.handle(request)
    after = snapshot()
    released_private = 'private_key' in response
    rows_unchanged = before == after
    assert request.headers[b'Cache-Control'] == b'no-store'
    if fault is not None:
        assert not released_private
        assert rows_unchanged
        assert status == (401 if fault == 'revoked' else 403)
        assert state['business_calls'] == 2
    else:
        assert status == (201 if route == 'enrollment' else 200)
        assert released_private == (route == 'material')
        assert rows_unchanged == (route == 'material')
        assert state['business_calls'] == (2 if route == 'material' else 3)
