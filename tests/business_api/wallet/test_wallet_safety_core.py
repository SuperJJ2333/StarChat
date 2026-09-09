from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.ledger.service import LedgerService
from app.modules.wallet.service import WalletService


@pytest.fixture()
def core():
    engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    provider = SandboxCustodyProvider(secret='offline-only')
    service = WalletService(factory, provider, conversions_enabled=True)
    provider.custody_balance = Decimal('100')
    service.credit_for_test('alice', Decimal('50'))
    yield service, provider, factory
    engine.dispose()


def test_conversion_is_atomic_balanced_and_payload_bound(core):
    service, _, factory = core
    result = service.convert('alice', 'USDT_TO_CAIBI', '12.34', 'intent-1')
    assert result['status'] == 'COMPLETED'
    assert service.balances('alice')['usdt_available'] == '37.660000'
    assert LedgerService(factory).balance('alice') == Decimal('12.34')
    assert service.convert('alice', 'USDT_TO_CAIBI', '12.340000', 'intent-1') == result
    with pytest.raises(ValueError, match='payload'):
        service.convert('alice', 'USDT_TO_CAIBI', '1', 'intent-1')


def test_holds_at_creation_and_requires_two_non_self_approvers(core):
    service, _, _ = core
    row = service.request_withdrawal(user_id='alice', amount='10', address='T_OFFLINE', client_order_id='w1', reason_code='USER_WITHDRAWAL')
    assert service.balances('alice')['usdt_available'] == '40.000000'
    assert service.balances('alice')['usdt_held'] == '10.000000'
    with pytest.raises(ValueError):
        service.finance_approve(row.id, 'alice')
    with pytest.raises(ValueError):
        service.admin_approve(row.id, 'admin')
    service.finance_approve(row.id, 'finance')
    with pytest.raises(ValueError):
        service.admin_approve(row.id, 'finance')
    service.admin_approve(row.id, 'admin')
    service.submit_to_custody(row.id, 'worker')
    with pytest.raises(ValueError):
        service.cancel_withdrawal(row.id, 'alice')


def test_forged_signed_final_callback_cannot_release_hold(core):
    service, provider, _ = core
    row = service.request_withdrawal(user_id='alice', amount='10', address='T_OFFLINE', client_order_id='w2', reason_code='USER_WITHDRAWAL')
    payload = {'event_id': 'forged', 'type': 'WITHDRAWAL_STATUS', 'asset': 'USDT-TRC20', 'client_order_id': row.id, 'status': 'FAILED'}
    assert service.handle_withdrawal_webhook(payload, provider.sign(payload)) == 'REQUESTED'
    assert service.balances('alice')['usdt_held'] == '10.000000'


def test_cancel_releases_once(core):
    service, _, _ = core
    row = service.request_withdrawal(user_id='alice', amount='10', address='T_OFFLINE', client_order_id='w3', reason_code='USER_WITHDRAWAL')
    assert service.cancel_withdrawal(row.id, 'alice')['status'] == 'CANCELLED'
    assert service.cancel_withdrawal(row.id, 'alice')['status'] == 'CANCELLED'
    assert service.balances('alice')['usdt_available'] == '50.000000'


def test_reserve_counts_escrow_and_blocks_unfunded_issuance(core):
    service, provider, factory = core
    service.convert('alice', 'USDT_TO_CAIBI', '10', 'c1')
    ledger = LedgerService(factory)
    ledger.post(entries={'alice': Decimal('-10'), 'REDPACKET:one': Decimal('10')}, actor_id='alice', reason_code='ESCROW', idempotency_key='e1')
    provider.custody_balance = Decimal('50')
    service.refresh_reserve_evidence(actor_id='operator')
    with pytest.raises(ValueError, match='reserve'):
        ledger.adjust(user_id='alice', amount=Decimal('0.01'), actor_id='operator', reason_code='ISSUE', idempotency_key='issue')
    assert service.snapshot_report('operator')['caibi_liability'] == '10.00'


@pytest.mark.parametrize('amount', ['NaN', 'Infinity', '-1', '0', '1.0000001'])
def test_invalid_conversion_amount_is_rejected(core, amount):
    with pytest.raises(ValueError):
        core[0].convert('alice', 'USDT_TO_CAIBI', amount, 'bad')


def approved(core, key='approved'):
    service = core[0]
    row = service.request_withdrawal(user_id='alice', amount='10', address='T_OFFLINE', client_order_id=key, reason_code='USER_WITHDRAWAL')
    service.finance_approve(row.id, 'finance')
    service.admin_approve(row.id, 'admin')
    return row


