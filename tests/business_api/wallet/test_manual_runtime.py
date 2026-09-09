from datetime import datetime, timezone
from decimal import Decimal

from coincurve import PrivateKey
from cryptography.fernet import Fernet
import pytest
from sqlalchemy import create_engine

from app.core.config import Settings
from app.core.database import create_session_factory
from app.core.rate_limits import NoopRateLimiter
from app.integrations.tron.message_signature import address_from_public_key


def configured(**updates):
    values = dict(_env_file=None, environment='test', wallet_real_mode='manual_tron',
        totp_issuer='Test', wallet_totp_encryption_key=Fernet.generate_key().decode(),
        wallet_binding_domain='wallet.example.test', wallet_official_address=address_from_public_key(PrivateKey().public_key.format(compressed=False)),
        wallet_official_config_version='test-v1', wallet_manual_owner_admin_id='owner',
        wallet_manual_policy_version='test-v1', wallet_manual_max_per='100000.000000',
        wallet_manual_user_24h='100000.000000', wallet_manual_global_24h='10000000.000000',
        wallet_funding_baseline_at=datetime(2026,9,7,tzinfo=timezone.utc), wallet_funding_baseline_height=100)
    return Settings(**(values | updates))


def test_disabled_runtime_has_no_provider_or_funding_fallback():
    from app.modules.wallet.runtime import create_manual_wallet_runtime
    assert create_manual_wallet_runtime(Settings(_env_file=None), None, NoopRateLimiter()) is None


def test_independent_manual_capabilities_do_not_enable_payout_execution():
    from app.modules.wallet.runtime import create_manual_wallet_runtime
    settings = configured(wallet_deposits_enabled=True, wallet_payout_requests_enabled=True,
                          wallet_payout_execution_enabled=False, wallet_conversions_enabled=True,
                          wallet_reserve_policy='manual_liquidity')
    runtime = create_manual_wallet_runtime(settings, None, NoopRateLimiter())
    try:
        assert runtime.deposits_enabled
        assert runtime.payout_requests_enabled
        assert not runtime.payout_execution_enabled
        assert runtime.conversions_enabled
        assert runtime.receipts.reserve_policy == 'manual_liquidity'
    finally:
        runtime.close()


def test_disabled_mode_rejects_independent_funding_flags():
    with pytest.raises(ValueError):
        Settings(_env_file=None, wallet_deposits_enabled=True)


@pytest.mark.parametrize('missing', ['wallet_totp_encryption_key','wallet_binding_domain','wallet_official_address',
    'wallet_official_config_version','wallet_manual_owner_admin_id','wallet_manual_policy_version',
    'wallet_manual_max_per','wallet_manual_user_24h','wallet_manual_global_24h',
    'wallet_funding_baseline_at','wallet_funding_baseline_height'])
def test_enabled_mode_requires_explicit_settings(missing):
    with pytest.raises(ValueError): configured(**{missing: None})


def test_runtime_wires_single_source_real_mfa_and_server_limits():
    from app.modules.wallet.runtime import create_manual_wallet_runtime
    settings = configured()
    engine = create_engine('sqlite://')
    runtime = create_manual_wallet_runtime(settings, create_session_factory(engine), NoopRateLimiter())
    try:
        assert runtime.binding.finality_policy == 'TRONGRID_SINGLE_SOURCE_V1'
        assert runtime.binding.mfa_verifier is not None
        assert runtime.payouts.policy.max_per == Decimal('100000.000000')
        assert runtime.payouts.policy.user_24h == Decimal('100000.000000')
        assert runtime.payouts.policy.global_24h == Decimal('10000000.000000')
        assert runtime.funds_enabled is False
        assert runtime.receipts.adapter is runtime.finality
    finally:
        runtime.close()
        engine.dispose()


@pytest.mark.parametrize('value', ['9.999999','1e5','100000.0000001','NaN',100000.0])
def test_runtime_limits_require_exact_decimal_strings(value):
    with pytest.raises(ValueError): configured(wallet_manual_max_per=value)


def test_runtime_funds_cannot_enable_in_disabled_mode():
    with pytest.raises(ValueError):
        Settings(_env_file=None, wallet_real_funds_enabled=True)


def test_runtime_baseline_requires_aware_time():
    with pytest.raises(ValueError): configured(wallet_funding_baseline_at=datetime(2026,9,7))
