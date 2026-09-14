"""Contract-first tests for window-external deposit allocation cases."""
from dataclasses import replace
from decimal import Decimal, getcontext
from importlib.util import find_spec
from uuid import uuid4

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import AccountStatus, User, UserRole
from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
from test_deposit_receipts import core as receipt_core, ingest


def test_manual_deposit_case_application_service_exists():
    assert find_spec('app.modules.wallet.manual_deposit_cases') is not None


@pytest.fixture
def manual_core():
    from app.modules.wallet import manual_deposit_cases  # noqa: F401
    yield from receipt_core.__wrapped__()


def _service(core, *, amount_units=None, extra_transfer=False):
    from app.modules.wallet.manual_deposit_cases import ManualDepositCaseService
    from app.modules.wallet.repair_models import RepairCommand, RepairPreview
    RepairPreview.__table__.create(core[1].kw['bind'], checkfirst=True)
    RepairCommand.__table__.create(core[1].kw['bind'], checkfirst=True)
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False
        session.add(User(id='owner', username='owner', username_normalized='owner', email='o@example.test',
            email_normalized='o@example.test', password_hash='fixture', status=AccountStatus.ACTIVE,
            created_at=core[5], updated_at=core[5]))
        session.add(UserRole(id='owner-role', user_id='owner', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='fixture', assigned_at=core[5]))
    if amount_units is not None:
        transfer = core[2].value.transfers[0]
        core[2].value = replace(core[2].value, transfers=(replace(transfer, amount_units=amount_units),))
    if extra_transfer:
        transfer = core[2].value.transfers[0]
        core[2].value = replace(core[2].value, transfers=(transfer, replace(transfer, log_index=1)))
    receipt = ingest(core)[0]
    return ManualDepositCaseService(core[1], receipts=core[0], owner_admin_id='owner', clock_trusted=lambda: True), receipt


def test_window_external_case_requires_approval_then_credits_exactly_once(manual_core):
    service, receipt = _service(manual_core)
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='订单窗口外的固化收款，历史绑定唯一归属该用户', ownership_attestation=True,
        idempotency_key='case-one', authorize=lambda session: lambda: None)
    case_view = service.get(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    assert case_view['reason_detail'] == '订单窗口外的固化收款，历史绑定唯一归属该用户'
    assert case_view['binding_id'] == 'binding'
    assert case_view['txid'] == manual_core[2].value.txid and case_view['log_index'] == 0
    assert case_view['source_address'] and case_view['official_address']
    assert case_view['block_number'] == 102 and case_view['block_time']
    assert case_view['amount'] == '10.000000' and case_view['asset'] == 'USDT'
    assert case_view['network'] and case_view['contract'] and case_view['official_config_version']
    assert case_view['username'] == 'alice'
    blocked = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    assert 'MANUAL_CASE_NOT_APPROVED' in blocked['blockers']
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED',
        reason_detail='负责人复核链证据和历史绑定', confirmed=True, idempotency_key='decision-one',
        authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    result = service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'],
        digest=preview['digest'], expected_version=1, operation_id='manual-case-one', idempotency_key='execute-one',
        authorize=lambda session: lambda: None)
    assert service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'],
        digest=preview['digest'], expected_version=1, operation_id='manual-case-one', idempotency_key='execute-one',
        authorize=lambda session: lambda: None) == result
    with manual_core[1]() as session:
        row = session.get(manual_core[4], receipt['id'])
        assert row.status == 'CREDITED' and row.intent_id is None and row.manual_case_id == case['case_id']
        assert session.scalar(select(WalletLedgerTransaction).where(WalletLedgerTransaction.id == result['ledger_transaction_id']))


def test_manual_case_rejects_user_other_than_unique_historical_binding(manual_core):
    service, receipt = _service(manual_core)
    with pytest.raises(AppError) as error:
        service.create(actor_id='owner', receipt_id=receipt['id'], user_id='wrong-user',
            reason_detail='不得由管理员任意指定用户', ownership_attestation=True, idempotency_key='wrong-user',
            authorize=lambda session: lambda: None)
    assert error.value.code == 'USER_MISMATCH'


def test_case_decision_same_key_replays_and_changed_payload_conflicts(manual_core):
    service, receipt = _service(manual_core)
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice', reason_detail='审批重放', ownership_attestation=True, idempotency_key='case-replay', authorize=lambda session: lambda: None)
    first = service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='同一决定', confirmed=True, idempotency_key='decision-replay', authorize=lambda session: lambda: None)
    assert service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='同一决定', confirmed=True, idempotency_key='decision-replay', authorize=lambda session: lambda: None) == first
    with pytest.raises(AppError) as error:
        service.decide(actor_id='owner', case_id=case['case_id'], decision='REJECTED', reason_detail='不同决定', confirmed=True, idempotency_key='decision-replay', authorize=lambda session: lambda: None)
    assert error.value.code == 'IDEMPOTENCY_CONFLICT'


