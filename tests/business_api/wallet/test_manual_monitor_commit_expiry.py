from datetime import timedelta

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.wallet.incident_models import WalletIncident
from test_manual_reserve_monitor import core, coverage, monitor  # noqa: F401


def test_coverage_lock_delay_cannot_publish_expired_cut(core, monitor, monkeypatch):
    service, _, clock = monitor
    original = service._coverage
    def delayed(session, cut):
        result = original(session, cut)
        clock[0] += timedelta(seconds=121)
        return result
    monkeypatch.setattr(service, '_coverage', delayed)
    assert not service.run_once()['complete']
    with core[1]() as session:
        assert session.scalar(select(ManualReserveEvaluation)) is None


def test_review_callback_expiry_rolls_back_clearance(core, monitor):
    service, _, clock = monitor
    service.incidents.observe([dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNHEALTHY',
        code='MANUAL_SOURCE_UNHEALTHY', severity='P0', subject_id='global')], complete=False)
    def delayed(session):
        service.incidents.observe_in_session(session, [], actor_id='test',
            complete=True, clear_prefix='manual-reserve:')
        clock[0] += timedelta(seconds=121)
        return {'verified': True}
    with pytest.raises(AppError) as caught:
        service.review_once(on_review=delayed)
    assert caught.value.code == 'WALLET_MONITOR_EVIDENCE_EXPIRED'
    with core[1]() as session:
        incident = session.scalar(select(WalletIncident))
        assert incident.cleared_at is None
        assert incident.condition_active
