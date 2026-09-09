from dataclasses import replace
from decimal import Decimal
import pytest
from sqlalchemy import select, func
from app.core.errors import AppError
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from test_legacy_handover import handover, common, prepared, notified
from test_manual_reserve_monitor import digest_cut


def fund(handover, key='history', amount='1000.00'):
    return LedgerService(handover[1]).adjust(user_id='synthetic-user', amount=Decimal(amount),
        actor_id='owner', reason_code='LEGACY_CAIBI_ADJUSTMENT', idempotency_key=key)


def test_caibi_history_is_versioned_digest_bound_and_still_requires_full_coverage(handover):
    fund(handover)
    result = notified(handover)
    from app.modules.wallet.handover_models import WalletHandoverPreparation
    with handover[1]() as session:
        history = session.get(WalletHandoverPreparation, result['id']).manifest['financial']
        assert history['history_policy'] == 'CAIBI_HISTORY_V1'
        assert history['ledger_entries'] == 2 and history['ledger_transactions'] == 1
        assert history['caibi_liability'] == '1000.00'
        assert len(history['history_digest']) == 64
    handover[4].value = digest_cut(replace(handover[4].value, balance_units=10_000000, digest=''))
    with pytest.raises(AppError):
        handover[0].confirm(preparation_id=result['id'], manifest_digest=result['manifest_digest'],
            no_unregistered_payments=True, notice_received=True, **common('confirm'))
    from app.modules.ledger.reserve import RedeemabilityReserve
    from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
    with handover[1]() as session:
        assert session.get(RedeemabilityReserve, 'global') is None
        assert session.scalar(select(func.count()).select_from(LedgerOutgoingRestriction)) == 0
        assert session.scalar(select(func.count()).select_from(LedgerEntry)) == 2


def test_added_balanced_history_invalidates_prepared_manifest(handover):
    fund(handover)
    result = prepared(handover)
    fund(handover, key='another', amount='1.00')
    assert handover[0].status(result['id'], actor_id='owner')['status'] == 'INVALID'
    with pytest.raises(AppError, match='HANDOVER_MANIFEST_CONFLICT'):
        handover[0].notify(preparation_id=result['id'],manifest_digest=result['manifest_digest'],**common('notify'))


@pytest.mark.parametrize('fault', ['usdt', 'unknown', 'entry_asset', 'orphan', 'unbalanced', 'actor', 'reason', 'idempotency', 'scope', 'missing_entries', 'reversal'])
def test_caibi_history_rejects_unsupported_or_inconsistent_records(handover, fault):
    tx = fund(handover)
    with handover[1].begin() as session:
        row = session.get(LedgerTransaction, tx.id)
        entry = session.scalar(select(LedgerEntry).where(LedgerEntry.transaction_id == tx.id))
        if fault in ('usdt', 'unknown'): row.asset = 'USDT' if fault == 'usdt' else 'UNKNOWN'
        elif fault == 'entry_asset': entry.asset = 'USDT'
        elif fault == 'orphan': entry.transaction_id = 'orphan'
        elif fault == 'unbalanced': entry.amount += Decimal('0.01')
        elif fault == 'actor': row.actor_id = ' '
        elif fault == 'reason': row.reason_code = ''
        elif fault == 'idempotency': row.idempotency_key = ''
        elif fault == 'scope': row.scope = ''
        elif fault == 'reversal': row.reversal_of_id = 'missing'
        elif fault == 'missing_entries':
            for entry in session.scalars(select(LedgerEntry)):
                session.delete(entry)
    with pytest.raises(AppError):
        prepared(handover)


def test_caibi_history_preserved_on_covered_handover_and_audited(handover):
    fund(handover, amount='10.00')
    result = notified(handover)
    handover[4].value = digest_cut(replace(handover[4].value, balance_units=10_000000, digest=''))
    outcome = handover[0].confirm(preparation_id=result['id'], manifest_digest=result['manifest_digest'],
        no_unregistered_payments=True, notice_received=True, **common('confirm'))
    assert outcome['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'
    from app.modules.audit.models import AuditEvent
    with handover[1]() as session:
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == 'ledger.legacy_stop_adopted'))
        assert audit.after_data['history']['history_policy'] == 'CAIBI_HISTORY_V1'
        assert audit.after_data['history']['caibi_liability'] == '10.00'
        assert session.scalar(select(func.count()).select_from(LedgerEntry)) == 2