def test_case_create_replay_returns_before_evidence_provider_refresh(manual_core, monkeypatch):
    service, receipt = _service(manual_core)
    first = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='幂等重放必须不依赖链节点', ownership_attestation=True,
        idempotency_key='case-provider-replay', authorize=lambda session: lambda: None)
    monkeypatch.setattr(service, '_proof', lambda txid: (_ for _ in ()).throw(AssertionError('provider called')))
    assert service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='幂等重放必须不依赖链节点', ownership_attestation=True,
        idempotency_key='case-provider-replay', authorize=lambda session: lambda: None) == first
    with pytest.raises(AppError) as error:
        service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
            reason_detail='changed payload', ownership_attestation=True,
            idempotency_key='case-provider-replay', authorize=lambda session: lambda: None)
    assert error.value.code == 'IDEMPOTENCY_CONFLICT'


@pytest.mark.parametrize('entrypoint', ['context', 'create', 'preview'])
def test_case_entrypoints_keep_budget_lock_before_grant_and_do_not_query_provider_after_denial(manual_core, monkeypatch, entrypoint):
    from app.modules.wallet import manual_deposit_cases
    service, receipt = _service(manual_core)
    case = None
    if entrypoint == 'preview':
        case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
            reason_detail='为预检授权顺序建立补录单', ownership_attestation=True,
            idempotency_key='case-preview-auth', authorize=lambda session: lambda: None)
    order = []
    monkeypatch.setattr(manual_deposit_cases, 'lock_budget', lambda session: order.append('budget'))
    monkeypatch.setattr(service, '_proof', lambda txid: (_ for _ in ()).throw(AssertionError('provider called')))
    def denied(session):
        order.append('authorize')
        raise AppError(code='WALLET_ACCESS_REQUIRED', message='grant missing', status_code=403)
    with pytest.raises(AppError) as error:
        if entrypoint == 'context':
            service.context(actor_id='owner', txid=manual_core[2].value.txid, log_index=0, authorize=denied)
        elif entrypoint == 'create':
            service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
                reason_detail='授权必须先于对象和网络读取', ownership_attestation=True,
                idempotency_key='case-create-auth', authorize=denied)
        else:
            service.preview(actor_id='owner', case_id=case['case_id'], authorize=denied)
    assert error.value.code == 'WALLET_ACCESS_REQUIRED'
    assert order == ['budget', 'authorize']


def test_context_uses_real_chain_and_control_facts_without_case_approval_blocker(manual_core):
    service, receipt = _service(manual_core)
    transfer = manual_core[2].value.transfers[0]
    manual_core[2].value = replace(manual_core[2].value, transfers=(replace(transfer, amount_units=11_000_000),))
    with manual_core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = True
    context = service.context(actor_id='owner', txid=manual_core[2].value.txid, log_index=0,
        authorize=lambda session: lambda: None)
    assert 'EVIDENCE_CONFLICT' in context['blockers']
    assert 'FUNDS_CONTROL_BLOCKED' in context['blockers']
    assert 'MANUAL_CASE_NOT_APPROVED' not in context['blockers']


def test_context_labels_stale_provider_evidence_as_expired(manual_core):
    from datetime import timedelta
    service, receipt = _service(manual_core)
    manual_core[2].value = replace(manual_core[2].value,
        observed_at=manual_core[5] - timedelta(minutes=10))
    context = service.context(actor_id='owner', txid=manual_core[2].value.txid, log_index=0,
        authorize=lambda session: lambda: None)
    assert 'EVIDENCE_EXPIRED' in context['blockers']
    assert 'CLOCK_UNTRUSTED' not in context['blockers']


def test_context_blocks_when_another_receipt_in_the_same_transaction_has_an_anomaly(manual_core):
    from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
    service, receipt = _service(manual_core, extra_transfer=True)
    with manual_core[1].begin() as session:
        other = session.scalar(select(DepositReceipt).where(DepositReceipt.txid == manual_core[2].value.txid,
            DepositReceipt.id != receipt['id']))
        session.add(DepositReceiptAnomaly(id=str(uuid4()), receipt_id=other.id, observed_digest='a' * 64,
            reason_code='TEST_ANOMALY', observed_at=manual_core[5]))
    context = service.context(actor_id='owner', txid=manual_core[2].value.txid, log_index=0,
        authorize=lambda session: lambda: None)
    assert 'EVIDENCE_CONFLICT' in context['blockers']


