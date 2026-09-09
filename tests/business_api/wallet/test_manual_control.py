from datetime import timedelta

import pytest
from sqlalchemy import select, func

from app.core.errors import AppError
from app.modules.ledger.service import LedgerService
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.wallet.models import WalletControl, WalletSafetyState
from test_manual_reserve_monitor import core, coverage, monitor  # noqa: F401


def control(core, monitor):
    assert hasattr(LedgerService, 'restriction_snapshot'), 'ledger restriction provenance is required'
    from app.modules.wallet.manual_control import ManualWalletControl
    monitor[0].external_delivery_configured = True
    return ManualWalletControl(core[1], clock=lambda: monitor[2][0], configuration_id='fixture-v1')


def args(service, key):
    state = service.status()
    return dict(actor_id='owner', reason_code='OWNER_CONTROL', idempotency_key=key,
        expected_epoch=state['epoch'], snapshot_digest=state['snapshot_digest'], authorize=lambda session: lambda: None)


def test_owner_pause_and_resume_publish_fresh_reserve_atomically(core, monitor):
    service = control(core, monitor)
    paused = service.pause(**args(service, 'pause'))
    assert paused['withdrawals_paused'] and paused['outgoing_restricted'] and paused['global_restricted']
    assert paused['restriction_scopes'] == ['manual_tron']
    command = args(service, 'resume')
    result = service.resume(monitor=monitor[0], **command)
    assert result['status'] == 'RUNNING'
    assert not any(result[k] for k in ('withdrawals_paused', 'outgoing_restricted', 'global_restricted'))
    assert result['epoch'] > paused['epoch']
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 1
    monitor[1].read_reserve_cut = lambda: pytest.fail('replay must not read provider')
    assert service.resume(monitor=monitor[0], **command) == result
    with pytest.raises(AppError, match='IDEMPOTENCY'):
        service.resume(monitor=monitor[0], **(command|{'reason_code':'CHANGED_REASON'}))


@pytest.mark.parametrize('fault', ['legacy', 'other_scope', 'user_safety', 'pause_reason', 'safety_reason', 'incident', 'stale', 'deficit'])
def test_resume_preserves_every_unrelated_or_unverified_restriction(core, monitor, fault):
    service = control(core, monitor)
    service.pause(**args(service, 'pause'))
    with core[1].begin() as session:
        if fault == 'legacy':
            from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
            session.delete(session.get(LedgerOutgoingRestriction, 'manual_tron'))
        elif fault == 'other_scope':
            LedgerService(core[1]).restrict_redeemable_outgoing(session=session, actor_id='risk', reason_code='RISK')
        elif fault == 'user_safety':
            session.add(WalletSafetyState(id='some-user', restricted=True, epoch=1, reason='RISK'))
        elif fault == 'pause_reason':
            session.get(WalletControl, 'global').pause_reason = 'OTHER_PAUSE'
        elif fault == 'safety_reason':
            session.get(WalletSafetyState, 'global').reason = 'OTHER_RISK'
    if fault == 'incident':
        monitor[0].incidents.observe([dict(fingerprint='other:incident', code='OTHER', severity='P0', subject_id='global')], complete=False)
    elif fault == 'stale':
        monitor[2][0] += timedelta(seconds=121)
    elif fault == 'deficit':
        from test_manual_reserve_monitor import digest_cut
        monitor[1].value = digest_cut(monitor[1].value, balance_units=1)
    with pytest.raises(AppError):
        service.resume(monitor=monitor[0], **args(service, 'resume'))
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(WalletSafetyState, 'global').restricted
        assert session.get(RedeemabilityReserve, 'global').outgoing_restricted
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 0


