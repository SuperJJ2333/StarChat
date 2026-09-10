"""Coordinator security tests; actual pinned Synapse is covered separately."""
import asyncio
from contextlib import asynccontextmanager
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mobile_login', ROOT / 'third_party/synapse/chatflow_mobile_login.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Queue:
    def __init__(self):
        self.lock = asyncio.Lock()

    @asynccontextmanager
    async def queue(self, key):
        async with self.lock:
            yield


class Backend:
    def __init__(self):
        self.generations = {}
        self.tokens = {'old-a': ('@a:example.test', 'A'), 'old-b': ('@a:example.test', 'B')}
        self.keys = {'A': 'retained-e2ee', 'B': 'old-e2ee'}
        self.deleted_devices = []
        self.fail_revoke = False
        self.calls = 0
        self.started = asyncio.Event()
        self.resume = None
        self.allowed = True

    async def ensure_user(self, user):
        if not self.allowed:
            raise module.MobileAccountUnavailable()

    async def claim(self, user, generation):
        if generation <= self.generations.get(user, 0):
            return False
        self.generations[user] = generation
        return True

    async def register(self, user, device, name):
        self.calls += 1
        self.started.set()
        if self.resume:
            await self.resume.wait()
        token = f'new-{self.calls}'
        self.tokens[token] = (user, device)
        self.keys.setdefault(device, 'new-key')
        return device, token, None, None

    async def token_id(self, user, device, token):
        if self.tokens.get(token) != (user, device):
            raise RuntimeError('wrong identity')
        return token

    async def revoke_others(self, user, device, token_id):
        if self.fail_revoke:
            raise RuntimeError('sensitive upstream token must not escape')
        self.tokens = {t: pair for t, pair in self.tokens.items()
                       if pair != (user, device) or t == token_id}

    async def devices(self, user):
        return list(self.keys)

    async def delete_device(self, user, device):
        self.deleted_devices.append(device)
        self.keys.pop(device, None)
        self.tokens = {t: pair for t, pair in self.tokens.items() if pair != (user, device)}

    async def compensate(self, token):
        self.tokens.pop(token, None)


class MobileLoginTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.backend = Backend()
        self.coordinator = module.MobileLoginCoordinator(self.backend, Queue())

    def test_packaged_code_sets_readable_modes_independent_of_upload_umask(self):
        dockerfile = (ROOT / 'third_party/synapse/Dockerfile').read_text()
        self.assertIn('target.chmod(0o644)', dockerfile)
        self.assertIn('target.parent.chmod(0o755)', dockerfile)
        self.assertNotIn("shutil.copy('/opt/chatflow-mobile/chatflow_mobile_login.py'", dockerfile)

    async def test_same_device_retains_keys_and_only_new_token(self):
        response = await self.coordinator.login('@a:example.test', 1, 'A', None)
        self.assertEqual(set(self.backend.tokens), {response['access_token']})
        self.assertEqual(self.backend.keys, {'A': 'retained-e2ee'})
        self.assertEqual(self.backend.deleted_devices, ['B'])
        self.assertNotIn('refresh_token', response)

    async def test_duplicate_and_older_generation_never_register(self):
        await self.coordinator.login('@a:example.test', 2, 'A', None)
        for generation in [2, 1]:
            with self.assertRaises(module.StaleGeneration):
                await self.coordinator.login('@a:example.test', generation, 'A', None)
        self.assertEqual(self.backend.calls, 1)

    async def test_failure_consumes_generation_and_compensates_without_deleting_keys(self):
        self.backend.fail_revoke = True
        with self.assertRaises(module.MobileLoginFailed) as error:
            await self.coordinator.login('@a:example.test', 1, 'A', None)
        self.assertNotIn('sensitive', str(error.exception))
        self.assertEqual(set(self.backend.tokens), {'old-a', 'old-b'})
        self.assertEqual(self.backend.keys['A'], 'retained-e2ee')
        with self.assertRaises(module.StaleGeneration):
            await self.coordinator.login('@a:example.test', 1, 'A', None)

    async def test_restart_uses_persistent_generation(self):
        await self.coordinator.login('@a:example.test', 9, 'A', None)
        restarted = module.MobileLoginCoordinator(self.backend, Queue())
        with self.assertRaises(module.StaleGeneration):
            await restarted.login('@a:example.test', 8, 'A', None)

    async def test_account_became_unavailable_while_queued_is_rejected(self):
        self.backend.resume = asyncio.Event()
        first = asyncio.create_task(self.coordinator.login('@a:example.test', 1, 'A', None))
        await self.backend.started.wait()
        second = asyncio.create_task(self.coordinator.login('@a:example.test', 2, 'B', None))
        await asyncio.sleep(0)
        self.backend.allowed = False
        self.backend.resume.set()
        await first
        with self.assertRaises(module.MobileAccountUnavailable):
            await second
        self.assertEqual(self.backend.generations['@a:example.test'], 1)

    async def test_unknown_result_older_operation_finishes_before_newer_success(self):
        self.backend.resume = asyncio.Event()
        older = asyncio.create_task(self.coordinator.login('@a:example.test', 1, 'A', None))
        await self.backend.started.wait()
        # Simulate caller timing out without cancelling the upstream operation.
        newer = asyncio.create_task(self.coordinator.login('@a:example.test', 2, 'B', None))
        await asyncio.sleep(0)
        self.assertEqual(self.backend.calls, 1)
        self.backend.resume.set()
        await older
        response = await newer
        self.assertEqual(self.backend.tokens, {response['access_token']: ('@a:example.test', 'B')})

    async def test_invalid_payload_rejected_before_generation_or_device_writes(self):
        for payload in [None, {}, {'user_id': '@a:example.test', 'generation': True, 'device_id': 'A'},
                        {'user_id': '@a:example.test', 'generation': 1, 'device_id': ''},
                        {'user_id': '@a:example.test', 'generation': 2**63, 'device_id': 'A'}]:
            with self.assertRaises(ValueError):
                module.validate_payload(payload)


if __name__ == '__main__':
    unittest.main()
