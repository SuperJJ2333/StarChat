"""Exercise the additive migration against an isolated prior-schema database."""
import importlib.util
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def migration(filename='0043_funding_intents.py'):
    path = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions' / filename
    assert path.is_file(), 'deposit intent migration missing'
    spec = importlib.util.spec_from_file_location('funding_migration', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_scan_migration_retains_existing_data_and_rejects_invalid_progress():
    module = migration('0048_funding_scan.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE existing_history (id INTEGER PRIMARY KEY)')
        conn.exec_driver_sql('INSERT INTO existing_history VALUES (1)')
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        assert conn.exec_driver_sql('SELECT id FROM existing_history').scalar_one() == 1
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        state = sa.Table('wallet_funding_scan_state', sa.MetaData(), autoload_with=conn)
        item = sa.Table('wallet_funding_scan_items', sa.MetaData(), autoload_with=conn)
        conn.execute(state.insert().values(id='global', source_identity='a'*64,
            cursor_rowid=1, source_max_rowid=2, checkpoint_ms=0, updated_at=now))
        conn.execute(item.insert().values(txid='b'*64, state='PENDING', discovered_rowid=1,
            attempts=0, created_at=now, updated_at=now))
        for table, values in ((state, {'cursor_rowid': 3}), (state, {'checkpoint_ms': -1}),
                              (item, {'state': 'CREDITED'}), (item, {'attempts': -1}),
                              (item, {'discovered_rowid': 0})):
            with pytest.raises(sa.exc.IntegrityError):
                with conn.begin_nested():
                    conn.execute(table.update().values(**values))
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_coverage_migration_requires_evidence_shape_and_unique_source_log():
    from datetime import datetime, timezone
    module = migration('0049_funding_coverage.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        table = sa.Table('wallet_funding_coverage_events', sa.MetaData(), autoload_with=conn)
        row = dict(id='coverage-1', source_identity='a'*64, source_rowid=1, txid='b'*64, log_index=0,
            amount_units='10000000', from_address='isolated-source', to_address='isolated-target',
            block_number=100, timestamp_ms=1, facts_digest='c'*64, status='PENDING', created_at=datetime.now(timezone.utc))
        conn.execute(table.insert().values(**row))
        for values in ({'source_rowid': 0}, {'log_index': -1}, {'status': 'VERIFIED'}, {'status': 'CONFLICT'}):
            with pytest.raises(sa.exc.IntegrityError):
                with conn.begin_nested():
                    conn.execute(table.update().values(**values))
        with pytest.raises(sa.exc.IntegrityError):
            with conn.begin_nested():
                conn.execute(table.insert().values(**(row | {'id':'coverage-2','source_rowid':2})))
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_manual_reserve_migration_retains_evaluations_and_rejects_invalid_versions():
    from datetime import datetime, timezone
    module = migration('0050_manual_reserve.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE prior_ledger (id INTEGER PRIMARY KEY)')
        conn.exec_driver_sql('INSERT INTO prior_ledger VALUES (1)')
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        assert conn.exec_driver_sql('SELECT id FROM prior_ledger').scalar_one() == 1
        table = sa.Table('ledger_manual_reserve_evaluations', sa.MetaData(), autoload_with=conn)
        row = dict(id='evaluation-1', idempotency_key='evaluation-fixture', payload_digest='a'*64,
            source_identity='b'*64, observation_id=1, cut_digest='c'*64,
            expected_version=None, result_version=1, evidence={}, created_at=datetime.now(timezone.utc))
        conn.execute(table.insert().values(**row))
        for values in ({'observation_id': 0}, {'expected_version': 0}, {'result_version': 0},
                       {'expected_version': 2, 'result_version': 2}):
            with pytest.raises(sa.exc.IntegrityError):
                with conn.begin_nested():
                    conn.execute(table.update().values(**values))
        with pytest.raises(sa.exc.IntegrityError):
            with conn.begin_nested():
                conn.execute(table.insert().values(**(row | {'id': 'evaluation-2'})))
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_policy_migration_preserves_legacy_binding_without_inventing_evidence():
    module = migration('0044_binding_policy.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE wallet_bindings (id VARCHAR(36) PRIMARY KEY)')
        conn.exec_driver_sql("INSERT INTO wallet_bindings (id) VALUES ('old-binding')")
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        assert conn.exec_driver_sql('SELECT barrier_policy FROM wallet_bindings').scalar_one() == 'LEGACY_UNSPECIFIED'
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_manual_payout_migration_adds_immutable_execution_tables():
    module = migration('0046_manual_payouts.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        names = sa.inspect(conn).get_table_names()
        for name in ('quotes', 'orders', 'commands', 'events'):
            assert 'wallet_manual_payout_' + name in names
        quote_checks = sa.inspect(conn).get_check_constraints('wallet_manual_payout_quotes')
        assert any('amount >= 10' in check['sqltext'] for check in quote_checks)
        order_checks = sa.inspect(conn).get_check_constraints('wallet_manual_payout_orders')
        assert any('UNKNOWN' in check['sqltext'] for check in order_checks)
        unique = sa.inspect(conn).get_unique_constraints('wallet_manual_payout_events')
        assert any(item['column_names'] == ['network', 'contract', 'txid', 'log_index'] for item in unique)
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_candidate_migration_preserves_original_order_locator():
    previous, module = migration('0046_manual_payouts.py'), migration('0047_payout_candidates.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        operations = Operations(MigrationContext.configure(conn))
        previous.op = operations
        previous.upgrade()
        before = [(c['name'], str(c['type']), c['nullable']) for c in sa.inspect(conn).get_columns('wallet_manual_payout_orders')]
        module.op = operations
        module.upgrade()
        assert [(c['name'], str(c['type']), c['nullable']) for c in sa.inspect(conn).get_columns('wallet_manual_payout_orders')] == before
        unique = sa.inspect(conn).get_unique_constraints('wallet_manual_payout_candidates')
        assert any(item['column_names'] == ['order_id', 'txid'] for item in unique)
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_receipt_migration_adds_event_tables_and_fulfilled_intents():
    previous, module = migration(), migration('0045_deposit_receipts.py')
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE wallet_bindings (id VARCHAR(36) PRIMARY KEY)')
        conn.exec_driver_sql('CREATE TABLE wallet_ledger_transactions (id VARCHAR(36) PRIMARY KEY)')
        operations = Operations(MigrationContext.configure(conn))
        previous.op = operations
        previous.upgrade()
        module.op = operations
        module.upgrade()
        names = sa.inspect(conn).get_table_names()
        assert 'wallet_deposit_receipts' in names
        assert 'wallet_deposit_receipt_anomalies' in names
        checks = sa.inspect(conn).get_check_constraints('wallet_deposit_intents')
        assert any('FULFILLED' in check['sqltext'] for check in checks)
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()


def test_additive_migration_preserves_binding_and_enforces_one_open():
    module = migration()
    engine = sa.create_engine('sqlite://')
    with engine.begin() as conn:
        conn.exec_driver_sql('CREATE TABLE wallet_bindings (id VARCHAR(36) PRIMARY KEY)')
        conn.exec_driver_sql("INSERT INTO wallet_bindings (id) VALUES ('existing-binding')")
        module.op = Operations(MigrationContext.configure(conn))
        module.upgrade()
        assert conn.exec_driver_sql('SELECT id FROM wallet_bindings').scalar_one() == 'existing-binding'
        table = sa.Table('wallet_deposit_intents', sa.MetaData(), autoload_with=conn)
        from datetime import datetime, timedelta, timezone
        from decimal import Decimal
        now = datetime.now(timezone.utc)
        row = dict(id='intent1', user_id='alice', idempotency_key='key1', binding_id='existing-binding',
            binding_version=1, binding_effective_from_block=101, source_address='isolated-source',
            official_address='isolated-official', official_config_version='isolated-v1', network='tron-mainnet',
            expected_amount=Decimal('10.000000'), rules_snapshot={}, status='OPEN',
            created_at=now, expires_at=now + timedelta(minutes=20))
        conn.execute(table.insert().values(**row))
        with pytest.raises(sa.exc.IntegrityError):
            with conn.begin_nested():
                conn.execute(table.insert().values(**(row | {'id': 'intent2', 'idempotency_key': 'key2'})))
        with pytest.raises(sa.exc.IntegrityError):
            with conn.begin_nested():
                conn.execute(table.update().values(expected_amount=Decimal('9.999999')))
        with pytest.raises(RuntimeError, match='retained'):
            module.downgrade()
    engine.dispose()
