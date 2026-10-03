"""Main-only Synapse 1.132.0 recovery vault. ADR 2026-10-04.

No native backup, SSSS, trust, room-message or financial operation is performed.
Exceptions crossing the resource boundary are deliberately reduced to fixed errors.
"""
import hashlib
import hmac
import io
import json
import logging
import os
import re
import stat
import time
import uuid

from chatflow_recovery_crypto import ALGORITHM, Unavailable, canonical, decode, encode, generate_envelope, unwrap
from chatflow_recovery_store import VaultError, VaultStore, descriptor, digest

BASE = '/_matrix/client/unstable/com.starchat.recovery/v1'
PRIVATE_BASE = '/_synapse/client/chatflow/recovery/v1'
AUTHORITY = 'http://business-api:8000/api/v1/auth/matrix-recovery-authorize'
LIMIT = 1024 * 1024


class RecoverySQLFilter(logging.Filter):
    """Pinned Synapse SQL logger otherwise prints full parameters at DEBUG."""
    def filter(self, record):
        args = record.args
        return not (isinstance(args, tuple) and args and isinstance(args[0], str)
                    and re.fullmatch(r'chatflow_recovery-[0-9a-f]+', args[0]))


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise VaultError(400, 'M_INVALID_PARAM')


def identifier(value, maximum=255):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or any(ord(c) < 33 or ord(c) == 127 for c in value):
        raise VaultError(400, 'M_INVALID_PARAM')
    return value


def operation_id(value):
    try:
        if str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise VaultError(400, 'M_INVALID_PARAM') from None
    return value


def integer(value, maximum=2**63 - 1):
    if type(value) is not int or not 0 <= value <= maximum:
        raise VaultError(400, 'M_INVALID_PARAM')


def b64(value, length=None, maximum=16384):
    try:
        if not isinstance(value, str) or not 1 <= len(value) <= maximum:
            raise ValueError()
        raw = decode(value)
        if length is not None and len(raw) != length:
            raise ValueError()
    except Exception:
        raise VaultError(400, 'M_INVALID_PARAM') from None


def pairs(values):
    if not isinstance(values, list) or not 1 <= len(values) <= 64:
        raise VaultError(400, 'M_INVALID_PARAM')
    seen = set()
    for pair in values:
        fields(pair, ('room_id', 'session_id'))
        identifier(pair['room_id']); identifier(pair['session_id'])
        if not pair['room_id'].startswith('!') or (pair['room_id'], pair['session_id']) in seen:
            raise VaultError(400, 'M_INVALID_PARAM')
        seen.add((pair['room_id'], pair['session_id']))


def validate_upload(body):
    fields(body, ('algorithm', 'public_key', 'sessions'))
    if body['algorithm'] != ALGORITHM:
        raise VaultError(400, 'M_UNSUPPORTED_BACKUP_ALGORITHM')
    b64(body['public_key'], 32)
    if not isinstance(body['sessions'], list) or not 1 <= len(body['sessions']) <= 80:
        raise VaultError(400, 'M_INVALID_PARAM')
    seen = set()
    for item in body['sessions']:
        fields(item, ('room_id', 'session_id', 'expected_revision', 'first_message_index', 'forwarded_count', 'is_verified', 'session_data'))
        identifier(item['room_id']); identifier(item['session_id'])
        if not item['room_id'].startswith('!') or (item['room_id'], item['session_id']) in seen:
            raise VaultError(400, 'M_INVALID_PARAM')
        seen.add((item['room_id'], item['session_id']))
        integer(item['expected_revision']); integer(item['first_message_index'], 2**32 - 1)
        integer(item['forwarded_count'], 64)
        if type(item['is_verified']) is not bool or len(canonical(item)) > 16384:
            raise VaultError(400, 'M_INVALID_PARAM')
        fields(item['session_data'], ('ephemeral', 'mac', 'ciphertext'))
        b64(item['session_data']['ephemeral'], 32)
        b64(item['session_data']['mac'], 8)
        b64(item['session_data']['ciphertext'], maximum=16000)


def parse_body(raw, limit):
    if len(raw) > limit:
        raise VaultError(413, 'M_TOO_LARGE')
    def unique(items):
        result = {}
        for key, value in items:
            if key in result: raise ValueError()
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(value, dict): raise ValueError()
        return value
    except Exception:
        raise VaultError(400, 'M_BAD_JSON') from None


