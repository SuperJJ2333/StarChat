from sqlalchemy import select, func

from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.models import WalletControl, WalletSafetyState
from app.core.errors import AppError
import pytest
from test_manual_reserve_monitor import core, coverage, monitor  # noqa: F401


def test_review_clears_only_manual_conditions_without_releasing_funds(core, monitor):
    service, source, clock = monitor
    original = source.read_reserve_cut
    source.read_reserve_cut = lambda: (_ for _ in ()).throw(ValueError('unavailable'))
    assert service.run_once()['status'] == 'BLOCKED'
    service.incidents.observe([dict(fingerprint='other:source', code='OTHER_SOURCE',
        severity='P0', subject_id='global')], complete=False)
    source.read_reserve_cut = original
    with core[1]() as session:
        version = session.get(RedeemabilityReserve, 'global').version
    assert service.review_once()['status'] == 'REVIEWED'
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(WalletSafetyState, 'global').restricted
        reserve = session.get(RedeemabilityReserve, 'global')
        assert reserve.outgoing_restricted and reserve.version == version
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 0
        rows = {r.fingerprint:r for r in session.scalars(select(WalletIncident))}
        assert rows['other:source'].condition_active
        row = rows['manual-reserve:MANUAL_SOURCE_UNAVAILABLE']
        assert not row.condition_active and row.status == 'OPEN' and row.clearance_digest
        clearance = row.clearance_digest
    assert service.review_once()['complete']
    with core[1]() as session:
        row = session.scalar(select(WalletIncident).where(WalletIncident.fingerprint == 'manual-reserve:MANUAL_SOURCE_UNAVAILABLE'))
        assert row.clearance_digest == clearance


def test_failed_manual_review_does_not_clear_existing_condition(core, monitor):
    service, source, clock = monitor
    source.read_reserve_cut = lambda: (_ for _ in ()).throw(ValueError('unavailable'))
    assert service.run_once()['status'] == 'BLOCKED'
    assert not service.review_once()['complete']
    with core[1]() as session:
        row = session.scalar(select(WalletIncident).where(WalletIncident.fingerprint == 'manual-reserve:MANUAL_SOURCE_UNAVAILABLE'))
        assert row.condition_active and row.clearance_digest is None


def test_owner_manual_resolution_is_scoped_and_keeps_pause(core, monitor):
    service = monitor[0]
    row = service.incidents.observe([dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNAVAILABLE',
        code='MANUAL_SOURCE_UNAVAILABLE', severity='P0', subject_id='global')], complete=False)[0]
    service.incidents.ack(row['id'], 'owner', 'INVESTIGATING', 'ack-owner', row['version'])
    service.review_once()
    cleared = service.incidents.get(row['id'])
    result = service.incidents.resolve_manual(row['id'], 'owner', 'OWNER_REVIEWED', 'resolve-owner',
        cleared['version'], cleared['clearance_digest'])
    assert result['status'] == 'RESOLVED' and result['resolved_by'] == 'owner'
    assert service.incidents.replay_manual_resolve(row['id'], 'owner', 'OWNER_REVIEWED', 'resolve-owner',
        cleared['version'], cleared['clearance_digest']) == result
    other = service.incidents.observe([dict(fingerprint='other:SOURCE', code='SOURCE',
        severity='P0', subject_id='global')], complete=False)[0]
    service.incidents.ack(other['id'], 'owner', 'INVESTIGATING', 'other-ack', other['version'])
    service.incidents.observe([])
    cleared = service.incidents.get(other['id'])
    with pytest.raises(AppError, match='WALLET_INCIDENT_MANUAL_SCOPE_REQUIRED'):
        service.incidents.resolve_manual(other['id'], 'owner', 'OWNER_REVIEWED', 'other-resolve',
            cleared['version'], cleared['clearance_digest'])
