"""Test-only native fault injection. Never copied into the production image."""
from chatflow_mobile_login import MobileLoginModule, _SynapseBackend


class FaultProbeModule(MobileLoginModule):
    def __init__(self, config, api):
        register = _SynapseBackend.register
        revoke = _SynapseBackend.revoke_others
        failures = set()

        async def controlled_register(backend, user, device, name):
            if name == 'synthetic-slow':
                await api._hs.get_clock().sleep(1)
            result = await register(backend, user, device, name)
            if name == 'synthetic-fail-after-issue':
                failures.add((user, device))
            return result

        async def controlled_revoke(backend, user, device, token_id):
            if (user, device) in failures:
                failures.remove((user, device))
                raise RuntimeError('Synthetic native revocation failure')
            return await revoke(backend, user, device, token_id)

        _SynapseBackend.register = controlled_register
        _SynapseBackend.revoke_others = controlled_revoke
        super().__init__(config, api)