def test_execute_rejects_reused_operation_id_with_a_new_idempotency_key(manual_core):
    service, receipt = _service(manual_core)
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice', reason_detail='操作编号唯一', ownership_attestation=True, idempotency_key='case-operation', authorize=lambda session: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='批准', confirmed=True, idempotency_key='decision-operation', authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='operation-reused', idempotency_key='execute-operation-one', authorize=lambda session: lambda: None)
    with pytest.raises(AppError) as error:
        service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='operation-reused', idempotency_key='execute-operation-two', authorize=lambda session: lambda: None)
    assert error.value.code == 'IDEMPOTENCY_CONFLICT'


def test_execute_keeps_usdt_precision_when_global_decimal_context_is_low(manual_core):
    service, receipt = _service(manual_core, amount_units=123_456_789_123_456)
    with manual_core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False
        from app.modules.ledger.reserve import RedeemabilityReserve
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('123456790.000000')
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice', reason_detail='大额六位精度补录', ownership_attestation=True, idempotency_key='case-precision', authorize=lambda session: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='批准', confirmed=True, idempotency_key='decision-precision', authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    original_precision = getcontext().prec
    try:
        getcontext().prec = 6
        result = service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='precision-operation', idempotency_key='execute-precision', authorize=lambda session: lambda: None)
    finally:
        getcontext().prec = original_precision
    assert result['amount'] == '123456789.123456'


def test_late_627_second_manual_case_preserves_expired_intent_and_exposes_manual_attribution(manual_core):
    from datetime import datetime, timedelta, timezone
    from app.modules.wallet.finance_queries import WalletFinanceQuery
    from app.modules.wallet.funding_models import DepositIntent
    from app.modules.wallet.models import WalletLedgerEntry
    from app.modules.wallet.service import WalletService
    service, receipt = _service(manual_core)
    def stored(value):
        return value.replace(tzinfo=timezone.utc) if hasattr(value, 'tzinfo') and value.tzinfo is None else value
    receipt_time = datetime.fromtimestamp(manual_core[2].value.timestamp_ms / 1000, timezone.utc)
    late_time = receipt_time + timedelta(seconds=627.682362)
    manual_core[3].clock = lambda: late_time
    old = manual_core[3].create(user_id='alice', expected_amount='10.000000',
        expected_binding_version=1, idempotency_key='expired-627-second-order')
    now = late_time + timedelta(minutes=20, seconds=1)
    manual_core[3].clock = lambda: now
    assert manual_core[3].status(user_id='alice', intent_id=old['id'])['status'] == 'EXPIRED'
    manual_core[2].value = replace(manual_core[2].value, observed_at=now,
        solid_head=replace(manual_core[2].value.solid_head, observed_at=now,
            timestamp_ms=int(now.timestamp() * 1000)))
    from app.modules.ledger.reserve import RedeemabilityReserve
    with manual_core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').observed_at = now
    service.clock = service._guard.clock = lambda: now
    with manual_core[1].begin() as session:
        old_row = session.get(DepositIntent, old['id'])
        before = {name: stored(getattr(old_row, name)) for name in ('id', 'user_id', 'binding_id', 'binding_version',
            'binding_effective_from_block', 'source_address', 'official_address', 'official_config_version',
            'network', 'expected_amount', 'rules_snapshot', 'status', 'created_at', 'expires_at', 'closed_at')}
        assert stored(old_row.created_at) - receipt_time == timedelta(seconds=627.682362)
        assert stored(old_row.expires_at) < now
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='固化收款早于旧过期订单627.682362秒', ownership_attestation=True,
        idempotency_key='case-627-seconds', authorize=lambda session: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='负责人确认不关联旧订单', confirmed=True, idempotency_key='decision-627-seconds', authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    assert 'ORDINARY_INTENT_AVAILABLE' not in preview['blockers']
    result = service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='manual-627-seconds', idempotency_key='execute-627-seconds', authorize=lambda session: lambda: None)
    with manual_core[1]() as session:
        assert {name: stored(getattr(session.get(DepositIntent, old['id']), name)) for name in before} == before
        entries = session.scalars(select(WalletLedgerEntry).where(WalletLedgerEntry.transaction_id == result['ledger_transaction_id'])).all()
        assert len(entries) == 2 and sum(entry.amount for entry in entries) == Decimal('0.000000')
    history, _ = WalletService(manual_core[1], None).history('alice', kind='deposit')
    assert any(item['id'] == receipt['id'] and item['status'] == 'CREDITED' for item in history)
    link = WalletFinanceQuery(manual_core[1]).chain_link(manual_core[2].value.txid, 0)
    assert link['manual_case_id'] == case['case_id'] and link['intent_id'] is None
    assert link['attribution_status'] == 'MANUAL_CASE' and link['ledger_transaction_id'] == result['ledger_transaction_id']


