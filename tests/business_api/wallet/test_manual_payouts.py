from datetime import datetime, timedelta, timezone
from decimal import Decimal
from importlib.util import find_spec

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, HoldType, RoleCode
from app.modules.identity.models import Device, RefreshTokenFamily, SecurityHold, User, UserRole
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.models import WalletControl
from app.modules.wallet.service import WalletLedger
from app.modules.ledger.reserve import RedeemabilityReserve


def test_manual_payout_module_exists():
    assert find_spec('app.modules.wallet.manual_payouts') is not None


@pytest.fixture
def core():
    from coincurve import PrivateKey
    from app.integrations.tron.message_signature import address_from_public_key
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutService, ManualPayoutPolicy
    from app.modules.wallet import manual_payout_models  # noqa: F401
    engine = create_engine('sqlite://', connect_args={'check_same_thread': False}, poolclass=StaticPool)
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
    with factory.begin() as s:
        s.add(RedeemabilityReserve(id='global', eligible_usdt=Decimal('1000'), usdt_liability=Decimal('1000'),
            version=1, pending_payouts=0, outgoing_restricted=False, observed_at=now[0]))
    class Finality:
        evidence = None
        def transaction_evidence(self, txid):
            return self.evidence
    finality = Finality()
    svc = ManualPayoutService(factory, official_config=OfficialFundingConfig(official, 'official-v1'),
        policy=ManualPayoutPolicy('test-v1', timedelta(minutes=5), Decimal('100'), Decimal('200'), Decimal('500')),
        owner_admin_id='owner', mfa_verifier=lambda **kw: kw['proof'] == '123456', finality=finality, clock=lambda: now[0])
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


def quote(c, **kw):
    return c[0].quote(**(dict(user_id='alice', amount='10.000000', expected_binding_version=1, idempotency_key='q') | kw))


def test_address_only_request_does_not_disable_admin_mfa(core):
    svc = core[0]
    svc.user_mfa_required = False
    order = request(core, mfa_proof=None)
    with pytest.raises(AppError):
        svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
            expected_digest=order['digest'], idempotency_key='claim-without-proof', mfa_proof=None)


def test_user_history_contains_manual_request_but_not_other_users(core):
    from app.modules.wallet.service import WalletService
    order = request(core)
    history = WalletService(core[1], None)
    items, _ = history.history('alice')
    assert any(item['id'] == order['id'] and item['kind'] == 'withdrawal' for item in items)
    assert history.history('bob')[0] == []


def request(c, q=None, **kw):
    q = q or quote(c)
    key = kw.get('idempotency_key', 'r')
    identity = (key, q['id'])
    if identity not in c[0].fixture_tickets:
        c[0].fixture_tickets[identity] = c[0].payment_pin.authorize(claims=c[0].fixture_claims,
            pin='654321', action='wallet.payout.create', payload={'quote_id': q['id']},
            idempotency_key=key)['authorization']
    return c[0].request(**(dict(user_id='alice', session_id='session', mfa_proof='123456', quote_id=q['id'],
        claims=c[0].fixture_claims, payment_authorization=c[0].fixture_tickets[identity], idempotency_key=key) | kw))


