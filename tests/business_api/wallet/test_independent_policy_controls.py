"""Policy warnings remain visible without becoming an emergency stop."""
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.models import WalletControl
from test_manual_control import args, control
from test_manual_reserve_monitor import core, coverage, digest_cut, monitor  # noqa: F401
from test_legacy_handover import common, handover, notified  # noqa: F401


def policy_control(core, monitor):
    service = control(core, monitor)
    service.reserve_policy = monitor[0].reserve_policy = 'manual_liquidity'
    monitor[1].value = digest_cut(monitor[1].value, balance_units=1_000000)
    return service


def test_deficit_advisory_survives_reviewed_resume_and_remains_in_evidence(core, monitor):
    service = policy_control(core, monitor)
    service.pause(**args(service, 'pause'))
    assert monitor[0].review_once()['complete']
    result = service.resume(monitor=monitor[0], **args(service, 'resume'))
    assert result['status'] == 'RUNNING'
    assert result['unresolved_incidents'] == 0
    with core[1]() as session:
        advisory = session.scalar(select(WalletIncident))
        assert advisory.code == 'MANUAL_BACKING_DEFICIT'
        assert advisory.condition_active and advisory.status == 'OPEN'
        evaluation = session.scalar(select(ManualReserveEvaluation))
        assert evaluation.evidence['reserve_policy'] == 'manual_liquidity'
        assert Decimal(evaluation.evidence['backing_deficit']) > 0
        assert session.get(RedeemabilityReserve, 'global').eligible_usdt == Decimal('1')
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(
            OutboxEvent.topic == 'wallet.alert')) >= 1
        before_digest = service._snapshot(session)['snapshot_digest']
    monitor[0].incidents.ack(advisory.id, 'owner', 'OWNER_ACK', 'ack', advisory.version)
    assert service.status()['status'] == 'RUNNING'
    assert service.status()['snapshot_digest'] != before_digest


@pytest.mark.parametrize('mutation', ['fingerprint', 'code', 'severity', 'subject_id', 'policy'])
def test_only_exact_manual_liquidity_advisory_is_nonblocking(core, monitor, mutation):
    service = policy_control(core, monitor)
    assert monitor[0].run_once()['complete']
    with core[1].begin() as session:
        advisory = session.scalar(select(WalletIncident))
        if mutation == 'policy':
            service.reserve_policy = 'full_backing'
        else:
            setattr(advisory, mutation, dict(fingerprint='other:warning', code='OTHER_WARNING',
                severity='P0', subject_id='another-user')[mutation])
    assert service.status()['unresolved_incidents'] == 1
    assert service.status()['status'] == 'PAUSED'
    with core[1]() as session:
        with pytest.raises(AppError, match='UNRESOLVED_INCIDENTS'):
            service.incidents.require_resolved_in_session(session,
                allow_backing_advisory=service.reserve_policy == 'manual_liquidity')


def test_other_p1_still_blocks_resume_with_approved_deficit(core, monitor):
    service = policy_control(core, monitor)
    service.pause(**args(service, 'pause'))
    assert monitor[0].review_once()['complete']
    monitor[0].incidents.observe([dict(fingerprint='other:warning', code='OTHER_WARNING',
        severity='P1', subject_id='global')], complete=False)
    with pytest.raises(AppError, match='UNRESOLVED_INCIDENTS'):
        service.resume(monitor=monitor[0], **args(service, 'resume'))
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 0


def test_legacy_handover_accepts_real_deficit_without_creating_fourth_incident(handover):
    service, factory, _, _, source, _ = handover
    service.monitor.reserve_policy = 'manual_liquidity'
    ledger = LedgerService(factory)
    ledger.post(entries={'alice': Decimal('25'), 'PLATFORM_CLEARING': Decimal('-25')},
        actor_id='fixture', reason_code='LEGACY_CAIBI', idempotency_key='legacy-caibi')
    prepared = notified(handover)
    result = service.confirm(preparation_id=prepared['id'], manifest_digest=prepared['manifest_digest'],
        no_unregistered_payments=True, notice_received=True, **common('confirm'))
    assert result['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'
    assert source.value.balance_units == 0
    assert ledger.balance('alice') == Decimal('25')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 3
        assert session.get(RedeemabilityReserve, 'global') is None
    assert service.monitor.review_once()['complete']
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 4
        advisory = session.scalar(select(WalletIncident).where(WalletIncident.code == 'MANUAL_BACKING_DEFICIT'))
        assert advisory.condition_active and advisory.severity == 'P1'
        assert session.get(RedeemabilityReserve, 'global') is None
