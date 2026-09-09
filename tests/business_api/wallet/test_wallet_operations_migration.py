"""Only the additive 0041 step is applied; this is not historical-chain validation."""
import importlib.util
import os
from decimal import Decimal
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


MIGRATION_PATH = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0041_wallet_operations.py'
TABLES = {'wallet_daily_closes', 'wallet_incidents', 'wallet_incident_commands',
          'wallet_alert_receipts', 'wallet_monitor_heartbeats'}


def migration():
    spec = importlib.util.spec_from_file_location('wallet_operations_migration', MIGRATION_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_migration_has_stable_ddl_and_refuses_destructive_downgrade():
    module = migration()
    assert module.revision == '0041_wallet_operations'
    assert module.down_revision == '0040_wallet_safety'
    source = MIGRATION_PATH.read_text(encoding='utf-8')
    assert 'app.modules' not in source and 'metadata' not in source
    with pytest.raises(RuntimeError, match='preserved'):
        module.downgrade()


@pytest.mark.skipif(not os.getenv('REPORTING_PG_URL'), reason='REPORTING_PG_URL required for isolated PostgreSQL migration')
def test_0041_preserves_journal_and_matches_operational_models():
    from app.modules.wallet.closing_models import WalletDailyClose
    from app.modules.wallet.incident_models import WalletAlertReceipt, WalletIncident, WalletIncidentCommand
    from app.modules.wallet.monitoring import WalletMonitorHeartbeat
    models = [WalletDailyClose, WalletAlertReceipt, WalletIncident, WalletIncidentCommand, WalletMonitorHeartbeat]
    url = os.environ['REPORTING_PG_URL']
    schema = 'operations_migration_' + uuid4().hex
    admin = create_engine(url)
    engine = None
    try:
        with admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        engine = create_engine(url, connect_args={'options': f'-csearch_path={schema}'})
        with engine.begin() as connection:
            connection.execute(text('CREATE TABLE wallet_ledger_entries (id VARCHAR(36) PRIMARY KEY, amount NUMERIC(30,6) NOT NULL)'))
            connection.execute(text("INSERT INTO wallet_ledger_entries VALUES ('preserved-journal', 12.345678)"))
            connection.execute(text('CREATE TABLE migration_preservation_marker (value VARCHAR(32) NOT NULL)'))
            connection.execute(text("INSERT INTO migration_preservation_marker VALUES ('before-0041')"))
            journal_before = inspect(connection).get_columns('wallet_ledger_entries')
            with Operations.context(MigrationContext.configure(connection)):
                migration().upgrade()
        with engine.connect() as connection:
            inspector = inspect(connection)
            assert set(inspector.get_table_names()) == TABLES | {'wallet_ledger_entries', 'migration_preservation_marker'}
            assert connection.scalar(text('SELECT amount FROM wallet_ledger_entries')) == Decimal('12.345678')
            assert connection.scalar(text('SELECT value FROM migration_preservation_marker')) == 'before-0041'
            journal_after = inspector.get_columns('wallet_ledger_entries')
            assert [(c['name'], str(c['type']), c['nullable']) for c in journal_before] == [(c['name'], str(c['type']), c['nullable']) for c in journal_after]
            for model in models:
                table = model.__table__
                actual = {c['name']: c for c in inspector.get_columns(table.name)}
                assert set(actual) == set(table.columns.keys())
                for column in table.columns:
                    assert actual[column.name]['nullable'] == column.nullable
                    assert str(actual[column.name]['type'].compile(dialect=engine.dialect)) == str(column.type.compile(dialect=engine.dialect))
                expected_unique = {tuple(c.name for c in constraint.columns) for constraint in table.constraints
                                   if constraint.__class__.__name__ == 'UniqueConstraint'}
                assert {tuple(c['column_names']) for c in inspector.get_unique_constraints(table.name)} == expected_unique
                assert inspector.get_pk_constraint(table.name)['constrained_columns'] == [c.name for c in table.primary_key.columns]
            foreign_keys = inspector.get_foreign_keys('wallet_daily_closes')
            assert len(foreign_keys) == 1 and foreign_keys[0]['referred_table'] == 'wallet_daily_closes'
            assert foreign_keys[0]['constrained_columns'] == ['previous_id']
            with pytest.raises(RuntimeError, match='preserved'):
                with Operations.context(MigrationContext.configure(connection)):
                    migration().downgrade()
            assert connection.scalar(text('SELECT amount FROM wallet_ledger_entries')) == Decimal('12.345678')
    finally:
        if engine is not None:
            engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA IF EXISTS {schema} CASCADE'))
        admin.dispose()
