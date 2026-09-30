from decimal import Decimal

from sqlalchemy import create_engine
from sqlalchemy import select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.audit.models import AuditEvent
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.service import WalletService
from tasks.wallet import WalletMaintenanceTask


def test_maintenance_reports_custody_mismatch_and_orphan_without_pausing():
    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    try:
        Base.metadata.create_all(engine)
        factory = create_session_factory(engine)
        provider = SandboxCustodyProvider(secret='offline-monitor-test')
        provider.custody_balance = Decimal('20.000000')
        service = WalletService(factory, provider)
        service.credit_for_test('user', Decimal('20.000000'))
        provider.submit_withdrawal(client_order_id='orphan', address='T_OFFLINE',
            amount=Decimal('10.000000'))
        provider.withdrawal_event(client_order_id='orphan', status='CHAIN_CONFIRMED',
            confirmations=20, event_id='orphan-confirmed')

        result = WalletMaintenanceTask(factory, service).run_once()

        assert result['reconciliation'].matched is False
        assert service.detect_orphan_external_orders(actor_id='test')['orphan_order_ids'] == ['orphan']
        assert service.withdrawals_paused() is False
        with factory() as session:
            incidents = {row.code: row for row in session.scalars(select(WalletIncident))}
            assert set(incidents) == {'RESERVE_DEFICIT', 'ORPHAN_EXTERNAL_ORDER'}
            assert all(row.condition_active and row.severity == 'P0' for row in incidents.values())
            alerts = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')).all()
            assert {row.payload['code'] for row in alerts} == set(incidents)
            assert len(session.scalars(select(AuditEvent).where(
                AuditEvent.action == 'wallet.incident.opened')).all()) == 2
        WalletMaintenanceTask(factory, service).run_once()
        unrelated = WalletIncidentService(factory).observe([dict(
            fingerprint='unrelated:signal', code='OTHER_SOURCE', severity='P0',
            subject_id='global')], complete=False)[0]
        provider.custody_balance = Decimal('20.000000')
        assert WalletMaintenanceTask(factory, service).run_once()['reconciliation'].matched is True
        with factory() as session:
            incidents = {row.code: row for row in session.scalars(select(WalletIncident))}
            assert incidents['RESERVE_DEFICIT'].condition_active is False
            assert incidents['ORPHAN_EXTERNAL_ORDER'].condition_active is True
            assert session.get(WalletIncident, unrelated['id']).condition_active is True
            assert len(session.scalars(select(OutboxEvent).where(
                OutboxEvent.topic == 'wallet.alert')).all()) == 3
        assert service.withdrawals_paused() is False
    finally:
        engine.dispose()