def test_resume_rejects_snapshot_aba_and_rolls_back_expired_authorization(core, monitor):
    service = control(core, monitor)
    service.pause(**args(service, 'pause'))
    stale = args(service, 'stale-resume')
    service.resume(monitor=monitor[0], **args(service, 'resume'))
    service.pause(**args(service, 'pause-again'))
    with pytest.raises(AppError, match='SNAPSHOT'):
        service.resume(monitor=monitor[0], **stale)
    def expired(session):
        def check():
            raise AppError(code='TOTP_REQUIRED', message='TOTP_REQUIRED', status_code=403)
        return check
    with pytest.raises(AppError, match='TOTP_REQUIRED'):
        service.resume(monitor=monitor[0], **(args(service, 'expired')|{'authorize':expired}))
    assert service.status()['withdrawals_paused']


def test_manual_monitor_restrictions_record_provenance_without_claiming_legacy_flags(core, monitor):
    service = control(core, monitor)
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = True
        session.get(WalletControl, 'global').pause_reason = 'LEGACY_PAUSE'
        session.get(RedeemabilityReserve, 'global').outgoing_restricted = True
    monitor[1].read_reserve_cut = lambda: (_ for _ in ()).throw(ValueError('offline'))
    monitor[0].run_once()
    status = service.status()
    assert 'legacy_unknown' in status['restriction_scopes'] and 'manual_tron' in status['restriction_scopes']
    with core[1]() as session:
        assert session.get(WalletControl, 'global').pause_reason == 'LEGACY_PAUSE'


def test_healthy_monitor_preserves_owner_pause_without_opening_an_incident(core, monitor):
    service = control(core, monitor)
    paused = service.pause(**args(service, 'pause'))
    assert monitor[0].run_once()['status'] == 'WAITING'
    assert service.status()['unresolved_incidents'] == 0
    assert service.status()['epoch'] == paused['epoch']


def test_activation_requires_configured_alert_delivery(core, monitor):
    service = control(core, monitor)
    service.pause(**args(service, 'pause'))
    monitor[0].external_delivery_configured = False
    with pytest.raises(AppError):
        service.resume(monitor=monitor[0], **args(service, 'resume'))
    assert service.status()['withdrawals_paused']


def test_activation_rolls_back_release_publication_and_command_together(core, monitor, monkeypatch):
    from app.modules.wallet.manual_control_models import WalletManualControlCommand
    service = control(core, monitor)
    before = service.pause(**args(service, 'pause'))
    original = service._record
    def fail_after_publication(session, **kwargs):
        if kwargs['operation'] == 'resume':
            assert not session.get(RedeemabilityReserve, 'global').outgoing_restricted
            assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 1
            raise AppError(code='TEST_COMMIT_REJECTED', message='TEST_COMMIT_REJECTED', status_code=409)
        return original(session, **kwargs)
    monkeypatch.setattr(service, '_record', fail_after_publication)
    with pytest.raises(AppError, match='TEST_COMMIT_REJECTED'):
        service.resume(monitor=monitor[0], **args(service, 'resume'))
    assert service.status() == before
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation)) == 0
        assert session.get(WalletManualControlCommand, 'resume') is None


@pytest.mark.parametrize('fault', ['unknown_payment', 'dead_alert'])
def test_activation_rejects_unknown_legacy_payment_and_failed_alert(core, monitor, fault):
    from decimal import Decimal
    from app.modules.wallet.models import Withdrawal
    from app.core.outbox import OutboxPublisher, OutboxEvent
    service = control(core, monitor)
    service.pause(**args(service, 'pause'))
    with core[1].begin() as session:
        if fault == 'unknown_payment':
            session.add(Withdrawal(id='unknown-order', user_id='alice', client_order_id='legacy', address='fixture',
                amount=Decimal('10'), status='UNKNOWN', created_at=monitor[2][0], updated_at=monitor[2][0]))
        else:
            OutboxPublisher.enqueue(session, topic='wallet.alert', event_type='fixture', aggregate_type='fixture',
                aggregate_id='fixture', payload={}, now=monitor[2][0])
            session.flush()
            session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')).status = 'DEAD'
    with pytest.raises(AppError):
        service.resume(monitor=monitor[0], **args(service, 'resume'))
    assert service.status()['withdrawals_paused']