def test_canonical_digest_binds_balanced_amounts_and_all_metadata(handover):
    from app.modules.ledger.handover import handover_history_snapshot
    tx = fund(handover, amount='10.00')
    def snapshot():
        with handover[1].begin() as session:
            return handover_history_snapshot(session)
    original = snapshot()
    assert snapshot() == original
    with handover[1].begin() as session:
        for row in session.scalars(select(LedgerEntry)):
            row.amount *= 2
    changed = snapshot()
    assert changed['ledger_entries'] == original['ledger_entries']
    assert changed['history_digest'] != original['history_digest']
    assert changed['caibi_liability'] == '20.00'
    with handover[1].begin() as session:
        session.get(LedgerTransaction, tx.id).reason_code = 'OTHER_VALID_REASON'
    assert snapshot()['history_digest'] != changed['history_digest']


def test_valid_linked_reversal_keeps_exact_history_and_liability(handover):
    from app.modules.ledger.handover import handover_history_snapshot
    tx = fund(handover, amount='10.00')
    LedgerService(handover[1]).reverse(tx.id, reason_code='REVERSE_FIXTURE', actor_id='owner', idempotency_key='reverse')
    with handover[1].begin() as session:
        history = handover_history_snapshot(session)
        assert history['ledger_transactions'] == 2 and history['ledger_entries'] == 4
        assert history['caibi_liability'] == '0.00'


def test_snapshot_uses_existing_hold_escrow_and_issuance_liability_rules(handover):
    from app.modules.ledger.handover import handover_history_snapshot
    LedgerService(handover[1]).post(entries={
        'synthetic-user': Decimal('500.00'), 'HOLD:synthetic-user': Decimal('300.00'),
        'RED_PACKET:synthetic': Decimal('200.00'), 'PLATFORM_FEE': Decimal('30.00'),
        'PLATFORM_CLEARING': Decimal('-1030.00')}, actor_id='owner',
        reason_code='SYNTHETIC_LIABILITY_FIXTURE', idempotency_key='liability')
    with handover[1].begin() as session:
        assert handover_history_snapshot(session)['caibi_liability'] == '1000.00'


@pytest.mark.parametrize('fault', ['double_amount', 'different_account'])
def test_balanced_but_inexact_reversal_is_rejected(handover, fault):
    from app.modules.ledger.handover import handover_history_snapshot
    tx = fund(handover, amount='10.00')
    reversal = LedgerService(handover[1]).reverse(tx.id, reason_code='REVERSE_FIXTURE',
        actor_id='owner', idempotency_key='reverse')
    with handover[1].begin() as session:
        for row in session.scalars(select(LedgerEntry).where(LedgerEntry.transaction_id == reversal.id)):
            if fault == 'double_amount': row.amount *= 2
            elif row.account_id == 'synthetic-user': row.account_id = 'different-user'
    with handover[1].begin() as session:
        with pytest.raises(AppError, match='HANDOVER_LEDGER_HISTORY_INVALID'):
            handover_history_snapshot(session)


def test_reversal_aggregates_duplicate_accounts_and_allows_reverse_of_reversal(handover):
    from uuid import uuid4
    from app.modules.ledger.handover import handover_history_snapshot
    tx = fund(handover, amount='10.00')
    ledger = LedgerService(handover[1])
    reversal = ledger.reverse(tx.id, reason_code='REVERSE_FIXTURE', actor_id='owner', idempotency_key='reverse')
    ledger.reverse(reversal.id, reason_code='REVERSE_AGAIN', actor_id='owner', idempotency_key='reverse-again')
    with handover[1].begin() as session:
        for row in list(session.scalars(select(LedgerEntry).where(LedgerEntry.transaction_id == reversal.id))):
            row.amount /= 2
            session.add(LedgerEntry(id=str(uuid4()), transaction_id=row.transaction_id,
                account_id=row.account_id, asset=row.asset, amount=row.amount, created_at=row.created_at))
    with handover[1].begin() as session:
        snapshot = handover_history_snapshot(session)
        assert snapshot['ledger_transactions'] == 3 and snapshot['ledger_entries'] == 8
        assert snapshot['caibi_liability'] == '10.00'
