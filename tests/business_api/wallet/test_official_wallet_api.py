from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import SecretStr
import pytest
from sqlalchemy import func, select

from app.core.errors import install_error_handlers
from app.modules.identity.tokens import TokenService
from app.modules.wallet.models import WalletLedgerTransaction
from test_manual_payouts import core  # noqa: F401


@pytest.fixture
def official_api(core):
    from app.api.official_wallet import create_official_wallet_router
    settings = SimpleNamespace(jwt_secret='official-read-test-secret-'*3,
        jwt_issuer='liuhetong', wallet_official_address=SecretStr(core[4]),
        wallet_real_mode='disabled', wallet_real_funds_enabled=False)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_official_wallet_router(settings, core[1]), prefix='/wallet')
    token = TokenService(core[1], jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer).issue_pair(user_id='alice', device_key='read-only', display_name='test').access_token
    return TestClient(app), {'Authorization': 'Bearer '+token}, settings


def test_official_address_visible_while_funds_closed_without_financial_write(core, official_api):
    client, headers, _ = official_api
    with core[1]() as session:
        before = session.scalar(select(func.count()).select_from(WalletLedgerTransaction))
    result = client.get('/wallet/official-deposit-address', headers=headers)
    assert result.status_code == 200
    assert result.json() == dict(address=core[4], asset='USDT', network='TRC20',
        minimum_deposit='10.000000', funding_enabled=False,
        notice='充值入账尚未开放，请勿转账。此处仅展示官方钱包地址。')
    assert result.headers['cache-control'] == 'no-store'
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == before


def test_official_address_requires_real_login(official_api):
    client, _, _ = official_api
    assert client.get('/wallet/official-deposit-address').status_code == 401


@pytest.mark.parametrize('value', [None, SecretStr('invalid')])
def test_missing_or_invalid_official_address_is_actionable_and_not_cached(official_api, value):
    client, headers, settings = official_api
    settings.wallet_official_address = value
    result = client.get('/wallet/official-deposit-address', headers=headers)
    assert result.status_code == 503
    assert result.json()['error']['code'] == 'WALLET_OFFICIAL_ADDRESS_UNAVAILABLE'
    assert 'invalid' not in result.text


def test_client_cannot_override_official_address(official_api, core):
    client, headers, _ = official_api
    assert client.post('/wallet/official-deposit-address', headers=headers,
        json={'address':'untrusted'}).status_code == 405
    result = client.get('/wallet/official-deposit-address?address=untrusted', headers=headers)
    assert result.json()['address'] == core[4]


def test_enabled_notice_does_not_promise_unbound_credit(official_api):
    client, headers, settings = official_api
    settings.wallet_real_mode = 'manual_tron'
    settings.wallet_real_funds_enabled = True
    result = client.get('/wallet/official-deposit-address', headers=headers)
    assert result.json()['funding_enabled'] is True
    assert '绑定' in result.json()['notice'] and '充值意图' in result.json()['notice']
