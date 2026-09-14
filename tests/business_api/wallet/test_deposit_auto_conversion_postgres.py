from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from uuid import uuid4
import os

import pytest
from sqlalchemy import create_engine, func, select, text

import test_deposit_receipts as fixtures


@pytest.fixture
def pg_core(monkeypatch):
    from app.modules.wallet import repair_models  # noqa: F401
    url = os.environ.get('REPORTING_PG_URL')
    if not url:
        pytest.skip('REPORTING_PG_URL required for isolated PostgreSQL integration')
    schema = 'deposit_convert_' + uuid4().hex
    admin = create_engine(url)
    with admin.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA {schema}'))
    engine = create_engine(url, connect_args={'options': f'-csearch_path={schema}'}, pool_size=5)
    monkeypatch.setattr(fixtures, 'create_engine', lambda *args, **kwargs: engine)
    try:
        yield from fixtures.core.__wrapped__()
    finally:
        engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


def test_concurrent_receipt_conversion_is_one_receipt_one_conversion(pg_core):
    from app.core.outbox import OutboxEvent
    from app.modules.audit.models import AuditEvent
    from app.modules.ledger.service import LedgerService
    from app.modules.wallet.deposit_conversion import convert_credited_receipt
    from app.modules.wallet.models import WalletControl, WalletConversion
    pg_core[0].reserve_policy = pg_core[0].wallet_ledger.reserve_policy = 'manual_liquidity'
    fixtures.intent(pg_core)
    receipt = fixtures.ingest(pg_core)[0]
    with pg_core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False
    def invoke(actor):
        with pg_core[1].begin() as session:
            return convert_credited_receipt(session, pg_core[1], receipt_id=receipt['id'], actor_id=actor,
                enabled=True, reserve_policy='manual_liquidity')
    with ThreadPoolExecutor(max_workers=2) as executor:
        first, second = list(executor.map(invoke, ['worker', 'admin']))
    assert first['conversion_id'] == second['conversion_id']
    assert pg_core[0].wallet_ledger.balance('alice') == Decimal('0')
    assert LedgerService(pg_core[1]).balance('alice') == Decimal('10')
    with pg_core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletConversion)) == 1
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.action == 'wallet.deposit_auto_converted')) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.event_type == 'wallet.deposit_auto_converted')) == 1
