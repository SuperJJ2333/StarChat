"""Add delivery configuration without rewriting operational or financial history."""
import importlib.util
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_delivery_column_defaults_false_and_preserves_old_writer():
    path = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0051_monitor_delivery.py'
    spec = importlib.util.spec_from_file_location('monitor_delivery_migration', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.down_revision == '0050_manual_reserve'
    engine = sa.create_engine('sqlite://')
    with engine.begin() as connection:
        connection.exec_driver_sql('CREATE TABLE wallet_monitor_heartbeats '
            '(id VARCHAR(36) PRIMARY KEY, last_error_code VARCHAR(100))')
        connection.exec_driver_sql("INSERT INTO wallet_monitor_heartbeats VALUES ('global', 'SOURCE_UNAVAILABLE')")
        module.op = Operations(MigrationContext.configure(connection))
        module.upgrade()
        assert connection.exec_driver_sql('SELECT * FROM wallet_monitor_heartbeats').one() == (
            'global', 'SOURCE_UNAVAILABLE', 0)
        connection.exec_driver_sql("INSERT INTO wallet_monitor_heartbeats (id) VALUES ('legacy-writer')")
        assert connection.exec_driver_sql("SELECT external_delivery_configured FROM wallet_monitor_heartbeats WHERE id='legacy-writer'").scalar_one() == 0
        with pytest.raises(sa.exc.IntegrityError):
            with connection.begin_nested():
                connection.exec_driver_sql('UPDATE wallet_monitor_heartbeats SET external_delivery_configured=NULL')
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()
