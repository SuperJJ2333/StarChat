from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app.core.errors import AppError
from app.integrations.tron.finality import AccountControlEvidence, SolidHead


def test_single_source_binding_bridge_preserves_real_evidence():
    from app.modules.wallet.binding_adapters import TronBindingVerifier
    now = datetime(2026, 9, 7, tzinfo=timezone.utc)
    evidence = AccountControlEvidence('isolated-address', SolidHead(100, 'a'*64, 1, now), now)
    finality = SimpleNamespace(account_control=lambda address: evidence)
    verifier = TronBindingVerifier(finality)
    assert verifier.permission(address='isolated-address', network='tron-mainnet', now=now)
    barrier = verifier.barrier(binding=SimpleNamespace(id='binding1', address='isolated-address'), now=now)
    assert barrier.policy == 'TRONGRID_SINGLE_SOURCE_V1'
    assert barrier.binding_id == 'binding1'
    assert barrier.source_ids == ('trongrid-mainnet',)


def test_mfa_uses_server_totp_and_rate_limit_not_caller_assertion():
    from app.modules.wallet.binding_adapters import WalletTotpVerifier
    now = datetime(2026, 9, 7, tzinfo=timezone.utc)
    verified, limited = [], []
    totp = SimpleNamespace(verify=lambda user, proof: verified.append((user, proof)) or now)
    limiter = SimpleNamespace(hit=lambda key, **kwargs: limited.append((key, kwargs)))
    verifier = WalletTotpVerifier(totp, limiter, clock=lambda: now)
    assert verifier(user_id='alice', session_id='actual-family', proof='123456', now=now)
    assert verified == [('alice', '123456')]
    assert len(limited) == 1
    with pytest.raises(AppError):
        verifier(user_id='alice', session_id='actual-family', proof='verified', now=now)
    assert len(verified) == 1


@pytest.mark.parametrize('age', [-1, 31])
def test_mfa_timestamp_must_come_from_recent_server_verification(age):
    from app.modules.wallet.binding_adapters import WalletTotpVerifier
    now = datetime(2026, 9, 7, tzinfo=timezone.utc)
    totp = SimpleNamespace(verify=lambda *args: now - timedelta(seconds=age))
    verifier = WalletTotpVerifier(totp, SimpleNamespace(hit=lambda *a, **k: None), clock=lambda: now)
    with pytest.raises(AppError):
        verifier(user_id='alice', session_id='actual-family', proof='123456', now=now)
