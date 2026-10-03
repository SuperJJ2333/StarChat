"""Real cryptography; transport/authority tests identify their isolated doubles."""
import base64
import copy
import os
from pathlib import Path
import sys
import json
import io
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'third_party/synapse'))
import chatflow_recovery_crypto as crypto


def test_recovery_envelope_authenticates_all_binding_fields():
    key = os.urandom(32)
    envelope = crypto.generate_envelope('matrix.test', '@a:matrix.test', 'version', 'key1', key)
    private = crypto.unwrap(envelope, {'key1': key})
    assert len(private) == 32
    assert crypto.public_key(private) == envelope['public_key']
    assert base64.b64encode(private).decode().rstrip('=') not in str(envelope)
    for field in ('server', 'owner', 'version', 'algorithm', 'public_key', 'key_id', 'nonce', 'ciphertext'):
        broken = copy.deepcopy(envelope)
        broken[field] += 'x'
        with pytest.raises(crypto.Unavailable): crypto.unwrap(broken, {'key1': key})
    with pytest.raises(crypto.Unavailable): crypto.unwrap(envelope, {'key1': os.urandom(32)})
    with pytest.raises(crypto.Unavailable): crypto.unwrap(envelope, {})


def test_rewrap_retains_private_binding_with_unique_nonces():
    old, new = os.urandom(32), os.urandom(32)
    envelope = crypto.generate_envelope('matrix.test', '@a:matrix.test', 'v', 'old', old)
    changed = crypto.rewrap(envelope, {'old': old}, 'new', new)
    assert crypto.unwrap(envelope, {'old': old}) == crypto.unwrap(changed, {'new': new})
    assert envelope['nonce'] != changed['nonce']


def test_worker_returns_before_secret_schema_resource_or_native_import():
    from chatflow_recovery_vault import RecoveryVaultModule
    class Api:
        _hs = SimpleNamespace(config=SimpleNamespace(worker=SimpleNamespace(worker_app='synapse.app.generic_worker')))
        def __getattr__(self, name): raise AssertionError('worker accessed capability: ' + name)
    RecoveryVaultModule({'enabled': True, 'keyring_path': '/does/not/exist'}, Api())


def test_strict_standard_encrypted_candidate_validation():
    from chatflow_recovery_vault import validate_upload, parse_body
    from chatflow_recovery_store import VaultError
    good = {'algorithm': crypto.ALGORITHM, 'public_key': crypto.encode(os.urandom(32)), 'sessions': [{
        'room_id': '!room:test', 'session_id': 'session', 'expected_revision': 0,
        'first_message_index': 0, 'forwarded_count': 0, 'is_verified': False,
        'session_data': {'ephemeral': crypto.encode(os.urandom(32)), 'mac': crypto.encode(os.urandom(8)),
                         'ciphertext': crypto.encode(os.urandom(48))}}]}
    validate_upload(good)
    for key, value in [('session_key', 'plaintext'), ('owner', '@victim:test')]:
        broken = copy.deepcopy(good)
        broken['sessions'][0][key] = value
        with pytest.raises(VaultError): validate_upload(broken)
    for key, value in [('first_message_index', -1), ('forwarded_count', 65), ('expected_revision', True)]:
        broken = copy.deepcopy(good)
        broken['sessions'][0][key] = value
        with pytest.raises(VaultError): validate_upload(broken)
    with pytest.raises(VaultError): validate_upload({**good, 'sessions': good['sessions'] * 81})
    with pytest.raises(VaultError): parse_body(b'{"algorithm":"a","algorithm":"b"}', 1024)
    with pytest.raises(VaultError): parse_body(b' ' * 1025, 1024)
    with pytest.raises(VaultError): parse_body(b'{"x":NaN}', 1024)


def test_cursor_is_bound_to_owner_version_query_and_signature():
    from chatflow_recovery_vault import sign_cursor, read_cursor
    from chatflow_recovery_store import VaultError
    keys = {'key': os.urandom(32)}
    query = [{'room_id': '!r:test', 'session_id': 's'}]
    token = sign_cursor({'position': 0, 'offset': 16, 'revision': 3}, '@a:test', 'v', query, 'key', keys)
    assert read_cursor(token, '@a:test', 'v', query, keys)['offset'] == 16
    for owner, version, pairs in [('@b:test', 'v', query), ('@a:test', 'x', query), ('@a:test', 'v', [])]:
        with pytest.raises(VaultError): read_cursor(token, owner, version, pairs, keys)
    with pytest.raises(VaultError): read_cursor(token + 'A', '@a:test', 'v', query, keys)


@pytest.mark.asyncio
async def test_final_authority_revocation_discards_material_and_does_not_log(tmp_path, caplog):
    from chatflow_recovery_vault import RecoveryVaultModule
    from chatflow_recovery_store import VaultError, VaultStore
    key = os.urandom(32)
    ring = tmp_path / 'keyring.json'
    ring.write_bytes(crypto.canonical({'format': 1, 'active': 'k', 'keys': {
        'k': {'key': crypto.encode(key), 'state': 'active_for_writes', 'confirmation': 'a' * 64}}}))
    ring.chmod(0o600)
    envelope = crypto.generate_envelope('matrix.test', '@a:matrix.test', '00000000-0000-4000-8000-000000000001', 'k', key)
    module = object.__new__(RecoveryVaultModule)
    module.config = {'enabled': True, 'keyring_path': str(ring)}
    module.store, module.buckets = VaultStore(), {}
    class Authority:
        calls = 0
        async def verify(self, request, expected=None):
            self.calls += 1
            if self.calls > 1: raise VaultError(403, 'M_FORBIDDEN')
            return {'matrix_user_id': '@a:matrix.test', 'matrix_device_id': 'D', 'generation': 1, 'family_id': 'F'}
    module.authority = Authority()
    class Api:
        server_name = 'matrix.test'
        async def run_db_interaction(self, name, fn, *args): return envelope
    module.api = Api()
    class Request:
        path = b'/_synapse/client/chatflow/recovery/v1/material'
        method = b'POST'
        content = io.BytesIO(crypto.canonical({'version': envelope['version']}))
        headers = {}
        def setHeader(self, key, value): self.headers[key] = value
    request = Request()
    code, response = await module.handle(request)
    assert code == 403 and 'private_key' not in response
    assert request.headers[b'Cache-Control'] == b'no-store'
    assert caplog.text == ''


