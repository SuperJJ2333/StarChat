import pytest
from coincurve import PrivateKey

from app.core.errors import AppError
from app.integrations.tron.message_signature import address_from_public_key
from app.modules.wallet.binding import WalletBindingService
from test_manual_payouts import core, request, claim  # noqa: F401


@pytest.mark.parametrize('phase', ['REQUESTED', 'CLAIMED', 'UNKNOWN'])
def test_pending_manual_payout_blocks_rebind_challenge(core, phase):
    order = request(core)
    if phase != 'REQUESTED':
        claim(core, order)
    if phase == 'UNKNOWN':
        core[0].reconcile(order_id=order['id'])
    binding = WalletBindingService(core[1], domain='wallet.example.test', clock=lambda: core[2][0])
    target = address_from_public_key(PrivateKey().public_key.format(compressed=False))
    with pytest.raises(AppError) as error:
        binding.challenge(user_id='alice', session_id='session', address=target,
            expected_version=1, idempotency_key='rebind')
    assert error.value.code == 'WALLET_WITHDRAWAL_IN_PROGRESS'


def test_cancelled_manual_payout_allows_rebind_challenge(core):
    order = request(core)
    core[0].cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel')
    binding = WalletBindingService(core[1], domain='wallet.example.test', clock=lambda: core[2][0])
    target = address_from_public_key(PrivateKey().public_key.format(compressed=False))
    result = binding.challenge(user_id='alice', session_id='session', address=target,
        expected_version=1, idempotency_key='rebind')
    assert result['protocol'] == 'signMessageV2'