def load_keyring(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 32768:
                raise ValueError()
            if os.name == 'posix' and (info.st_uid not in (0, os.getuid()) or stat.S_IMODE(info.st_mode) & 0o077):
                raise ValueError()
            data = json.loads(stream.read(32769))
        fields(data, ('format', 'active', 'keys'))
        if data['format'] != 1 or not isinstance(data['keys'], dict) or not 1 <= len(data['keys']) <= 64:
            raise ValueError()
        keys = {}
        for name, entry in data['keys'].items():
            identifier(name, 64)
            fields(entry, ('key', 'state', 'confirmation'))
            keys[name] = decode(entry['key'])
            if len(keys[name]) != 32: raise ValueError()
            if entry['state'] not in ('primary_inactive', 'independent_protected_and_readback_confirmed', 'active_for_writes', 'bounded_rewrap'):
                raise ValueError()
        active = data['keys'][data['active']]
        if active['state'] not in ('active_for_writes', 'bounded_rewrap') or not re.fullmatch('[0-9a-f]{64}', active['confirmation'] or ''):
            raise ValueError()
        return data['active'], keys
    except Exception:
        raise Unavailable('Recovery unavailable') from None


def sign_cursor(cursor, owner, version, query, key_id, keys):
    payload = {**cursor, 'owner': owner, 'version': version, 'query': digest(query),
               'key_id': key_id, 'expires': int(time.time()) + 900}
    raw = canonical(payload)
    signature = hmac.digest(keys[key_id], b'chatflow-recovery-cursor-v1\0' + raw, 'sha256')
    return encode(raw) + '.' + encode(signature)


def read_cursor(value, owner, version, query, keys):
    try:
        if not isinstance(value, str) or len(value) > 2048: raise ValueError()
        encoded, signature = value.split('.')
        raw = decode(encoded)
        payload = json.loads(raw)
        fields(payload, ('position', 'offset', 'revision', 'owner', 'version', 'query', 'key_id', 'expires'))
        if (not hmac.compare_digest(decode(signature), hmac.digest(keys[payload['key_id']],
                b'chatflow-recovery-cursor-v1\0' + raw, 'sha256'))
                or payload['owner'] != owner or payload['version'] != version
                or payload['query'] != digest(query) or payload['expires'] < int(time.time())):
            raise ValueError()
        integer(payload['position'], len(query)-1); integer(payload['offset'], 100000); integer(payload['revision'])
        return payload
    except Exception:
        raise VaultError(400, 'M_INVALID_CONTINUATION') from None


class Authority:
    def __init__(self, api):
        from twisted.web.client import Agent
        self.api = api
        self.reactor = api._hs.get_reactor()
        self.agent = Agent(self.reactor, connectTimeout=5)

    async def matrix(self, request):
        if request.args:
            raise VaultError(400, 'M_INVALID_PARAM')
        authorization = request.requestHeaders.getRawHeaders(b'Authorization', [])
        business = request.requestHeaders.getRawHeaders(b'X-StarChat-Session', [])
        if (len(authorization) != 1 or len(business) != 1
                or not authorization[0].startswith(b'Bearer ') or not business[0].startswith(b'Bearer ')
                or not 8 <= len(authorization[0]) <= 8192 or not 8 <= len(business[0]) <= 8192):
            raise VaultError(401, 'M_UNAUTHORIZED')
        token = authorization[0][7:].decode('ascii')
        auth = self.api._hs.get_auth()
        if not getattr(request, '_chatflow_recovery_request_authenticated', False):
            requester = await self.api.get_user_by_req(request, allow_guest=False, allow_expired=False)
            # SynapseRequest.requester is single-assignment. This marker records
            # only that the initial native request hook ran, never an auth result.
            request._chatflow_recovery_request_authenticated = True
        else:
            # Pinned native adapter repeats token validity/expiry and account
            # validity without assigning request.requester a second time.
            requester = await auth.get_user_by_access_token(token, allow_expired=False)
        owner = requester.user.to_string()
        if (not self.api.is_mine(owner) or requester.is_guest or requester.app_service is not None
                or requester.authenticated_entity != owner or not requester.device_id):
            raise VaultError(403, 'M_FORBIDDEN')
        info = await self.api.get_userinfo_by_id(owner)
        if (info is None or info.is_admin or info.is_guest or info.is_deactivated or info.locked
                or info.suspended or not info.approved or info.appservice_id is not None or info.user_type is not None):
            raise VaultError(403, 'M_FORBIDDEN')
        if await auth._account_validity_handler.is_user_expired(owner):
            raise VaultError(403, 'M_FORBIDDEN')
        # Access token lookup repeated after user-info await; pinned datastore cache
        # is invalidated by native revocation, unlike a positive vault auth cache.
        found = await self.api._hs.get_datastores().main.get_user_by_access_token(token)
        if found is None or found.user_id != owner or found.device_id != requester.device_id:
            raise VaultError(401, 'M_UNAUTHORIZED')
        return owner, requester.device_id, business[0]

    async def verify(self, request, expected=None):
        from synapse.logging.context import make_deferred_yieldable
        from twisted.internet.defer import Deferred
        from twisted.internet.protocol import Protocol
        from twisted.web.client import FileBodyProducer, ResponseDone
        from twisted.web.http_headers import Headers
        owner, device, bearer = await self.matrix(request)
        try:
            response = await make_deferred_yieldable(self.agent.request(b'POST', AUTHORITY.encode(),
                Headers({b'Authorization': [bearer], b'Content-Type': [b'application/json']}),
                FileBodyProducer(io.BytesIO(canonical({'matrix_user_id': owner, 'matrix_device_id': device})))).addTimeout(5, self.reactor))
            done = Deferred()
            class Reader(Protocol):
                def __init__(self): self.body = bytearray()
                def dataReceived(self, data):
                    self.body.extend(data)
                    if len(self.body) > 4096:
                        self.transport.abortConnection()
                        if not done.called: done.errback(ValueError('Authority unavailable'))
                def connectionLost(self, reason):
                    if not done.called:
                        if reason.check(ResponseDone): done.callback(bytes(self.body))
                        else: done.errback(ValueError('Authority unavailable'))
            response.deliverBody(Reader())
            raw = await make_deferred_yieldable(done.addTimeout(5, self.reactor))
            if response.code in (401, 403, 409): raise VaultError(403, 'M_FORBIDDEN')
            if response.code == 429: raise VaultError(429, 'M_LIMIT_EXCEEDED', {'retry_after_ms': 1000})
            if response.code != 200: raise ValueError()
            metadata = json.loads(raw)
            fields(metadata, ('matrix_user_id', 'matrix_device_id', 'family_id', 'generation'))
            if metadata['matrix_user_id'] != owner or metadata['matrix_device_id'] != device:
                raise ValueError()
            identifier(metadata['family_id'], 128); integer(metadata['generation'])
            if metadata['generation'] < 1: raise ValueError()
            if expected is not None and metadata != expected: raise VaultError(403, 'M_FORBIDDEN')
            return metadata
        except VaultError:
            raise
        except Exception:
            raise VaultError(503, 'M_VAULT_UNAVAILABLE') from None


class RecoveryVaultModule:
    @staticmethod
    def parse_config(config):
        fields(config, (), ('enabled', 'keyring_path'))
        if type(config.get('enabled', False)) is not bool:
            raise ValueError('Invalid vault configuration')
        path = config.get('keyring_path', '/run/chatflow-recovery/keyring.json')
        if path != '/run/chatflow-recovery/keyring.json':
            raise ValueError('Invalid vault credential path')
        return {'enabled': config.get('enabled', False), 'keyring_path': path}

    def __init__(self, config, api):
        # Must precede credentials, database/schema, HTTP clients and resources.
        if api._hs.config.worker.worker_app is not None:
            return
        import synapse
        from synapse.http.server import DirectServeJsonResource
        if synapse.__version__ != '1.132.0':
            raise RuntimeError('Recovery vault requires Synapse 1.132.0')
        self.api, self.config, self.store = api, config, VaultStore()
        for name in ('synapse.storage.SQL', 'synapse.storage.txn'):
            logging.getLogger(name).addFilter(RecoverySQLFilter())
        self.authority = Authority(api)
        self.buckets = {}
        module = self
        class Resource(DirectServeJsonResource):
            isLeaf = True
            async def _async_render_GET(self, request): return await module.handle(request)
            async def _async_render_POST(self, request): return await module.handle(request)
            async def _async_render_PUT(self, request): return await module.handle(request)
            async def _async_render_DELETE(self, request): return await module.handle(request)
            async def _async_render_PATCH(self, request): return await module.handle(request)
            async def _async_render_HEAD(self, request): return await module.handle(request)
            async def _async_render_OPTIONS(self, request): return await module.handle(request)
        # The native /_matrix/client JsonResource is a leaf. A deeper module
        # resource there is unreachable. The exact public Nginx location rewrites
        # to this existing nonleaf private tree; no core router is patched.
        api.register_web_resource(PRIVATE_BASE, Resource())

    def rate(self, owner):
        now = time.monotonic()
        self.buckets = {key: val for key, val in self.buckets.items() if now - val[0] < 60}
        start, count = self.buckets.get(owner, (now, 0))
        if count >= 120 or len(self.buckets) >= 10000 and owner not in self.buckets:
            raise VaultError(429, 'M_LIMIT_EXCEEDED', {'retry_after_ms': 1000})
        self.buckets[owner] = (start, count + 1)

    async def db(self, function, *args):
        return await self.api.run_db_interaction('chatflow_recovery', function, *args)

    async def handle(self, request):
        request.setHeader(b'Cache-Control', b'no-store')
        request.setHeader(b'Pragma', b'no-cache')
        try:
            if not self.config['enabled']:
                raise VaultError(503, 'M_VAULT_UNAVAILABLE')
            metadata = await self.authority.verify(request)
            owner, device, generation = metadata['matrix_user_id'], metadata['matrix_device_id'], metadata['generation']
            self.rate(owner)
            active, keys = load_keyring(self.config['keyring_path'])
            path = request.path.decode('ascii')
            if not path.startswith(PRIVATE_BASE + '/'):
                raise VaultError(404, 'M_NOT_FOUND')
            parts = path[len(PRIVATE_BASE)+1:].split('/')
            method = request.method.decode('ascii')
            maximum = LIMIT if parts[0] == 'sessions' and method == 'PUT' else (32768 if parts == ['sessions', 'query'] else 1024)
            raw = request.content.read(maximum + 1)
            body = parse_body(raw, maximum) if raw else {}
            status = 200
            if parts == ['status'] and method == 'GET':
                if raw: raise VaultError(400, 'M_INVALID_PARAM')
                result = await self.db(self.store.status, owner)
            elif len(parts) == 2 and parts[0] == 'enrollments' and method == 'PUT':
                op = operation_id(parts[1])
                self.operation_headers(request, op, enrollment=True)
                fields(body, ('algorithm',))
                if body['algorithm'] != ALGORITHM: raise VaultError(400, 'M_UNSUPPORTED_BACKUP_ALGORITHM')
                envelope = generate_envelope(self.api.server_name, owner, str(uuid.uuid4()), active, keys[active])
                await self.authority.verify(request, metadata)
                status, result = await self.db(self.store.enroll, owner, device, generation, op, digest(['enroll', body]), envelope)
            elif parts == ['material'] and method == 'POST':
                fields(body, ('version',)); operation_id(body['version'])
                envelope = await self.db(self.store.material, owner, body['version'])
                if envelope['server'] != self.api.server_name: raise Unavailable()
                private = unwrap(envelope, keys)
                result = {**descriptor(envelope), 'server': envelope['server'], 'owner': owner, 'private_key': encode(private)}
                if len(canonical(result)) > 4096: raise Unavailable()
            elif len(parts) == 3 and parts[0] == 'sessions' and method == 'PUT':
                version, op = operation_id(parts[1]), operation_id(parts[2])
                self.operation_headers(request, op)
                validate_upload(body)
                await self.authority.verify(request, metadata)
                result = await self.db(self.store.upload, owner, device, generation, version, op,
                                       digest(['upload', version, body]), body)
            elif parts == ['sessions', 'query'] and method == 'POST':
                fields(body, ('version', 'pairs'), ('continuation',))
                version = operation_id(body['version']); pairs(body['pairs'])
                cursor = read_cursor(body['continuation'], owner, version, body['pairs'], keys) if 'continuation' in body else None
                result = await self.db(self.store.query, owner, version, body['pairs'], cursor)
                if result['continuation'] is not None:
                    result['continuation'] = sign_cursor(result['continuation'], owner, version, body['pairs'], active, keys)
            else:
                known = (parts in (['status'], ['material'], ['sessions', 'query'])
                         or len(parts) == 2 and parts[0] == 'enrollments'
                         or len(parts) == 3 and parts[0] == 'sessions')
                raise VaultError(405 if known else 404, 'M_UNRECOGNIZED' if known else 'M_NOT_FOUND')
            # Decision point after DB/network awaits. Revalidate both credentials,
            # including authority generation, before releasing metadata/material.
            await self.authority.verify(request, metadata)
            if len(canonical(result)) > LIMIT: raise Unavailable()
            return status, result
        except VaultError as error:
            return error.status, {'errcode': error.code, 'error': 'Recovery request could not complete', **error.details}
        except Exception as error:
            # Never pass exception repr, request bodies or locals to Synapse logging.
            code = getattr(error, 'code', None)
            if code in (401, 403):
                return code, {'errcode': 'M_UNAUTHORIZED' if code == 401 else 'M_FORBIDDEN', 'error': 'Recovery authorization required'}
            return 503, {'errcode': 'M_VAULT_UNAVAILABLE', 'error': 'Recovery temporarily unavailable'}

    @staticmethod
    def operation_headers(request, operation, enrollment=False):
        if request.requestHeaders.getRawHeaders(b'Idempotency-Key', []) != [operation.encode()]:
            raise VaultError(400, 'M_INVALID_PARAM')
        if enrollment and request.requestHeaders.getRawHeaders(b'If-None-Match', []) != [b'*']:
            raise VaultError(428, 'M_PRECONDITION_REQUIRED')