def test_manual_execute_replay_survives_provider_outage_and_never_crosses_repair_kinds(manual_core, monkeypatch):
    from app.modules.wallet.repair_models import RepairCommand, RepairPreview
    from app.modules.wallet.repair_payouts import PayoutReconciliationService
    service, receipt = _service(manual_core)
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice', reason_detail='重放与类型隔离', ownership_attestation=True, idempotency_key='case-kind-isolation', authorize=lambda session: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='批准', confirmed=True, idempotency_key='decision-kind-isolation', authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    result = service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='manual-kind-execute', idempotency_key='manual-kind-key', authorize=lambda session: lambda: None)
    monkeypatch.setattr(service, '_proof', lambda txid: (_ for _ in ()).throw(AssertionError('provider called')))
    assert service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='manual-kind-execute', idempotency_key='manual-kind-key', authorize=lambda session: lambda: None) == result
    with pytest.raises(AppError) as error:
        service._guard.status(actor_id='owner', operation_id='manual-kind-execute', authorize=lambda session: lambda: None)
    assert error.value.code == 'REPAIR_OPERATION_NOT_FOUND'
    with pytest.raises(AppError) as error:
        PayoutReconciliationService(manual_core[1], payouts=None, deposits=service._guard).status(
            actor_id='owner', operation_id='manual-kind-execute', authorize=lambda session: lambda: None)
    assert error.value.code == 'REPAIR_OPERATION_NOT_FOUND'
    with manual_core[1].begin() as session:
        session.add(RepairPreview(id='deposit-preview', actor_id='owner', kind='DEPOSIT', digest='d' * 64, snapshot={}, created_at=manual_core[5], expires_at=manual_core[5]))
        session.add(RepairPreview(id='payout-preview', actor_id='owner', kind='PAYOUT', digest='e' * 64, snapshot={}, created_at=manual_core[5], expires_at=manual_core[5]))
        session.add(RepairCommand(operation_id='deposit-command', actor_id='owner', idempotency_key='cross-kind-key', payload_digest='d' * 64, preview_id='deposit-preview', receipt_id='other-receipt', intent_id=None, result={}, created_at=manual_core[5]))
        session.add(RepairCommand(operation_id='payout-command', actor_id='owner', idempotency_key='payout-kind-key', payload_digest='e' * 64, preview_id='payout-preview', receipt_id=None, intent_id=None, result={}, created_at=manual_core[5]))
    with pytest.raises(AppError) as error:
        service.status(actor_id='owner', operation_id='deposit-command', authorize=lambda session: lambda: None)
    assert error.value.code == 'REPAIR_OPERATION_NOT_FOUND'
    with pytest.raises(AppError) as error:
        service.status(actor_id='owner', operation_id='payout-command', authorize=lambda session: lambda: None)
    assert error.value.code == 'REPAIR_OPERATION_NOT_FOUND'
    with pytest.raises(AppError) as error:
        service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='manual-cross-kind', idempotency_key='cross-kind-key', authorize=lambda session: lambda: None)
    assert error.value.code == 'IDEMPOTENCY_CONFLICT'


@pytest.mark.parametrize('failure', ['audit', 'outbox', 'final_grant'])
def test_execute_late_failure_rolls_back_money_and_command(manual_core, monkeypatch, failure):
    from app.modules.wallet import manual_deposit_cases
    from app.modules.wallet.repair_models import RepairCommand
    from app.modules.ledger.reserve import RedeemabilityReserve
    service, receipt = _service(manual_core)
    case = service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice', reason_detail='回滚验证', ownership_attestation=True, idempotency_key='rollback-case', authorize=lambda session: lambda: None)
    service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED', reason_detail='批准', confirmed=True, idempotency_key='rollback-decision', authorize=lambda session: lambda: None)
    preview = service.preview(actor_id='owner', case_id=case['case_id'], authorize=lambda session: lambda: None)
    if failure == 'audit': monkeypatch.setattr(manual_deposit_cases.AuditWriter, 'record_in_session', lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError('audit failed')))
    if failure == 'outbox': monkeypatch.setattr(manual_deposit_cases.OutboxPublisher, 'enqueue', lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError('outbox failed')))
    calls=[]
    def authorize(session):
        def fresh():
            calls.append(1)
            if failure == 'final_grant' and len(calls) >= 4: raise AppError(code='WALLET_ACCESS_REQUIRED', message='expired', status_code=403)
        return fresh
    with pytest.raises((RuntimeError, AppError)):
        service.execute(actor_id='owner', case_id=case['case_id'], preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1, operation_id='rollback-op', idempotency_key='rollback-execute', authorize=authorize)
    with manual_core[1]() as session:
        row=session.get(manual_core[4], receipt['id'])
        assert row.status == 'REVIEW' and row.pending_obligation and row.ledger_transaction_id is None
        assert session.scalar(select(WalletLedgerTransaction)) is None
        assert session.scalar(select(RepairCommand)) is None
        assert session.get(RedeemabilityReserve, 'global').usdt_liability == 10