def test_response_loss_retains_hold_and_query_settles_once(core, monkeypatch):
    service, provider, _ = core
    row = approved(core)
    submit = provider.submit_withdrawal
    def lose_response(**kwargs):
        submit(**kwargs)
        raise TimeoutError('accepted but response lost')
    monkeypatch.setattr(provider, 'submit_withdrawal', lose_response)
    with pytest.raises(TimeoutError):
        service.submit_to_custody(row.id, 'worker')
    assert service.withdrawal_status(row.id, 'alice')['status'] == 'UNKNOWN'
    service.submit_to_custody(row.id, 'worker')
    assert len(provider.enumerate_withdrawals()) == 1
    assert service.balances('alice')['usdt_held'] == '10.000000'
    provider.withdrawal_event(client_order_id=row.id, status='CHAIN_CONFIRMED', confirmations=20, event_id='final')
    assert service.resolve_unknown_withdrawal(row.id, actor_id='worker').status == 'CHAIN_CONFIRMED'
    service.resolve_unknown_withdrawal(row.id, actor_id='worker')
    assert service.balances('alice')['usdt_held'] == '0.000000'
    assert service.balances('alice')['usdt_available'] == '40.000000'


def test_failure_status_without_non_execution_evidence_does_not_refund(core):
    service, provider, _ = core
    row = approved(core)
    service.submit_to_custody(row.id, 'worker')
    provider.withdrawals[row.id]['status'] = 'FAILED'
    service.resolve_unknown_withdrawal(row.id, actor_id='worker')
    assert service.balances('alice')['usdt_held'] == '10.000000'


def test_solidification_and_independent_sources_are_required(core):
    service, provider, _ = core
    event = provider.deposit_event(user_id='bob', amount=Decimal('10'), confirmations=20, event_id='dep')
    evidence = provider.deposits[event.payload['txid']]
    evidence['sources'] = ['same-source', 'same-source']
    assert service.handle_deposit_webhook(event.payload, event.signature) == 'PENDING'
    evidence.update(provider._evidence(20))
    assert service.handle_deposit_webhook(event.payload, event.signature) == 'CREDITED'


def test_conversion_target_failure_rolls_back_source_and_order(core, monkeypatch):
    service, _, factory = core
    from app.modules.wallet.models import WalletConversion
    from sqlalchemy import select, func
    def fail(*args, **kwargs):
        raise RuntimeError('injected target failure')
    monkeypatch.setattr(LedgerService, 'post', fail)
    with pytest.raises(RuntimeError):
        service.convert('alice', 'USDT_TO_CAIBI', '10', 'rollback')
    assert service.usdt_balance('alice') == Decimal('50')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletConversion)) == 0


def test_recovery_enumerates_terminal_orphans_and_pauses(core):
    service, provider, _ = core
    provider.submit_withdrawal(client_order_id='missing-local', address='T_UNKNOWN', amount=Decimal('10'))
    provider.withdrawal_event(client_order_id='missing-local', status='CHAIN_CONFIRMED', confirmations=20, event_id='orphan')
    assert service.detect_orphan_external_orders(actor_id='recovery')['orphan_order_ids'] == ['missing-local']
    assert service.withdrawals_paused()
    with pytest.raises(ValueError, match='paused'):
        service.convert('alice', 'USDT_TO_CAIBI', '10', 'paused')


def test_reverse_conversion_preserves_all_liabilities(core):
    service, _, _ = core
    service.convert('alice', 'USDT_TO_CAIBI', '10', 'forward')
    before = service.snapshot_report('operator')['required_usdt']
    service.convert('alice', 'CAIBI_TO_USDT', '10', 'reverse')
    assert service.balances('alice')['usdt_available'] == '50.000000'
    assert service.snapshot_report('operator')['required_usdt'] == before


def test_points_only_mode_still_allows_issuance():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    LedgerService(factory).adjust(user_id='points', amount=Decimal('5'), actor_id='admin', reason_code='POINTS_ONLY', idempotency_key='p')
    assert LedgerService(factory).balance('points') == Decimal('5.00')
    engine.dispose()


