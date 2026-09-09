from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace

import pytest
from sqlalchemy import select
from app.modules.ledger.reserve import RedeemabilityReserve, caibi_liability
from app.modules.ledger.service import LedgerService
from app.modules.wallet.service import WalletService
from app.modules.wallet.models import WalletConversion
from test_manual_payouts import core  # noqa: F401


def service(core):
    runtime = SimpleNamespace(receipts=SimpleNamespace(reserve_policy='manual_liquidity'))
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('10')
    return WalletService(core[1], None, conversions_enabled=True, manual_runtime=runtime)


def test_manual_conversion_both_directions_preserve_liability_and_replay(core):
    wallet = service(core)
    result = wallet.convert('alice', 'USDT_TO_CAIBI', '10.000000', 'convert-one')
    assert wallet.convert('alice', 'USDT_TO_CAIBI', '10.000000', 'convert-one') == result
    assert wallet.usdt_balance('alice') == Decimal('990')
    assert LedgerService(core[1]).balance('alice') == Decimal('10')
    wallet.convert('alice', 'CAIBI_TO_USDT', '10.00', 'convert-two')
    assert wallet.usdt_balance('alice') == Decimal('1000')
    assert LedgerService(core[1]).balance('alice') == Decimal('0')
    with core[1]() as session:
        reserve = session.get(RedeemabilityReserve, 'global')
        assert reserve.eligible_usdt == Decimal('10')
        assert reserve.usdt_liability + caibi_liability(session) == Decimal('1000')
        assert len(list(session.scalars(select(WalletConversion)))) == 2


@pytest.mark.parametrize('failure', ['insufficient', 'stale', 'paused', 'conflict'])
def test_manual_conversion_rejection_is_atomic(core, failure):
    wallet = service(core)
    if failure == 'stale':
        with core[1].begin() as session:
            session.get(RedeemabilityReserve, 'global').observed_at -= timedelta(minutes=5)
    if failure == 'paused':
        from app.modules.wallet.models import WalletControl
        with core[1].begin() as session:
            session.get(WalletControl, 'global').withdrawals_paused = True
    if failure == 'conflict':
        wallet.convert('alice', 'USDT_TO_CAIBI', '1.000000', 'attempt')
    before = (wallet.usdt_balance('alice'), LedgerService(core[1]).balance('alice'))
    with pytest.raises(ValueError):
        wallet.convert('alice', 'USDT_TO_CAIBI', '1001.000000' if failure == 'insufficient' else '10.000000', 'attempt')
    assert (wallet.usdt_balance('alice'), LedgerService(core[1]).balance('alice')) == before