def test_keyring_missing_corrupt_or_inactive_never_becomes_empty_replacement(tmp_path):
    from chatflow_recovery_vault import load_keyring
    path = tmp_path/'keyring'
    with pytest.raises(crypto.Unavailable): load_keyring(path)
    path.write_bytes(b'{}'); path.chmod(0o600)
    with pytest.raises(crypto.Unavailable): load_keyring(path)
    path.write_bytes(crypto.canonical({'format': 1, 'active': 'k', 'keys': {
        'k': {'key': crypto.encode(os.urandom(32)), 'state': 'primary_inactive', 'confirmation': None}}}))
    with pytest.raises(crypto.Unavailable): load_keyring(path)


def test_frozen_schema_agrees_with_standard_upload_and_descriptor():
    import jsonschema
    from chatflow_recovery_store import descriptor
    schema = json.loads((ROOT/'third_party/synapse/recovery-v1.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator.check_schema(schema)
    envelope = crypto.generate_envelope('matrix.test', '@a:matrix.test', '00000000-0000-4000-8000-000000000001', 'k', os.urandom(32))
    selected = {'$ref': '#/$defs/Descriptor', '$defs': schema['$defs']}
    jsonschema.validate(descriptor(envelope), selected)


def test_native_sql_filter_suppresses_only_vault_transactions(caplog):
    import logging
    from chatflow_recovery_vault import RecoverySQLFilter
    logger = logging.getLogger('synapse.storage.SQL')
    guard = RecoverySQLFilter()
    logger.addFilter(guard)
    try:
        with caplog.at_level(logging.DEBUG, logger='synapse.storage.SQL'):
            logger.debug('[SQL values] {%s} %r', 'chatflow_recovery-a', ('BODY_SENTINEL',))
            logger.debug('[SQL FAIL] {%s} %s', 'chatflow_recovery-a', ValueError('ERROR_SENTINEL'))
            logger.debug('[SQL values] {%s} %r', 'unrelated-a', ('ordinary',))
        assert 'BODY_SENTINEL' not in caplog.text and 'ERROR_SENTINEL' not in caplog.text
        assert 'ordinary' in caplog.text
    finally:
        logger.removeFilter(guard)


@pytest.mark.asyncio
@pytest.mark.parametrize('change', ('none', 'expired_token', 'expired_account', 'revoked', 'locked', 'suspended'))
async def test_repeat_matrix_authority_preserves_single_assignment_and_revalidates(change):
    """Behavioral double of pinned request setter; real native HTTP is separate."""
    from chatflow_recovery_vault import Authority
    from chatflow_recovery_store import VaultError
    owner = '@a:matrix.test'
    state = {'expired_token': False, 'expired_account': False, 'revoked': False}
    info = SimpleNamespace(is_admin=False, is_guest=False, is_deactivated=False,
        locked=False, suspended=False, approved=True, appservice_id=None, user_type=None)
    requester = SimpleNamespace(user=SimpleNamespace(to_string=lambda: owner),
        device_id='D', is_guest=False, app_service=None, authenticated_entity=owner)
    class Auth:
        calls = 0
        async def get_user_by_access_token(self, token, allow_expired):
            self.calls += 1
            assert allow_expired is False
            if state['expired_token'] or state['revoked']: raise VaultError(401, 'M_UNAUTHORIZED')
            return requester
        async def is_user_expired(self, user): return state['expired_account']
    auth = Auth()
    auth._account_validity_handler = auth
    class Store:
        async def get_user_by_access_token(self, token):
            return None if state['revoked'] else SimpleNamespace(user_id=owner, device_id='D')
    class Api:
        requests = 0
        _hs = SimpleNamespace(get_auth=lambda: auth,
            get_datastores=lambda: SimpleNamespace(main=Store()))
        def is_mine(self, user): return True
        async def get_userinfo_by_id(self, user): return info
        async def get_user_by_req(self, request, **kwargs):
            self.requests += 1
            request.requester = await auth.get_user_by_access_token('synthetic', False)
            return request.requester
    class Headers:
        def getRawHeaders(self, name, default): return [b'Bearer synthetic']
    class Request:
        args = {}
        requestHeaders = Headers()
        _requester = None
        @property
        def requester(self): return self._requester
        @requester.setter
        def requester(self, value):
            assert self._requester is None, 'native request identity is single assignment'
            self._requester = value
    authority = object.__new__(Authority)
    authority.api = Api()
    request = Request()
    assert (await authority.matrix(request))[:2] == (owner, 'D')
    if change in state: state[change] = True
    elif change != 'none': setattr(info, change, True)
    if change == 'none':
        assert (await authority.matrix(request))[:2] == (owner, 'D')
    else:
        with pytest.raises(VaultError): await authority.matrix(request)
    assert authority.api.requests == 1
    assert auth.calls == 2
