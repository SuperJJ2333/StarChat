"""Private, version-pinned mobile login resource. No message/key data is read.

The public proxy must deny /_synapse/client/chatflow/ and admin routes. Only the business broker
may call this endpoint, using its existing Synapse administrator credential.
"""

PATH = '/_synapse/client/chatflow/mobile_login'


class StaleGeneration(Exception):
    pass


class MobileLoginFailed(Exception):
    pass


class MobileAccountUnavailable(Exception):
    pass


def validate_payload(body):
    if not isinstance(body, dict):
        raise ValueError('Invalid mobile login request')
    user = body.get('user_id')
    generation = body.get('generation')
    device = body.get('device_id')
    name = body.get('initial_device_display_name')
    if (not isinstance(user, str) or not user.startswith('@') or ':' not in user
            or len(user) > 255 or any(ord(c) < 32 for c in user)
            or type(generation) is not int or not 1 <= generation < 2**63
            or not isinstance(device, str) or not 1 <= len(device) <= 255
            or any(ord(c) < 32 for c in device)
            or (name is not None and (not isinstance(name, str) or len(name) > 255))):
        raise ValueError('Invalid mobile login request')
    return user, generation, device, name


class MobileLoginCoordinator:
    def __init__(self, backend, linearizer):
        self.backend = backend
        self.linearizer = linearizer

    async def login(self, user, generation, device, name):
        # Synapse Linearizer drops unused per-key entries. Do not use a permanent
        # dictionary of locks or release the lock when an HTTP caller disconnects.
        async with self.linearizer.queue(user):
            await self.backend.ensure_user(user)
            if not await self.backend.claim(user, generation):
                raise StaleGeneration('Mobile login generation already consumed')
            token = None
            try:
                actual, token, expiry, refresh = await self.backend.register(user, device, name)
                if actual != device or not token or refresh is not None:
                    raise MobileLoginFailed()
                token_id = await self.backend.token_id(user, device, token)
                # The pinned handler also revokes every refresh token for this
                # exact device; our new token has no refresh-token relationship.
                await self.backend.revoke_others(user, device, token_id)
                for other in await self.backend.devices(user):
                    if other != device:
                        await self.backend.delete_device(user, other)
                result = {'user_id': user, 'device_id': device, 'access_token': token}
                if expiry is not None:
                    result['expires_in_ms'] = max(0, expiry - self.backend.now_ms())
                return result
            except Exception:
                if token:
                    try:
                        await self.backend.compensate(token)
                    except Exception:
                        # Durable generation remains consumed; a new attempt
                        # reconciles orphaned credentials. Never delete keys.
                        pass
                raise MobileLoginFailed('Mobile login could not complete') from None


class _SynapseBackend:
    def __init__(self, api):
        from synapse.util.async_helpers import Linearizer
        self.api = api
        self.hs = api._hs  # Deliberately pinned private adapter: Synapse 1.132.0.
        self.store = self.hs.get_datastores().main
        self.auth_handler = self.hs.get_auth_handler()
        self._schema_ready = False
        self._schema_lock = Linearizer(name='mobile_login_schema')

    async def ensure_user(self, user):
        info = await self.api.get_userinfo_by_id(user)
        if (info is None or info.is_admin or info.is_guest or info.is_deactivated
                or info.locked or info.suspended or not info.approved
                or info.appservice_id is not None or info.user_type is not None):
            raise MobileAccountUnavailable()

    async def claim(self, user, generation):
        if not self._schema_ready:
            async with self._schema_lock.queue('schema'):
                if not self._schema_ready:
                    def schema(txn):
                        txn.execute('CREATE TABLE IF NOT EXISTS chatflow_mobile_login_generations '
                                    '(user_id TEXT PRIMARY KEY, generation BIGINT NOT NULL CHECK (generation > 0))')
                    await self.api.run_db_interaction('chatflow_mobile_schema', schema)
                    self._schema_ready = True
        def transaction(txn):
            txn.execute('INSERT INTO chatflow_mobile_login_generations (user_id, generation) '
                        'VALUES (?, ?) ON CONFLICT (user_id) DO UPDATE SET generation = excluded.generation '
                        'WHERE chatflow_mobile_login_generations.generation < excluded.generation',
                        (user, generation))
            return txn.rowcount == 1
        return await self.api.run_db_interaction('chatflow_mobile_generation', transaction)

    async def register(self, user, device, name):
        return await self.api.register_device(user, device, name)

    async def token_id(self, user, device, token):
        found = await self.store.get_user_by_access_token(token)
        if (found is None or found.user_id != user or found.device_id != device
                or found.token_id is None):
            raise MobileLoginFailed()
        return found.token_id

    async def revoke_others(self, user, device, token_id):
        await self.auth_handler.delete_access_tokens_for_user(
            user, except_token_id=token_id, device_id=device)

    async def devices(self, user):
        return await self.store.get_devices_by_user(user)

    async def delete_device(self, user, device):
        await self.hs.get_device_handler().delete_devices(user, [device])

    async def compensate(self, token):
        await self.auth_handler.delete_access_token(token)

    def now_ms(self):
        return self.hs.get_clock().time_msec()


class MobileLoginModule:
    @staticmethod
    def parse_config(config):
        if config:
            raise ValueError('MobileLoginModule does not accept configuration overrides')
        return {}

    def __init__(self, config, api):
        import synapse
        from synapse.api.errors import SynapseError
        from synapse.http.server import DirectServeJsonResource
        from synapse.http.servlet import parse_json_object_from_request
        from synapse.rest.admin._base import assert_requester_is_admin
        from synapse.types import UserID
        from synapse.util.async_helpers import Linearizer

        if synapse.__version__ != '1.132.0':
            raise RuntimeError('MobileLoginModule requires Synapse 1.132.0')
        # Shared homeserver configuration may be loaded by workers. They must
        # never expose this resource: the whole operation has one serial owner.
        if api._hs.config.worker.worker_app is not None:
            return
        coordinator = MobileLoginCoordinator(_SynapseBackend(api), Linearizer(name='mobile_login'))

        class Resource(DirectServeJsonResource):
            async def _async_render_POST(self, request):
                await assert_requester_is_admin(api._hs.get_auth(), request)
                try:
                    args = validate_payload(parse_json_object_from_request(request))
                    user = args[0]
                    UserID.from_string(user)
                    if not api.is_mine(user):
                        raise ValueError()
                except (ValueError, SynapseError):
                    return 400, {'errcode': 'M_INVALID_PARAM', 'error': 'Invalid mobile login request'}
                try:
                    return 200, await coordinator.login(*args)
                except MobileAccountUnavailable:
                    return 403, {'errcode': 'M_FORBIDDEN', 'error': 'Mobile account is unavailable'}
                except StaleGeneration:
                    return 409, {'errcode': 'M_FORBIDDEN', 'error': 'Mobile login generation already consumed'}
                except Exception:
                    # No exception body, credentials or upstream response is logged.
                    return 503, {'errcode': 'M_UNKNOWN', 'error': 'Mobile login could not complete'}

        api.register_web_resource(PATH, Resource())
