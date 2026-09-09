from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.modules.wallet.incidents import WalletIncidentService


class Wallet:
    paused = False
    matched = True
    broken = False

    def withdrawals_paused(self):
        return self.paused

    def pause_on_reconciliation_mismatch(self, reason, **kwargs):
        self.paused = True

    def reconcile_incremental(self, **kwargs):
        if self.broken:
            raise RuntimeError('sensitive provider details must never escape')
        return SimpleNamespace(matched=self.matched)

    def detect_orphan_external_orders(self, **kwargs):
        return {'status': 'MATCHED', 'orphan_order_ids': []}


@pytest.fixture
def setup():
    from app.modules.wallet.monitoring import WalletMonitoringService
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    wallet = Wallet()
    monitor = WalletMonitoringService(factory, wallet_service=wallet, now_factory=lambda: clock[0])
    yield factory, clock, wallet, monitor
    engine.dispose()


def test_monitor_success_heartbeat_and_outage_staleness(setup):
    factory, clock, wallet, monitor = setup
    assert monitor.status()['stale'] is True
    assert monitor.run_once()['complete'] is True
    assert monitor.status()['stale'] is False
    clock[0] += timedelta(seconds=121)
    assert monitor.status()['stale'] is True


def test_partial_scan_preserves_incidents_and_never_claims_success(setup):
    factory, clock, wallet, monitor = setup
    wallet.matched = False
    monitor.run_once()
    incidents = WalletIncidentService(factory)
    deficit = next(x for x in incidents.list_incidents()['items'] if x['code'] == 'RESERVE_DEFICIT')
    assert wallet.paused
    previous = monitor.status()['last_success_at']
    wallet.broken = True
    clock[0] += timedelta(seconds=130)
    result = monitor.run_once()
    assert result['complete'] is False
    assert monitor.status()['last_success_at'] == previous
    assert monitor.status()['stale'] is True
    assert incidents.get(deficit['id'])['condition_active'] is True
    assert 'sensitive' not in str(result) + str(monitor.status())


def test_no_provider_is_visible_failure_not_simulated_health(setup):
    from app.modules.wallet.monitoring import WalletMonitoringService
    factory, clock, wallet, monitor = setup
    unavailable = WalletMonitoringService(factory, wallet_service=None, now_factory=lambda: clock[0])
    assert unavailable.run_once()['complete'] is False
    assert unavailable.status()['last_success_at'] is None


def test_retrying_failed_alert_remains_visible(setup):
    from app.core.outbox import OutboxEvent, OutboxPublisher
    factory, clock, wallet, monitor = setup
    with factory.begin() as session:
        id = OutboxPublisher.enqueue(session, topic='wallet.alert', event_type='fixture',
            aggregate_type='wallet_incident', aggregate_id='fixture', payload={}, now=clock[0]-timedelta(minutes=6))
    with factory.begin() as session:
        session.get(OutboxEvent, id).status = 'FAILED'
    assert 'ALERT_DELIVERY_UNHEALTHY' in monitor.run_once()['codes']


def test_corrupt_journal_is_critical_even_when_scan_cannot_complete(setup, monkeypatch):
    from app.modules.wallet.reporting import ReportDataError, WalletReportService
    factory, clock, wallet, monitor = setup
    def corrupt(self, day):
        raise ReportDataError('unsupported stored asset')
    monkeypatch.setattr(WalletReportService, 'daily', corrupt)
    result = monitor.run_once()
    assert result['complete'] is False
    row = next(x for x in WalletIncidentService(factory).list_incidents()['items'] if x['code'] == 'LEDGER_INTEGRITY')
    assert row['severity'] == 'P0' and wallet.paused


def test_uncertain_withdrawal_detected_without_exposing_address(setup):
    from app.modules.wallet.models import Withdrawal
    from decimal import Decimal
    factory, clock, wallet, monitor = setup
    with factory.begin() as session:
        session.add(Withdrawal(id='fixture-uncertain', user_id='fixture', client_order_id='fixture-order',
            address='synthetic-not-a-real-address', amount=Decimal('1'), status='UNKNOWN',
            created_at=clock[0]-timedelta(minutes=10), updated_at=clock[0]-timedelta(minutes=6)))
    assert 'WITHDRAWAL_UNCERTAIN' in monitor.run_once()['codes']
    incident = next(x for x in WalletIncidentService(factory).list_incidents()['items'] if x['code'] == 'WITHDRAWAL_UNCERTAIN')
    assert incident['subject_id'] == 'fixture-uncertain'
    assert 'address' not in str(incident)


def test_external_delivery_defaults_false_and_legacy_scan_resets_it(setup):
    from app.modules.wallet.monitoring import WalletMonitorHeartbeat
    factory, clock, wallet, monitor = setup
    assert monitor.status()['external_delivery_configured'] is False
    with factory.begin() as session:
        session.add(WalletMonitorHeartbeat(id='global', last_attempt_at=clock[0],
            external_delivery_configured=True))
    assert monitor.status()['external_delivery_configured'] is True
    monitor.run_once()
    assert monitor.status()['external_delivery_configured'] is False


def test_monitor_api_schema_accepts_configured_true(setup):
    from app.api.wallet_operations import WalletMonitorStatus
    value = setup[3].status() | {'external_delivery_configured': True}
    assert WalletMonitorStatus.model_validate(value).external_delivery_configured is True
