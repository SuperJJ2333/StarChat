"""Published void financial invariants, with explicit legacy UNKNOWN fixtures."""
from datetime import timedelta, timezone
from decimal import Decimal
import pytest
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.identity.models import UserRole
from app.modules.identity.rbac import RoleCode
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from test_manual_payouts import core, claim


def legacy_unknown(core, order):
    # Independent legacy state; an empty locator never creates UNKNOWN now.
    with core[1].begin() as session:
        session.get(ManualPayoutOrder, order['id']).status='UNKNOWN'


def test_unbroadcast_void_releases_claimed_unknown_once(core):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    order = claim(core)
    assert core[0].reconcile(order_id=order['id'])['status'] == 'CLAIMED'
    legacy_unknown(core, order)
    unknown = core[0].status(user_id='alice', order_id=order['id'])
    assert unknown['status'] == 'UNKNOWN'
    assert unknown['version'] == core[0].status(user_id='alice', order_id=order['id'])['version']
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        version, claimed_by, claimed_at = row.version, row.claimed_by, row.claimed_at
    proof = dict(source_id='official-observer', observation_id='obs-1', checkpoint=int(core[2][0].timestamp()*1000),
        observed_at=core[2][0], scanned_from=int(claimed_at.timestamp()*1000),
        reconciliation_status='SOURCE_MATCHED', matching_outflows=0,
        suspicious_outflows=0, fresh_until_ms=int((core[2][0]+timedelta(seconds=60)).timestamp()*1000),
        max_rowid=100)
    args = dict(admin_id='owner', order_id=order['id'], expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED', never_signed=True, never_broadcast=True,
        idempotency_key='void-1', evidence=proof, authorize=lambda session: lambda: None,
        verify_evidence=lambda session, evidence: True)
    result = core[0].void_unbroadcast(**args)
    assert result['status'] == 'VOIDED'
    assert core[0].void_unbroadcast(**args) == result
    with pytest.raises(AppError, match='WALLET_IDEMPOTENCY_CONFLICT'):
        core[0].void_unbroadcast(**(args | {'reason_code': 'DIFFERENT_REASON'}))
    assert core[5].balance('HOLD:alice') == Decimal('0')
    assert core[5].balance('alice') == Decimal('1000')
    with core[1]() as session:
        from app.modules.audit.models import AuditEvent
        from app.core.outbox import OutboxEvent
        row = session.get(ManualPayoutOrder, order['id'])
        assert row.claimed_by == claimed_by and row.claimed_at == claimed_at
        assert session.get(RedeemabilityReserve, 'global').pending_payouts == 0
        assert session.scalar(select(AuditEvent.id).where(AuditEvent.subject_id == order['id'],
            AuditEvent.action == 'wallet.manual_payout_void_unbroadcast')) is not None
        assert session.scalar(select(OutboxEvent.id).where(OutboxEvent.aggregate_id == order['id'],
            OutboxEvent.event_type == 'wallet.manual_payout_void_unbroadcast')) is not None
        row.updated_at = core[2][0] + timedelta(seconds=1)
        with pytest.raises(ValueError, match='terminal'):
            session.flush()

@pytest.mark.parametrize('change,code', [
    ({'never_signed': False}, 'WALLET_PAYOUT_VOID_DECLARATION_REQUIRED'),
    ({'never_broadcast': False}, 'WALLET_PAYOUT_VOID_DECLARATION_REQUIRED'),
    ({'expected_version': 999}, 'WALLET_PAYOUT_VERSION_CONFLICT'),
    ({'admin_id': 'bob'}, 'WALLET_PAYOUT_OWNER_REQUIRED'),
    ({'evidence': 'stale'}, 'WALLET_PAYOUT_VOID_EVIDENCE_INVALID'),
    ({'verify_evidence': lambda session, evidence: False}, 'WALLET_PAYOUT_VOID_EVIDENCE_CHANGED'),
])
def test_unbroadcast_void_rejects_invalid_intent_atomically(core, change, code):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    if change.get('admin_id') == 'bob':
        with core[1].begin() as session:
            session.add(UserRole(id='bob-admin', user_id='bob', role_code=RoleCode.SUPER_ADMIN,
                assigned_by='owner', assigned_at=core[2][0]))
    order = claim(core)
    core[0].reconcile(order_id=order['id'])
    legacy_unknown(core, order)
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        version, claim_ms = row.version, int(row.claimed_at.replace(tzinfo=timezone.utc).timestamp()*1000)
    proof = dict(source_id='official-observer', observation_id='obs-1', checkpoint=int(core[2][0].timestamp()*1000),
        observed_at=core[2][0], scanned_from=claim_ms, reconciliation_status='SOURCE_MATCHED',
        matching_outflows=0, suspicious_outflows=0,
        fresh_until_ms=int((core[2][0]+timedelta(seconds=60)).timestamp()*1000), max_rowid=100)
    args = dict(admin_id='owner', order_id=order['id'], expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED', never_signed=True, never_broadcast=True,
        idempotency_key='void-reject', evidence=proof, authorize=lambda session: lambda: None,
        verify_evidence=lambda session, evidence: True)
    with pytest.raises(AppError) as exc:
        core[0].void_unbroadcast(**(args | change))
    assert exc.value.code == code
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, 'global').pending_payouts == 1

@pytest.mark.parametrize('artifact', ['locator', 'candidate_row', 'payout_event'])
def test_unbroadcast_void_rejects_recorded_candidate(core, artifact):
    from app.modules.wallet.manual_payout_models import (
        ManualPayoutOrder, ManualPayoutCandidate, ManualPayoutEvent,
    )
    order = claim(core)
    if artifact == 'locator':
        core[0].submit_txid(admin_id='owner', order_id=order['id'], txid='a'*64, idempotency_key='tx-void')
    else:
        core[0].reconcile(order_id=order['id'])
        legacy_unknown(core, order)
        with core[1].begin() as session:
            if artifact == 'candidate_row':
                session.add(ManualPayoutCandidate(id='candidate-only', order_id=order['id'], txid='a'*64,
                    actor_id='owner', reason_code='INITIAL_LOCATOR', created_at=core[2][0]))
            else:
                session.add(ManualPayoutEvent(id='event-only', order_id=order['id'], network='TRON',
                    contract='test-contract', txid='a'*64, log_index=0,
                    evidence={'test': True}, created_at=core[2][0]))
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        version, claim_ms = row.version, int(row.claimed_at.replace(tzinfo=timezone.utc).timestamp()*1000)
    proof = dict(source_id='official-observer', observation_id='obs-1', checkpoint=int(core[2][0].timestamp()*1000),
        observed_at=core[2][0], scanned_from=claim_ms, reconciliation_status='SOURCE_MATCHED',
        matching_outflows=0, suspicious_outflows=0,
        fresh_until_ms=int((core[2][0]+timedelta(seconds=60)).timestamp()*1000), max_rowid=100)
    with pytest.raises(AppError, match='WALLET_PAYOUT_VOID_UNAVAILABLE'):
        core[0].void_unbroadcast(admin_id='owner', order_id=order['id'], expected_version=version,
            reason_code='NEVER_BROADCAST_CONFIRMED', never_signed=True, never_broadcast=True,
            idempotency_key='void-with-candidate', evidence=proof,
            authorize=lambda session: lambda: None, verify_evidence=lambda session, evidence: True)
    assert core[5].balance('HOLD:alice') == Decimal('10')