def claim(c, order=None, **kw):
    order = order or request(c)
    return c[0].claim(**(dict(admin_id='owner', session_id='admin-session', mfa_proof='123456', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim') | kw))


def test_manual_liquidity_accepts_request_but_blocks_underfunded_claim(core):
    core[0].reserve_policy = 'manual_liquidity'
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('9')
    order = request(core)
    assert order['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with pytest.raises(AppError) as exc:
        claim(core, order)
    assert exc.value.code == 'WALLET_PAYMENT_LIQUIDITY_INSUFFICIENT'
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('10')
    assert claim(core, order)['status'] == 'CLAIMED'


def test_claim_rolls_back_if_reserve_expires_during_audit(core, monkeypatch):
    core[0].reserve_policy = 'manual_liquidity'
    order = request(core)
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').observed_at = core[2][0] - timedelta(seconds=119)
    record = core[0]._record
    def delayed_record(*args, **kwargs):
        result = record(*args, **kwargs)
        core[2][0] += timedelta(seconds=2)
        return result
    monkeypatch.setattr(core[0], '_record', delayed_record)
    with pytest.raises(AppError, match='WALLET_RESERVE_UNAVAILABLE'):
        claim(core, order)
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, 'global').pending_payouts == 0


def test_request_freezes_and_cancel_releases_once(core):
    q = quote(core)
    assert q['fee'] == '0.000000'
    assert q['amount'] == q['hold'] == q['receive'] == '10.000000'
    o = request(core, q)
    assert request(core, q) == o
    assert core[5].balance('alice') == Decimal('990')
    assert core[5].balance('HOLD:alice') == Decimal('10')
    result = core[0].cancel(user_id='alice', order_id=o['id'], idempotency_key='cancel')
    assert result['status'] == 'CANCELLED'
    assert core[0].cancel(user_id='alice', order_id=o['id'], idempotency_key='cancel') == result
    assert core[5].balance('alice') == Decimal('1000')


@pytest.mark.parametrize('amount', ['9.999999', '10', 'NaN', '10.0000001', '-10.000000', '101.000000'])
def test_bad_amount(core, amount):
    with pytest.raises(AppError):
        quote(core, amount=amount)


def test_expiry_mfa_and_digest(core):
    q = quote(core)
    with pytest.raises(AppError):
        request(core, q, mfa_proof='000000')
    core[2][0] += timedelta(minutes=5)
    with core[1].begin() as s:
        s.get(RedeemabilityReserve, 'global').observed_at = core[2][0]
    with pytest.raises(AppError, match='EXPIRED'):
        request(core, q)


def test_claim_requires_admin_and_preserves_freeze(core):
    o = request(core)
    with pytest.raises(AppError):
        claim(core, o, admin_id='bob')
    with pytest.raises(AppError):
        claim(core, o, expected_digest='bad')
    result = claim(core, o)
    assert result['instructions']['target_address'] == core[3]
    assert result['instructions']['official_address'] == core[4]
    with pytest.raises(AppError):
        core[0].cancel(user_id='alice', order_id=o['id'], idempotency_key='cancel')
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with core[1]() as s:
        assert s.get(RedeemabilityReserve, 'global').pending_payouts == 1


@pytest.mark.parametrize('gate', ['missing', 'stale', 'paused', 'held'])
def test_fail_closed_gates(core, gate):
    with core[1].begin() as s:
        if gate == 'missing':
            s.delete(s.get(RedeemabilityReserve, 'global'))
        if gate == 'stale':
            s.get(RedeemabilityReserve, 'global').observed_at -= timedelta(minutes=3)
        if gate == 'paused':
            s.get(WalletControl, 'global').withdrawals_paused = True
        if gate == 'held':
            s.add(SecurityHold(id='hold', user_id='alice', hold_type=HoldType.WITHDRAWAL, reason_code='TEST',
                starts_at=core[2][0], ends_at=core[2][0]+timedelta(hours=1), created_at=core[2][0]))
    with pytest.raises(AppError):
        request(core)


def evidence(c, **overrides):
    from app.integrations.tron.finality import TransactionEvidence, TransferEvidence, SolidHead
    txid = 'a'*64
    # A newly observed solid head cannot be in the future of its observation.
    # Advance the synthetic clock to model a transfer after the claim.
    c[2][0] += timedelta(seconds=1)
    ms = int(c[2][0].timestamp()*1000)
    fields = dict(txid=txid, log_index=0, block_number=200, block_id='b'*64, timestamp_ms=ms,
        from_address=c[4], to_address=c[3], amount_units=10000000)
    fields.update(overrides)
    return TransactionEvidence(txid, 200, 'b'*64, ms, SolidHead(201, 'c'*64, ms, c[2][0]),
        (TransferEvidence(**fields),), c[2][0])


@pytest.mark.parametrize('bad', [{}, {'from_address':'wrong'}, {'to_address':'wrong'}, {'amount_units':1}, {'contract':'wrong'}])
def test_only_exact_evidence_settles(core, bad):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    core[6].evidence = evidence(core, **bad)
    result = core[0].reconcile(order_id=o['id'])
    assert result['status'] == ('UNKNOWN' if bad else 'SETTLED')
    assert core[5].balance('HOLD:alice') == (Decimal('10') if bad else Decimal('0'))
    assert core[0].reconcile(order_id=o['id'])['status'] == result['status']


def test_missing_evidence_never_releases(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    assert core[0].reconcile(order_id=o['id'])['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_other_actual_admin_cannot_claim(core):
    with core[1].begin() as s:
        s.add(UserRole(id='other-role', user_id='bob', role_code=RoleCode.SUPER_ADMIN, assigned_by='owner', assigned_at=core[2][0]))
    with pytest.raises(AppError, match='OWNER'):
        claim(core, admin_id='bob')


def test_mfa_delay_cannot_use_expired_quote(core):
    q = quote(core)
    def delayed_mfa(**kwargs):
        core[2][0] += timedelta(minutes=6)
        with core[1].begin() as s:
            s.get(RedeemabilityReserve, 'global').observed_at = core[2][0]
        return True
    core[0].mfa_verifier = delayed_mfa
    with pytest.raises(AppError, match='EXPIRED'):
        request(core, q)


def test_same_event_never_settles_two_orders(core):
    first = request(core)
    second = request(core, quote(core, idempotency_key='q2'), idempotency_key='r2')
    claim(core, first)
    core[0].submit_txid(admin_id='owner', order_id=first['id'], txid='a'*64, idempotency_key='t1')
    core[6].evidence = evidence(core)
    assert core[0].reconcile(order_id=first['id'])['status'] == 'SETTLED'
    with core[1].begin() as s:
        s.get(RedeemabilityReserve, 'global').observed_at = core[2][0]
    claim(core, second, idempotency_key='c2')
    core[0].submit_txid(admin_id='owner', order_id=second['id'], txid='a'*64, idempotency_key='t2')
    assert core[0].reconcile(order_id=second['id'])['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_settlement_rolls_back_event_ledger_status(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutEvent
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    core[6].evidence = evidence(core)
    original = core[0].wallet_ledger.post
    def fail_after_post(**kwargs):
        original(**kwargs)
        raise RuntimeError('injected failure')
    core[0].wallet_ledger.post = fail_after_post
    with pytest.raises(RuntimeError):
        core[0].reconcile(order_id=o['id'])
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with core[1]() as s:
        assert s.scalar(select(ManualPayoutEvent.id)) is None
        assert s.get(RedeemabilityReserve, 'global').pending_payouts == 1
    core[0].wallet_ledger.post = original
    assert core[0].reconcile(order_id=o['id'])['status'] == 'SETTLED'


def test_rolling_limit_includes_legacy(core):
    from app.modules.wallet.models import Withdrawal
    with core[1].begin() as s:
        s.add(Withdrawal(id='legacy', user_id='alice', client_order_id='legacy', address=core[3],
            amount=Decimal('195'), status='UNKNOWN', created_at=core[2][0], updated_at=core[2][0]))
    with pytest.raises(AppError, match='LIMIT'):
        request(core)


def test_quote_and_request_idempotency_conflict(core):
    q = quote(core)
    with pytest.raises(AppError, match='IDEMPOTENCY_CONFLICT'):
        quote(core, amount='11.000000')
    request(core, q)
    q2 = quote(core, idempotency_key='q2')
    with pytest.raises(AppError, match='IDEMPOTENCY_CONFLICT'):
        request(core, q2)


def test_lock_wait_cannot_turn_old_mfa_into_claim_instructions(core):
    o = request(core)
    original = core[0]._lock
    def delayed_lock(session, user_id):
        result = original(session, user_id)
        core[2][0] += timedelta(seconds=31)
        return result
    core[0]._lock = delayed_lock
    with pytest.raises(AppError, match='MFA'):
        claim(core, o)


def test_self_target_and_binding_change_denied(core):
    from app.modules.wallet.funding import OfficialFundingConfig
    core[0].official_config = OfficialFundingConfig(core[3], 'bad-target')
    with pytest.raises(AppError, match='OFFICIAL_TARGET'):
        quote(core)


def test_old_evidence_and_wrong_policy_keep_freeze(core):
    from dataclasses import replace
    o = claim(core)
    before_claim_ms = int(core[2][0].timestamp()*1000)-1
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    core[6].evidence = replace(evidence(core), policy='OTHER')
    assert core[0].reconcile(order_id=o['id'])['status'] == 'UNKNOWN'
    old = evidence(core)
    oldms = before_claim_ms
    core[6].evidence = replace(old, timestamp_ms=oldms, transfers=(replace(old.transfers[0], timestamp_ms=oldms),))
    assert core[0].reconcile(order_id=o['id'])['status'] == 'UNKNOWN'


def test_snapshots_and_terminal_status_immutable(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote
    o = request(core)
    with pytest.raises(ValueError, match='immutable'):
        with core[1].begin() as s:
            s.get(ManualPayoutQuote, o['quote_id']).amount = Decimal('20')
    core[0].cancel(user_id='alice', order_id=o['id'], idempotency_key='cancel')
    with pytest.raises(ValueError, match='illegal'):
        with core[1].begin() as s:
            s.get(ManualPayoutOrder, o['id']).status = 'CLAIMED'


def test_claim_audit_failure_returns_no_instructions_or_pending(core):
    o = request(core)
    def fail_record(*args, **kwargs):
        raise RuntimeError('audit unavailable')
    core[0]._record = fail_record
    with pytest.raises(RuntimeError):
        claim(core, o)
    assert core[0].status(user_id='alice', order_id=o['id'])['status'] == 'REQUESTED'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve, 'global').pending_payouts == 0


def test_global_limit_and_cancel_exclusion(core):
    from app.modules.wallet.models import Withdrawal
    with core[1].begin() as s:
        s.add(Withdrawal(id='legacy', user_id='bob', client_order_id='legacy', address=core[3],
            amount=Decimal('495'), status='CHAIN_CONFIRMED', created_at=core[2][0], updated_at=core[2][0]))
    with pytest.raises(AppError, match='LIMIT'):
        request(core)


def test_claim_stale_reserve_admin_hold_and_role_revocation(core):
    o = request(core)
    with core[1].begin() as s:
        s.get(RedeemabilityReserve, 'global').observed_at -= timedelta(minutes=3)
    with pytest.raises(AppError, match='RESERVE'):
        claim(core, o)
    with core[1].begin() as s:
        s.get(RedeemabilityReserve, 'global').observed_at = core[2][0]
        s.add(SecurityHold(id='owner-hold', user_id='owner', hold_type=HoldType.WITHDRAWAL, reason_code='TEST',
            starts_at=core[2][0], ends_at=core[2][0]+timedelta(hours=1), created_at=core[2][0]))
    with pytest.raises(AppError) as error:
        claim(core, o)
    assert error.value.code == 'WALLET_RECOVERY_HOLD'


def test_invalid_initial_claim_shape_rejected(core):
    from sqlalchemy.exc import IntegrityError
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    q = quote(core)
    with pytest.raises(IntegrityError):
        with core[1].begin() as s:
            s.add(ManualPayoutOrder(id='bad-order', quote_id=q['id'], user_id='alice', amount=Decimal('10'),
                digest=q['digest'], status='CLAIMED', created_at=core[2][0], updated_at=core[2][0]))


def test_claimed_replay_denies_revoked_admin(core):
    o = claim(core)
    with core[1].begin() as s:
        s.delete(s.get(UserRole, 'role'))
    with pytest.raises(AppError):
        claim(core, o)
    assert 'instructions' not in core[0].status(user_id='alice', order_id=o['id'])


def test_pending_binding_safety_epoch_and_user_status(core):
    from app.modules.wallet.models import WalletSafetyState
    q = quote(core)
    with core[1].begin() as s:
        s.add(WalletSafetyState(id='alice', restricted=False, epoch=1, reason='TEST'))
    with pytest.raises(AppError, match='QUOTE_CHANGED'):
        request(core, q)


def test_pending_binding_denies_new_quote(core):
    with core[1].begin() as s:
        s.get(WalletBindingState, 'alice').pending_binding_id = 'pending'
    with pytest.raises(AppError, match='BINDING_PENDING'):
        quote(core)


def test_after_claim_new_work_blocked_but_paused_settlement_allowed(core):
    o = claim(core)
    with pytest.raises(AppError, match='RESERVE'):
        quote(core, idempotency_key='q2')
    with core[1].begin() as s:
        s.get(WalletControl, 'global').withdrawals_paused = True
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    core[6].evidence = evidence(core)
    assert core[0].reconcile(order_id=o['id'])['status'] == 'SETTLED'


def test_nonterminal_public_binding_guard(core):
    from app.modules.wallet.manual_payouts import has_pending_manual_payout
    o = request(core)
    with core[1]() as s:
        assert has_pending_manual_payout(s, user_id='alice')
        assert not has_pending_manual_payout(s, user_id='bob')
    core[0].cancel(user_id='alice', order_id=o['id'], idempotency_key='cancel')
    with core[1]() as s:
        assert not has_pending_manual_payout(s, user_id='alice')


def test_unknown_claim_replay_does_not_reissue_payment_instructions(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    with pytest.raises(AppError, match='CLAIM_UNAVAILABLE'):
        claim(core, o)


@pytest.mark.parametrize('operation', ['request', 'claim'])
def test_slow_mfa_verifier_cannot_refresh_its_own_authentication_time(core, operation):
    q = quote(core)
    order = request(core, q) if operation == 'claim' else None
    def slow_verifier(**kwargs):
        core[2][0] += timedelta(seconds=31)
        return True
    core[0].mfa_verifier = slow_verifier
    with pytest.raises(AppError, match='MFA_EXPIRED'):
        claim(core, order) if operation == 'claim' else request(core, q)
    assert core[5].balance('HOLD:alice') == (Decimal('10') if operation == 'claim' else Decimal('0'))
    if order:
        assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve, 'global').pending_payouts == 0


def correct(c, order, **kwargs):
    assert hasattr(c[0], 'correct_candidate'), 'append-only candidate recovery missing'
    return c[0].correct_candidate(**(dict(admin_id='owner', session_id='admin-session', mfa_proof='123456',
        order_id=order['id'], txid='b'*64, reason_code='WRONG_LOCATOR', idempotency_key='correct') | kwargs))


def candidate_evidence(c, txid):
    from dataclasses import replace
    result = evidence(c)
    return replace(result, txid=txid, transfers=(replace(result.transfers[0], txid=txid),))


def test_correct_candidate_settles_without_replacing_original(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    result = correct(core, o)
    assert result['status'] == 'UNKNOWN' and 'instructions' not in result
    assert correct(core, o) == result
    core[6].transaction_evidence = lambda txid: candidate_evidence(core, txid) if txid == 'b'*64 else None
    settled = core[0].reconcile(order_id=o['id'])
    assert settled['status'] == 'SETTLED'
    assert settled['candidate_txid'] == 'a'*64
    assert settled['settlement_txid'] == 'b'*64
    assert core[0].reconcile(order_id=o['id']) == settled
    assert core[0].status(user_id='alice', order_id=o['id']) == settled
    assert core[5].balance('HOLD:alice') == Decimal('0')


@pytest.mark.parametrize('kwargs', [{'admin_id':'bob'}, {'mfa_proof':'000000'}, {'reason_code':'free text'}, {'reason_code':''}])
def test_candidate_correction_requires_owner_mfa_stable_reason(core, kwargs):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    with pytest.raises(AppError):
        correct(core, o, **kwargs)


def test_candidate_reason_and_key_conflict(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    correct(core, o)
    with pytest.raises(AppError, match='IDEMPOTENCY_CONFLICT'):
        correct(core, o, reason_code='OPERATOR_REVIEW')


def test_multiple_matching_candidates_keep_hold(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    correct(core, o)
    core[6].transaction_evidence = lambda txid: candidate_evidence(core, txid)
    result = core[0].reconcile(order_id=o['id'])
    assert result['status'] == 'UNKNOWN'
    assert result['review_reason'] == 'MULTIPLE_MATCHING_PAYOUT_EVENTS'
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_candidate_change_during_io_defers_settlement(core):
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    def fetch(txid):
        correct(core, o)
        return candidate_evidence(core, txid)
    core[6].transaction_evidence = fetch
    result = core[0].reconcile(order_id=o['id'])
    assert result['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_candidate_correction_audits_operator_reason(core):
    from app.modules.audit.models import AuditEvent
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    correct(core, o)
    with core[1]() as s:
        recorded = s.scalar(select(AuditEvent).where(AuditEvent.subject_id == o['id'],
            AuditEvent.action == 'wallet.manual_payout_correct_candidate'))
        assert recorded.reason_code == 'WRONG_LOCATOR'


def test_candidate_correction_requires_existing_initial_locator(core):
    o = claim(core)
    assert core[0].reconcile(order_id=o['id'])['status'] == 'UNKNOWN'
    with pytest.raises(AppError, match='CORRECTION_UNAVAILABLE'):
        correct(core, o)


def test_candidate_limit_immutability_and_initial_row(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutCandidate
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    for index in range(9):
        correct(core, o, txid=format(index, '064x'), idempotency_key='candidate-'+str(index))
    with pytest.raises(AppError, match='CANDIDATE_LIMIT'):
        correct(core, o, txid='b'*64)
    with core[1]() as s:
        rows = list(s.scalars(select(ManualPayoutCandidate).where(ManualPayoutCandidate.order_id == o['id'])))
        assert len(rows) == 10
        first = next(row for row in rows if row.txid == 'a'*64)
        assert first.actor_id == 'owner' and first.reason_code == 'INITIAL_LOCATOR'
        candidate_id = first.id
    with pytest.raises(ValueError, match='immutable'):
        with core[1].begin() as s:
            s.get(ManualPayoutCandidate, candidate_id).reason_code = 'CHANGED'


def test_multiple_logs_are_sticky_review(core):
    from dataclasses import replace
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    found = evidence(core)
    core[6].evidence = replace(found, transfers=(found.transfers[0], replace(found.transfers[0], log_index=1)))
    result = core[0].reconcile(order_id=o['id'])
    assert result['review_reason'] == 'MULTIPLE_MATCHING_PAYOUT_EVENTS'
    core[6].evidence = found
    assert core[0].reconcile(order_id=o['id'])['status'] == 'UNKNOWN'


def test_legacy_initial_locator_is_checked_without_backfill(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutCandidate
    o = claim(core)
    # Simulate a durable order written before the additive candidate table existed.
    with core[1].begin() as s:
        row = s.get(ManualPayoutOrder, o['id'])
        row.status, row.candidate_txid = 'UNKNOWN', 'a'*64
    correct(core, o)
    checked = []
    def fetch(txid):
        checked.append(txid)
        return candidate_evidence(core, txid) if txid == 'b'*64 else None
    core[6].transaction_evidence = fetch
    assert core[0].reconcile(order_id=o['id'])['settlement_txid'] == 'b'*64
    assert checked == ['a'*64, 'b'*64]
    with core[1]() as s:
        assert list(s.scalars(select(ManualPayoutCandidate.txid))) == ['b'*64]


def test_candidate_audit_failure_rolls_back_append(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutCandidate
    o = claim(core)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    def unavailable_audit(*args, **kwargs):
        raise RuntimeError('audit unavailable')
    core[0]._record = unavailable_audit
    with pytest.raises(RuntimeError):
        correct(core, o)
    with core[1]() as s:
        assert list(s.scalars(select(ManualPayoutCandidate.txid))) == ['a'*64]
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_candidate_slow_mfa_and_claimed_state_denied(core):
    o = claim(core)
    with pytest.raises(AppError, match='CORRECTION_UNAVAILABLE'):
        correct(core, o)
    core[0].submit_txid(admin_id='owner', order_id=o['id'], txid='a'*64, idempotency_key='tx')
    def slow_verifier(**kwargs):
        core[2][0] += timedelta(seconds=31)
        return True
    core[0].mfa_verifier = slow_verifier
    with pytest.raises(AppError, match='MFA_EXPIRED'):
        correct(core, o)
