from datetime import datetime, timedelta, timezone
from importlib.util import find_spec
import hashlib
import json
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, select, func
from sqlalchemy.pool import StaticPool
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxConsumer
from app.modules.audit.writer import AuditWriter
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.models import WalletControl, WalletSafetyState
from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
from app.modules.wallet.funding import OfficialFundingConfig
from app.modules.wallet.funding_scan_models import WalletFundingScanState
from app.integrations.tron.funding_source import ReserveCut
from test_manual_reserve_monitor import digest_cut


@pytest.fixture
def handover(tmp_path):
    assert find_spec('app.modules.wallet.handover') is not None, 'exact legacy handover application service required'
    from app.modules.wallet.handover import LegacyWalletHandover
    from app.core.outbox_handover import OutboxHandover
    from coincurve import PrivateKey
    from app.integrations.tron.message_signature import address_from_public_key
    engine = create_engine('sqlite://', connect_args={'check_same_thread':False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = [datetime.now(timezone.utc)]
    clock = lambda: now[0]
    baseline = now[0]-timedelta(minutes=1)
    official = OfficialFundingConfig(address_from_public_key(PrivateKey().public_key.format(compressed=False)), 'test-v1')
    identity = hashlib.sha256(('tron-mainnet-usdt:'+official.address).encode()).hexdigest()
    milliseconds = int(now[0].timestamp()*1000)
    source = SimpleNamespace(source_identity=identity)
    source.value = digest_cut(ReserveCut(identity, 1, 0, milliseconds, 101, 0, milliseconds, milliseconds+120000, True, ''))
    source.read_reserve_cut = lambda: source.value
    monitor = ManualReserveMonitor(factory, source=source, official_config=official,
        activation_baseline_time=baseline, activation_baseline_height=100, clock=clock, external_delivery_configured=True)
    with factory.begin() as session:
        session.add(WalletControl(id='global', withdrawals_paused=True, pause_reason='WALLET_MONITOR_SIGNAL'))
        session.add(WalletSafetyState(id='global', restricted=True, epoch=1, reason='WALLET_MONITOR_SIGNAL'))
        session.add(WalletFundingScanState(id='global', source_identity=identity, cursor_rowid=0,
            source_max_rowid=0, checkpoint_ms=milliseconds, updated_at=now[0]))
        AuditWriter(factory, now_factory=lambda: now[0]-timedelta(seconds=10)).record_in_session(session,
            actor_id='wallet-monitor', subject_type='wallet', subject_id='global', action='wallet.paused',
            result='SUCCESS', reason_code='RECONCILIATION_MISMATCH', trace_id='fixture')
    old = WalletIncidentService(factory, now_factory=lambda: now[0]-timedelta(seconds=9))
    old.observe([dict(fingerprint=code+':global', code=code, subject_id='global', severity='P0')
        for code in ('MONITOR_UNAVAILABLE','WALLET_PAUSED','ALERT_DELIVERY_UNHEALTHY')], actor_id='wallet-monitor', complete=False)
    with factory.begin() as session:
        for row in session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')):
            row.status, row.attempt_count = 'DEAD', 3
    record = dict(policy='LEGACY_CUSTODY_TO_MANUAL_V1', old_mode='custody_unavailable', new_mode='manual_tron',
        old_api_image='sha256:'+'a'*64, old_worker_image='sha256:'+'b'*64,
        old_source_sha256='c'*64, old_config_sha256='d'*64, new_worker_image='sha256:'+'e'*64,
        new_source_sha256='f'*64, manual_source_identity=identity, manual_config_version='test-v1',
        activation_baseline_at=baseline.isoformat(), activation_baseline_height=100,
        old_monitor_retired_at=(now[0]-timedelta(seconds=1)).isoformat(), verified_at=now[0].isoformat())
    file = tmp_path/'deployment.json'
    file.write_text(json.dumps(record), encoding='utf-8')
    file.chmod(0o600)
    service = LegacyWalletHandover(factory, monitor=monitor, deployment_record_path=str(file),
        clock=clock, preparation_mode=lambda: True, funds_enabled=lambda: False)
    yield service, factory, OutboxHandover(factory, clock=clock), now, source, file
    engine.dispose()


def common(key):
    return dict(actor_id='owner', reason_code='OWNER_HANDOVER', idempotency_key=key, authorize=lambda session: lambda: None)


def prepared(handover):
    return handover[0].prepare(**common('prepare'))


def notified(handover):
    result = prepared(handover)
    handover[0].notify(preparation_id=result['id'], manifest_digest=result['manifest_digest'], **common('notify'))
    events = OutboxConsumer(handover[1], wallet_handover_preparation_mode=True).claim_batch(
        worker_id='worker', limit=1000, topics=['wallet.alert'])
    assert len(events) == 1
    handover[2].record_smtp_delivery(events[0])
    return result


def test_handover_requires_real_notice_receipt_and_keeps_funds_paused(handover):
    result = prepared(handover)
    arguments = dict(preparation_id=result['id'], manifest_digest=result['manifest_digest'],
        no_unregistered_payments=True, notice_received=True, **common('confirm'))
    with pytest.raises(AppError, match='NOTICE_NOT_DELIVERED'):
        handover[0].confirm(**arguments)
    notified(handover)
    outcome = handover[0].confirm(**arguments)
    assert outcome['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'
    assert outcome['disposition_kind'] == 'LEGACY_MONITOR_SUPERSEDED'
    from app.modules.ledger.reserve import RedeemabilityReserve
    from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
    with handover[1]() as session:
        assert session.get(RedeemabilityReserve, 'global') is None
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(WalletSafetyState, 'global').restricted
        assert session.get(WalletSafetyState, 'global').epoch == 2
        assert session.get(LedgerOutgoingRestriction, 'manual_tron').active
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.status == 'DEAD')) == 3
    handover[4].read_reserve_cut = lambda: pytest.fail('handover replay must not rescan')
    assert handover[0].confirm(**arguments) == outcome


def test_retired_monitor_cannot_write_again_before_prepare(handover):
    from app.modules.wallet.incident_models import WalletIncident
    service, factory, _, clock, _, _ = handover
    with factory() as session:
        before = [(row.id, row.version) for row in session.scalars(select(WalletIncident).order_by(WalletIncident.id))]
    WalletIncidentService(factory, now_factory=lambda: clock[0]).observe([
        dict(fingerprint=code+':global', code=code, subject_id='global', severity='P0')
        for code in ('MONITOR_UNAVAILABLE', 'WALLET_PAUSED', 'ALERT_DELIVERY_UNHEALTHY')],
        actor_id='wallet-monitor', complete=False)
    with factory() as session:
        assert [(row.id, row.version) for row in session.scalars(select(WalletIncident).order_by(WalletIncident.id))] == before
    with pytest.raises(AppError, match='HANDOVER_INCIDENT_PROVENANCE_CONFLICT'):
        service.prepare(**common('retired-monitor-restarted'))


@pytest.mark.parametrize('fault', ['another_incident', 'generation', 'risk', 'pause_audit', 'ledger', 'lease', 'attestation'])
def test_prepare_rejects_unproven_or_changed_legacy_state(handover, fault):
    from app.modules.wallet.incident_models import WalletIncident
    from app.modules.ledger.reserve import RedeemabilityReserve
    if fault == 'another_incident':
        WalletIncidentService(handover[1]).observe([dict(fingerprint='other:global',code='OTHER',subject_id='global',severity='P0')], complete=False)
    elif fault == 'attestation':
        handover[5].write_text('{}', encoding='utf-8')
    else:
        with handover[1].begin() as session:
            if fault == 'generation':
                session.scalar(select(WalletIncident)).generation = 2
            elif fault == 'risk':
                session.add(WalletSafetyState(id='some-user', restricted=True, epoch=1, reason='RISK'))
            elif fault == 'pause_audit':
                AuditWriter(handover[1]).record_in_session(session, actor_id='another-actor', subject_type='wallet',
                    subject_id='global', action='wallet.paused', result='SUCCESS', reason_code='RISK', trace_id='other')
            elif fault == 'ledger':
                session.add(RedeemabilityReserve(id='global', eligible_usdt=0, usdt_liability=0, version=1,
                    pending_payouts=0, outgoing_restricted=True, observed_at=handover[3][0]))
            elif fault == 'lease':
                event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
                event.status, event.locked_by, event.locked_at = 'PROCESSING', 'worker', handover[3][0]
    with pytest.raises(AppError):
        prepared(handover)


def test_expired_identical_preparation_reuses_notice_without_resending(handover):
    first = notified(handover)
    handover[3][0] += timedelta(minutes=16)
    assert handover[0].status(first['id'], actor_id='owner')['status'] == 'EXPIRED'
    second = handover[0].prepare(**common('prepare-again'))
    assert second['id'] != first['id'] and second['manifest_digest'] == first['manifest_digest']
    notice = handover[0].notify(preparation_id=second['id'], manifest_digest=second['manifest_digest'], **common('notify-again'))
    assert notice['status'] == 'NOTICE_DELIVERED'


def test_late_confirmation_failure_rolls_back_ownership_and_incident_dispositions(handover, monkeypatch):
    from app.modules.wallet.handover_models import WalletIncidentHandoverDisposition, WalletHandoverCommand
    from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
    result = notified(handover)
    original = handover[0]._command
    def fail(session, row, **kwargs):
        original(session,row,**kwargs)
        raise AppError(code='TOTP_REQUIRED',message='TOTP_REQUIRED',status_code=403)
    monkeypatch.setattr(handover[0],'_command',fail)
    with pytest.raises(AppError,match='TOTP_REQUIRED'):
        handover[0].confirm(preparation_id=result['id'],manifest_digest=result['manifest_digest'],
            no_unregistered_payments=True,notice_received=True,**common('confirm'))
    with handover[1]() as session:
        assert session.get(LedgerOutgoingRestriction,'manual_tron') is None
        assert session.get(WalletSafetyState,'global').epoch == 1
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 0
        assert session.get(WalletHandoverCommand,'confirm') is None


def test_changed_preparation_reports_invalid_and_deterministic_manifest_conflict(handover):
    result=prepared(handover)
    with handover[1].begin() as session:
        session.get(WalletSafetyState,'global').epoch += 1
    assert handover[0].status(result['id'],actor_id='owner')['status'] == 'INVALID'
    with pytest.raises(AppError,match='HANDOVER_MANIFEST_CONFLICT'):
        handover[0].notify(preparation_id=result['id'],manifest_digest=result['manifest_digest'],**common('notify'))


def test_real_sender_failure_never_records_summary_delivery(handover):
    from tasks.wallet_alert_email import WalletAlertEmailHandler
    result=prepared(handover)
    handover[0].notify(preparation_id=result['id'],manifest_digest=result['manifest_digest'],**common('notify'))
    event=OutboxConsumer(handover[1],wallet_handover_preparation_mode=True).claim_batch(worker_id='worker',limit=100,topics=['wallet.alert'])[0]
    class Sender:
        def send_wallet_handover(self, **kwargs):
            raise RuntimeError('private smtp details')
    with pytest.raises(RuntimeError,match='WALLET_ALERT_EMAIL_FAILED'):
        WalletAlertEmailHandler(handover[1],email_sender=Sender(),recipient='owner@example.test')(event)
    assert handover[0].status(result['id'],actor_id='owner')['status'] == 'NOTICE_PENDING'
    Sender.send_wallet_handover=lambda self,**kwargs:None
    WalletAlertEmailHandler(handover[1],email_sender=Sender(),recipient='owner@example.test')(event)
    assert handover[0].status(result['id'],actor_id='owner')['status'] == 'NOTICE_DELIVERED'


@pytest.mark.parametrize('failure', ['outage', 'unhealthy'])
def test_failed_handover_proof_preserves_legacy_state_and_can_retry(handover, failure):
    from dataclasses import replace
    from app.modules.wallet.manual_control_models import WalletManualControlState
    from app.modules.wallet.incident_models import WalletIncident
    from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
    result = notified(handover)
    arguments = dict(preparation_id=result['id'], manifest_digest=result['manifest_digest'],
        no_unregistered_payments=True, notice_received=True, **common('confirm'))
    source = handover[4]
    good = source.value
    if failure == 'outage':
        def unavailable():
            raise RuntimeError('provider unavailable')
        source.read_reserve_cut = unavailable
    else:
        source.value = digest_cut(replace(good, healthy=False, digest=''))
    with pytest.raises(AppError):
        handover[0].confirm(**arguments)
    with handover[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(WalletSafetyState, 'global').epoch == 1
        assert session.get(WalletManualControlState, 'global') is None
        assert session.scalar(select(func.count()).select_from(LedgerOutgoingRestriction)) == 0
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 3
    source.value = good
    source.read_reserve_cut = lambda: source.value
    assert handover[0].confirm(**arguments)['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'


def test_preparation_heartbeat_never_publishes_or_changes_legacy_manifest(handover):
    from app.modules.wallet.monitoring import WalletMonitorHeartbeat
    from app.modules.ledger.reserve import RedeemabilityReserve
    result = prepared(handover)
    assert handover[0].monitor.preparation_once()['status'] == 'PREPARING_HANDOVER'
    assert handover[0].status(result['id'], actor_id='owner')['status'] == 'PREPARED'
    with handover[1]() as session:
        row = session.get(WalletMonitorHeartbeat, 'global')
        assert row.last_success_at is None
        assert row.last_error_code == 'PREPARING_HANDOVER'
        assert row.external_delivery_configured is True
        assert session.get(RedeemabilityReserve, 'global') is None
