import importlib.util
from pathlib import Path
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


def test_migration_adds_tables_without_changing_existing_wallet_state():
    path = Path('services/business-api/migrations/versions/0042_wallet_binding.py')
    assert path.exists()
    spec = importlib.util.spec_from_file_location('binding_migration', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    engine = create_engine('sqlite://')
    with engine.begin() as conn:
        conn.execute(text('CREATE TABLE wallet_controls (id VARCHAR(20) PRIMARY KEY, withdrawals_paused BOOLEAN NOT NULL, pause_reason VARCHAR(255))'))
        conn.execute(text("INSERT INTO wallet_controls VALUES ('global', 1, 'KEEP_CLOSED')"))
        with Operations.context(MigrationContext.configure(conn)):
            module.upgrade()
        assert {'wallet_bindings', 'wallet_binding_states', 'wallet_binding_challenges', 'wallet_address_owners', 'wallet_binding_requests'} <= set(inspect(conn).get_table_names())
        assert conn.execute(text('SELECT pause_reason FROM wallet_controls')).scalar() == 'KEEP_CLOSED'
        assert conn.execute(text('SELECT count(*) FROM wallet_bindings')).scalar() == 0
