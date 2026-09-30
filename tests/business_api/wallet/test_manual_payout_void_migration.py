"""The new terminal state expands the existing manual payout schema."""
import importlib.util
import os
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


VERSIONS = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions'


def _migration(name):
    spec = importlib.util.spec_from_file_location(name, VERSIONS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_void_revision_expands_claimed_order_without_erasing_history():
    original, revision = _migration('0046_manual_payouts'), _migration('0093_unbroadcast_payout_void')
    assert revision.down_revision == '0092_admin_session_entry_mode'
    engine = create_engine('sqlite://')
    with engine.begin() as connection:
        operations = Operations(MigrationContext.configure(connection))
        original.op = revision.op = operations
        original.upgrade()
        connection.execute(text("""INSERT INTO wallet_manual_payout_quotes
            (id,user_id,amount,snapshot,digest,created_at,expires_at)
            VALUES ('q','alice',10,'{}','digest','2026-09-30','2026-10-01')"""))
        connection.execute(text("""INSERT INTO wallet_manual_payout_orders
            (id,quote_id,user_id,amount,digest,status,claimed_by,claimed_at,created_at,updated_at)
            VALUES ('o','q','alice',10,'digest','UNKNOWN','owner','2026-09-30','2026-09-30','2026-09-30')"""))
        revision.upgrade()
        assert 'version' in {col['name'] for col in inspect(connection).get_columns('wallet_manual_payout_orders')}
        assert connection.scalar(text("SELECT version FROM wallet_manual_payout_orders WHERE id='o'")) == 1
        connection.execute(text("UPDATE wallet_manual_payout_orders SET status='VOIDED' WHERE id='o'"))
        assert connection.scalar(text("SELECT claimed_by FROM wallet_manual_payout_orders WHERE id='o'")) == 'owner'
        with pytest.raises(Exception):
            with connection.begin_nested():
                connection.execute(text("UPDATE wallet_manual_payout_orders SET candidate_txid='a' WHERE id='o'"))
        with pytest.raises(RuntimeError, match='retained'):
            revision.downgrade()
    engine.dispose()


@pytest.mark.skipif(not os.getenv('REPORTING_PG_URL'), reason='REPORTING_PG_URL required for isolated PostgreSQL migration')
def test_postgres_void_guard_rejects_candidates_and_terminal_mutation():
    original, revision = _migration('0046_manual_payouts'), _migration('0093_unbroadcast_payout_void')
    schema = 'payout_void_' + uuid4().hex
    admin = create_engine(os.environ['REPORTING_PG_URL'])
    engine = None
    try:
        with admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        engine = create_engine(os.environ['REPORTING_PG_URL'], connect_args={'options': f'-csearch_path={schema}'})
        with engine.begin() as connection:
            operations = Operations(MigrationContext.configure(connection))
            original.op = revision.op = operations
            original.upgrade()
            connection.execute(text('CREATE TABLE wallet_manual_payout_candidates '
                '(id VARCHAR(36) PRIMARY KEY, order_id VARCHAR(36) NOT NULL, txid VARCHAR(64) NOT NULL)'))
            connection.execute(text("""INSERT INTO wallet_manual_payout_quotes
                (id,user_id,amount,snapshot,digest,created_at,expires_at)
                VALUES ('q','alice',10,'{}','digest',now(),now()+interval '1 day')"""))
            connection.execute(text("""INSERT INTO wallet_manual_payout_orders
                (id,quote_id,user_id,amount,digest,status,claimed_by,claimed_at,created_at,updated_at)
                VALUES ('o','q','alice',10,'digest','UNKNOWN','owner',now(),now(),now())"""))
            revision.upgrade()
            connection.execute(text("UPDATE wallet_manual_payout_orders SET status='VOIDED' WHERE id='o'"))
            with pytest.raises(Exception):
                with connection.begin_nested():
                    connection.execute(text("UPDATE wallet_manual_payout_orders SET review_reason='CHANGED' WHERE id='o'"))
        with engine.begin() as connection:
            connection.execute(text("""INSERT INTO wallet_manual_payout_quotes
                (id,user_id,amount,snapshot,digest,created_at,expires_at)
                VALUES ('q2','alice',10,'{}','digest',now(),now()+interval '1 day')"""))
            connection.execute(text("""INSERT INTO wallet_manual_payout_orders
                (id,quote_id,user_id,amount,digest,status,claimed_by,claimed_at,created_at,updated_at)
                VALUES ('o2','q2','alice',10,'digest','UNKNOWN','owner',now(),now(),now())"""))
            connection.execute(text("INSERT INTO wallet_manual_payout_candidates VALUES ('c','o2','txid')"))
            with pytest.raises(Exception):
                with connection.begin_nested():
                    connection.execute(text("UPDATE wallet_manual_payout_orders SET status='VOIDED' WHERE id='o2'"))
    finally:
        if engine is not None:
            engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA IF EXISTS {schema} CASCADE'))
        admin.dispose()
