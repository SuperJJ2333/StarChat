"""Alert transport validates immutable event severity across current incident changes."""
from dataclasses import replace

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxMessage
from app.modules.wallet.alert_delivery import WalletAlertDelivery
from app.modules.wallet.incidents import SandboxWalletAlertHandler
from app.modules.wallet.incident_models import WalletAlertReceipt
from test_wallet_incidents import factory, service, SOURCE_TIMEOUT  # noqa: F401


def queued_alert(factory):
    with factory() as session:
        row = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        return OutboxMessage(row.id, row.topic, row.event_type, row.aggregate_type,
            row.aggregate_id, dict(row.payload), {}, 1)


def test_queued_p0_smtp_alert_replays_with_original_severity_after_t2_correction(factory):
    svc = service(factory)
    row = svc.observe([dict(SOURCE_TIMEOUT, severity='P0')])[0]
    event = queued_alert(factory)
    svc.reclassify_source_timeout(row['id'], actor_id='operator', idempotency_key='alert-correction',
        generation=row['generation'], expected_version=row['version'],
        diagnostic_code='SOURCE_READ_BUDGET_EXPIRED', evidence_digest='e'*64)
    delivery = WalletAlertDelivery(factory)
    assert delivery.prepare(event).severity == 'P0'
    delivery.record_smtp_delivery(event)
    assert delivery.prepare(event) is None
    with factory() as session:
        assert session.get(WalletAlertReceipt, event.id).payload['severity'] == 'P0'


def test_new_t2_alert_is_accepted_by_smtp_and_sandbox(factory):
    service(factory).observe([SOURCE_TIMEOUT])
    event = queued_alert(factory)
    assert WalletAlertDelivery(factory).prepare(event).severity == 'T2'
    SandboxWalletAlertHandler(factory)(event)
    with factory() as session:
        assert session.get(WalletAlertReceipt, event.id).payload['severity'] == 'T2'


def test_sandbox_uses_immutable_queued_p0_identity_after_t2_correction(factory):
    svc = service(factory)
    row = svc.observe([dict(SOURCE_TIMEOUT, severity='P0')])[0]
    event = queued_alert(factory)
    svc.reclassify_source_timeout(row['id'], actor_id='operator', idempotency_key='sandbox-correction',
        generation=row['generation'], expected_version=row['version'],
        diagnostic_code='SOURCE_READ_BUDGET_EXPIRED', evidence_digest='1'*64)
    with pytest.raises(AppError, match='EVENT_CONFLICT'):
        SandboxWalletAlertHandler(factory)(replace(event, payload=event.payload | {'code': 'OTHER'}))
    SandboxWalletAlertHandler(factory)(event)
    with factory() as session:
        assert session.get(WalletAlertReceipt, event.id).payload['severity'] == 'P0'
