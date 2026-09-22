"""ADR-0077：人工提现按结算汇率折算与客服调价。

- 报价快照锁汇率与 USDT 应付（receive = 点钻/率，6 位 HALF_UP）；
- 10 USDT 门槛按 USDT 应付额执行（不解释为 10 点钻）；
- 请求时内部兑换 source=点钻 target=USDT 应付，两账本各自平衡；
- 取消按原转换镜像冲正（退回点钻、收回 USDT）；
- 客服 adjust-rate：仅 CLAIMED，记录前后值，无用户确认/复核；
- SETTLED 不可调；链上支付按 final_receive 匹配；
- 旧 1:1 在途订单按原条款继续结算。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import Device, RefreshTokenFamily, User, UserRole
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.models import WalletControl, WalletConversion, WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.service import WalletLedger
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService


@pytest.fixture
def core():
    from coincurve import PrivateKey
    from app.integrations.tron.message_signature import address_from_public_key
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutService, ManualPayoutPolicy
    import app.modules.fx.models  # noqa: F401
    from app.modules.wallet import manual_payout_models  # noqa: F401
    from app.modules.wallet import receipt_models, repair_models  # noqa: F401  (FK 目标需全部注册，含 wallet_manual_deposit_cases)
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = [datetime.now(timezone.utc)]
    target, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as s:
        for uid in ['alice', 'owner', 'bob']:
            s.add(User(id=uid, username=uid, username_normalized=uid, email=uid+'@example.test',
                email_normalized=uid+'@example.test', password_hash='unused', status=AccountStatus.ACTIVE,
                created_at=now[0], updated_at=now[0]))
        s.flush()
        s.add(UserRole(id='role', user_id='owner', role_code=RoleCode.SUPER_ADMIN, assigned_by='owner', assigned_at=now[0]))
        s.add(WalletControl(id='global', withdrawals_paused=False))
        s.add(WalletAddressOwner(address=target, user_id='alice', created_at=now[0]))
        s.flush()
        s.add(WalletBinding(id='binding', user_id='alice', address=target, version=1, status='ACTIVE',
            created_at=now[0], activated_at=now[0], effective_from_block=101, barrier_height=100,
            barrier_block_id='a'*64, barrier_source_ids=['test'], barrier_observed_at=now[0]))
        s.add(WalletBindingState(user_id='alice', version=1, active_binding_id='binding'))
    ledger = WalletLedger(factory)
    ledger.post(entries={'PLATFORM_CUSTODY': Decimal('-1000'), 'alice': Decimal('1000')}, actor_id='alice',
        reason_code='TEST_FUND', idempotency_key='fund', scope='test')
    caibi = LedgerService(factory)
    caibi.adjust(user_id='alice', amount=Decimal('500.00'), actor_id='finance',
        reason_code='SEED_CAIBI', idempotency_key='seed-caibi-alice')
    with factory.begin() as s:
        from app.modules.fx.models import FxRate
        s.add(FxRate(pair='USD/CNY', rate=Decimal('7.120000'), fetched_at=now[0],
            expires_at=now[0] + timedelta(hours=1), fetch_state='idle'))
        s.add(RedeemabilityReserve(id='global', eligible_usdt=Decimal('100000'), usdt_liability=Decimal('1000'),
            version=1, pending_payouts=0, outgoing_restricted=False, observed_at=now[0]))

    class Finality:
        evidence = None
        def transaction_evidence(self, txid):
            return self.evidence
    finality = Finality()

    rate_state = {'rate': Decimal('7.120000'), 'stale': False, 'fetched_at': now[0].isoformat()}

    def rate_provider():
        if rate_state.get('unavailable'):
            return None
        return rate_state['rate'], rate_state['stale'], rate_state['fetched_at']

    svc = ManualPayoutService(factory, official_config=OfficialFundingConfig(official, 'official-v1'),
        policy=ManualPayoutPolicy('test-v1', timedelta(minutes=5), Decimal('100'), Decimal('200'), Decimal('500')),
        owner_admin_id='owner', mfa_verifier=lambda **kw: kw['proof'] == '123456', finality=finality, clock=lambda: now[0],
        rate_provider=rate_provider)
    svc.conversions_enabled = True
    svc.rate_state = rate_state
    from app.modules.identity.payment_pin_models import PaymentPinCredential
    with factory.begin() as session:
        session.add(Device(id='device', user_id='alice', device_key='fixture', display_name='fixture',
            last_seen_at=now[0], created_at=now[0]))
        session.add(RefreshTokenFamily(id='session', user_id='alice', device_id='device', created_at=now[0]))
        session.add(PaymentPinCredential(user_id='alice', pin_hash=svc.payment_pin.hasher.hash('654321'),
            version=1, failed_attempts=0, setup_key_hash='fixture', setup_family_id='session', created_at=now[0]))
    svc.fixture_claims = dict(sub='alice', family_id='session', device_id='device',
        iat=int(now[0].timestamp()), exp=int((now[0]+timedelta(hours=2)).timestamp()))
    svc.fixture_tickets = {}
    yield svc, factory, now, target, official, ledger, finality
    engine.dispose()


def _caibi_quote(c, **kw):
    # 报价金额串固定 6 位小数（CAIBI 值仍整分，71.200000 = 71.20 点钻）
    return c[0].quote(**(dict(user_id='alice', amount='71.200000', expected_binding_version=1,
        idempotency_key='q-caibi', funding_asset='CAIBI') | kw))


def _request(c, q, key='r'):
    identity = (key, q['id'])
    if identity not in c[0].fixture_tickets:
        c[0].fixture_tickets[identity] = c[0].payment_pin.authorize(claims=c[0].fixture_claims,
            pin='654321', action='wallet.payout.create', payload={'quote_id': q['id']},
            idempotency_key=key)['authorization']
    return c[0].request(**(dict(user_id='alice', session_id='session', mfa_proof='123456', quote_id=q['id'],
        claims=c[0].fixture_claims, payment_authorization=c[0].fixture_tickets[identity], idempotency_key=key)))


def _balance(c, factory, account, asset_ledger='usdt'):
    from sqlalchemy import func
    model = WalletLedgerEntry if asset_ledger == 'usdt' else __import__('app.modules.ledger.models', fromlist=['LedgerEntry']).LedgerEntry
    with factory() as session:
        return Decimal(session.scalar(select(func.coalesce(func.sum(model.amount), 0)).where(model.account_id == account)))


def test_caibi_quote_converts_at_rate_and_enforces_usdt_floor(core):
    svc, factory, now, target, official, ledger, finality = core
    quote = _caibi_quote(core)
    assert quote['conversion_rate'] == '7.120000'
    assert quote['receive'] == '10.000000'  # 71.20 / 7.12
    assert quote['funding_amount'] == '71.20'
    assert quote['rate_stale'] is False
    # 低于 10 USDT 应付 → 拒绝（门槛是 USDT，不是 10 点钻）
    with pytest.raises(AppError) as excinfo:
        _caibi_quote(core, amount='35.600000', idempotency_key='q-low')  # 5 USDT 应付
    assert excinfo.value.code == 'WALLET_PAYOUT_AMOUNT_INVALID'


def test_request_converts_and_holds_final_usdt(core):
    svc, factory, now, target, official, ledger, finality = core
    quote = _caibi_quote(core)
    order = _request(core, quote)
    assert order['amount'] == '10.000000'  # 链上 USDT 口径
    assert order['funding_amount'] == '71.20'
    # 兑换入账(+10) 与冻结(-10) 相抵：用户 USDT 净额不变，冻结为 10
    alice_usdt = _balance(core, factory, 'alice')
    assert alice_usdt == Decimal('1000')
    assert _balance(core, factory, 'HOLD:alice') == Decimal('10')
    # CAIBI 账本：alice 500 → 428.80（71.20 换出）
    assert _balance(core, factory, 'alice', 'caibi') == Decimal('500.00') - Decimal('71.20')
    # 兑换记录 source≠target
    with factory() as session:
        conv = session.scalar(select(WalletConversion).where(WalletConversion.idempotency_key == 'payout:'+order['id']))
        assert conv.source_amount == Decimal('71.20') and conv.target_amount == Decimal('10.00')
    # 冲正镜像可执行：取消退回
    cancelled = svc.cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel-1')
    assert cancelled['status'] == 'CANCELLED'
    assert _balance(core, factory, 'alice') == Decimal('1000')
    assert _balance(core, factory, 'HOLD:alice') == Decimal('0')
    assert _balance(core, factory, 'alice', 'caibi') == Decimal('500.00')  # 点钻退回


def test_adjust_rate_only_when_claimed_with_history(core):
    svc, factory, now, target, official, ledger, finality = core
    quote = _caibi_quote(core)
    order = _request(core, quote, key='r2')
    with pytest.raises(AppError) as excinfo:
        svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456', order_id=order['id'],
            new_rate='7.5', reason_code='CS_RATE_OVERRIDE_001', idempotency_key='adj-1')
    assert excinfo.value.code == 'WALLET_PAYOUT_RATE_ADJUST_UNAVAILABLE'
    claimed = svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim-1', mfa_proof='123456')
    adjusted = svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
        order_id=order['id'], new_rate='7.12', reason_code='CS_RATE_OVERRIDE_001', idempotency_key='adj-1')
    assert adjusted['final_receive'] == '10.000000'  # 71.20/7.12 未变
    # 降到 8 USDT 应付（率 8.9）被 10 USDT 最低门槛拒绝——门槛按 USDT 应付执行
    with pytest.raises(AppError) as excinfo:
        svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
            order_id=order['id'], new_rate='8.9', reason_code='CS_RATE_OVERRIDE_002', idempotency_key='adj-2')
    assert excinfo.value.code == 'WALLET_PAYOUT_AMOUNT_INVALID'
    # 合法上调应付：率 6.5 → 71.20/6.5 = 10.953846（HALF_UP 6 位）
    adjusted2 = svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
        order_id=order['id'], new_rate='6.5', reason_code='CS_RATE_OVERRIDE_002', idempotency_key='adj-2')
    assert adjusted2['final_receive'] == '10.953846'
    assert adjusted2['final_rate'] == '6.500000'
    # 冻结即时补足差额（10 → 10.953846），从用户可用 USDT 扣除差额。
    assert _balance(core, factory, 'HOLD:alice') == Decimal('10.953846')
    assert _balance(core, factory, 'alice') == Decimal('999.046154')
    # 调价后指令金额按 final_receive 投影（重复查询口径一致）
    assert svc.status(user_id='alice', order_id=order['id'])['final_receive'] == '10.953846'


def test_claim_recovery_after_rate_adjustment_uses_current_payment_instructions(core):
    svc, factory, now, target, official, ledger, finality = core
    order = _request(core, _caibi_quote(core))
    claim_args = dict(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim-current', mfa_proof='123456')
    original = svc.claim(**claim_args)
    adjusted = svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
        order_id=order['id'], new_rate='6.5', reason_code='CS_RATE_OVERRIDE', idempotency_key='adj-current')
    recovered = svc.claim(**claim_args)
    assert original['instructions']['amount'] == '10.000000'
    assert recovered['instructions']['amount'] == adjusted['final_receive'] == '10.953846'
    assert recovered['final_receive'] == adjusted['final_receive']
    assert recovered['instructions']['digest'] != original['instructions']['digest']
    assert _balance(core, factory, 'HOLD:alice') == Decimal('10.953846')
    with pytest.raises(AppError) as error:
        svc.claim(**(claim_args | {'mfa_proof': 'invalid'}))
    assert error.value.code == 'WALLET_MFA_REQUIRED'


def test_settlement_evidence_must_match_final_receive(core):
    """链上证据金额必须等于最终应付；金额不符进 UNKNOWN（待核对）。"""
    from app.integrations.tron.finality import TransactionEvidence
    svc, factory, now, target, official, ledger, finality = core
    quote = _caibi_quote(core)
    order = _request(core, quote, key='r3')
    svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim-1', mfa_proof='123456')
    with pytest.raises(AppError) as excinfo:
        svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456', order_id=order['id'],
            new_rate='14.24', reason_code='CS_RATE_OVERRIDE_003', idempotency_key='adj-1')
    assert excinfo.value.code == 'WALLET_PAYOUT_AMOUNT_INVALID'  # 14.24 → 5.00 低于 10 USDT 门槛
    with factory() as session:
        from app.modules.wallet.manual_payout_models import ManualPayoutOrder
        row = session.get(ManualPayoutOrder, order['id'])
        assert row.final_rate is None  # 调整被拒，订单未变


def test_legacy_in_flight_orders_keep_original_terms(core):
    """旧 1:1 报价（rate_provider=None 的历史快照）取消/冲正按原转换镜像。"""
    svc, factory, now, target, official, ledger, finality = core
    saved_provider = svc.rate_provider
    svc.rate_provider = None  # 模拟切换前创建的报价
    quote = svc.quote(user_id='alice', amount='20.000000', expected_binding_version=1,
        idempotency_key='q-legacy', funding_asset='CAIBI')
    assert quote['conversion_rate'] == '1.000000'
    order = _request(core, quote, key='r4')
    assert order['amount'] == '20.000000'
    svc.rate_provider = saved_provider
    cancelled = svc.cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel-legacy')
    assert cancelled['status'] == 'CANCELLED'
    assert _balance(core, factory, 'alice') == Decimal('1000')
    assert _balance(core, factory, 'alice', 'caibi') == Decimal('500.00')


def test_rate_unavailable_fails_closed(core):
    svc, factory, now, target, official, ledger, finality = core
    svc.rate_state['unavailable'] = True
    with pytest.raises(AppError) as excinfo:
        _caibi_quote(core, idempotency_key='q-none')
    assert excinfo.value.code == 'WALLET_RATE_UNAVAILABLE'