def test_persistent_sandbox_recreated_provider_queries_and_enumerates(tmp_path):
    path = str(tmp_path / 'external.sqlite')
    provider = SandboxCustodyProvider(secret='offline', store_path=path)
    provider.custody_balance = Decimal('100')
    original = provider.submit_withdrawal(client_order_id='restart', address='T_OFFLINE', amount=Decimal('10'))
    restarted = SandboxCustodyProvider(secret='offline', store_path=path)
    assert restarted.get_withdrawal('restart')['status'] == 'SUBMITTED'
    assert restarted.submit_withdrawal(client_order_id='restart', address='T_OFFLINE', amount=Decimal('10')) == original
    with pytest.raises(ValueError, match='payload'):
        restarted.submit_withdrawal(client_order_id='restart', address='T_OTHER', amount=Decimal('10'))
    restarted.withdrawal_event(client_order_id='restart', status='CHAIN_CONFIRMED', confirmations=20, event_id='done')
    final = SandboxCustodyProvider(secret='offline', store_path=path)
    assert final.enumerate_withdrawals()[0]['status'] == 'CHAIN_CONFIRMED'
    assert final.custody_balance == Decimal('90')
    final.withdrawal_event(client_order_id='restart', status='CHAIN_CONFIRMED', confirmations=20, event_id='done-again')
    assert final.custody_balance == Decimal('90')


def test_issuance_blocks_while_external_payout_can_consume_snapshot(core):
    service, provider, factory = core
    service.refresh_reserve_evidence(actor_id='operator')
    row = approved(core)
    service.submit_to_custody(row.id, 'worker')
    provider.withdrawal_event(client_order_id=row.id, status='CHAIN_CONFIRMED', confirmations=20, event_id='paid-not-local')
    with pytest.raises(ValueError, match='unresolved payouts'):
        LedgerService(factory).adjust(user_id='alice', amount=Decimal('1'), actor_id='operator', reason_code='ISSUE', idempotency_key='inflight')
    service.resolve_unknown_withdrawal(row.id, actor_id='worker')
    assert service.snapshot_report('operator')['required_usdt'] == '40.000000'


def test_fractional_usdt_floors_with_visible_remainder_and_original_intent_binding(core):
    service = core[0]
    result = service.convert('alice', 'USDT_TO_CAIBI', '10.123456', 'fraction')
    assert result['source_amount'] == '10.120000'
    assert result['target_amount'] == '10.12'
    assert result['remainder'] == '0.003456'
    assert service.balances('alice')['usdt_available'] == '39.880000'
    with pytest.raises(ValueError, match='payload'):
        service.convert('alice', 'USDT_TO_CAIBI', '10.123457', 'fraction')


def test_confirmed_small_deposit_is_pending_payable_not_free_reserve(core):
    service, provider, factory = core
    provider.custody_balance = Decimal('50')
    event = provider.deposit_event(user_id='bob', amount=Decimal('0.5'), confirmations=20, event_id='small')
    assert service.handle_deposit_webhook(event.payload, event.signature) == 'MANUAL_REVIEW'
    service.refresh_reserve_evidence(actor_id='operator')
    assert service.snapshot_report('operator')['pending_deposit_payable'] == '0.500000'
    with pytest.raises(ValueError, match='reserve'):
        LedgerService(factory).adjust(user_id='alice', amount=Decimal('0.01'), actor_id='operator', reason_code='ISSUE', idempotency_key='small-free')


def test_restricted_redeemable_value_cannot_escape_via_transfer_or_escrow(core):
    service, _, factory = core
    service.convert('alice', 'USDT_TO_CAIBI', '10', 'fund')
    service.restrict_user('alice', actor_id='risk', reason_code='RISK_HOLD')
    ledger = LedgerService(factory)
    for receiver in ['bob', 'REDPACKET:escrow']:
        with pytest.raises(ValueError, match='restricted'):
            ledger.post(entries={'alice': Decimal('-1'), receiver: Decimal('1')}, actor_id='alice', reason_code='MOVE', idempotency_key=receiver)
    with pytest.raises(ValueError):
        service.convert('alice', 'CAIBI_TO_USDT', '1', 'escape')


def test_approval_digest_rejects_amount_or_destination_mutation(core):
    from app.modules.wallet.models import Withdrawal
    service, _, factory = core
    row = approved(core)
    with factory.begin() as session:
        session.get(Withdrawal, row.id).address = 'T_TAMPERED'
    with pytest.raises(ValueError, match='digest'):
        service.submit_to_custody(row.id, 'worker')
    assert service.balances('alice')['usdt_held'] == '10.000000'


def test_preexisting_restriction_survives_redeemability_activation(core):
    service, provider, factory = core
    WalletService(factory, provider).restrict_user('bob', actor_id='risk', reason_code='PRIOR_RISK')
    with pytest.raises(ValueError, match='paused'):
        service.convert('alice', 'USDT_TO_CAIBI', '1', 'activation')
