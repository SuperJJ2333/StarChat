"""Separate PostgreSQL connections prove event serialization and rollback."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4
import os
import pytest
from sqlalchemy import create_engine, text, select, func
import test_deposit_receipts as fixtures
from test_admin_deposit_repairs import repair, preview, execute
from app.core.errors import AppError
from app.modules.wallet.models import WalletLedgerTransaction
from app.modules.wallet.repair_models import RepairCommand


@pytest.fixture
def core(monkeypatch):
    url = os.environ.get('REPORTING_PG_URL')
    if not url:
        pytest.skip('REPORTING_PG_URL required for isolated PostgreSQL integration')
    schema = 'repair_' + uuid4().hex
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


@pytest.mark.parametrize('same_key', [False, True])
def test_concurrent_repair_consumes_only_one_event(core, repair, same_key):
    p = preview(repair)
    barrier = Barrier(2)
    original = core[2].transaction_evidence
    def network(txid):
        result = original(txid)
        barrier.wait(timeout=10)
        return result
    core[2].transaction_evidence = network
    def submit(index):
        try:
            return execute(repair, p, key='same' if same_key else f'key-{index}',
                operation='same-operation' if same_key else f'operation-{index}')
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(submit, [1, 2]))
    assert sum(isinstance(r, dict) for r in results) == (2 if same_key else 1)
    if same_key:
        assert results[0] == results[1]
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 1
        assert session.scalar(select(func.count()).select_from(RepairCommand)) == 1


def test_postgres_migration_guards_native_updates_and_deletes(core):
    from importlib.util import module_from_spec, spec_from_file_location
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from sqlalchemy.exc import DBAPIError
    from app.modules.wallet.repair_models import RepairPreview
    spec = spec_from_file_location('repair_migration',
        'services/business-api/migrations/versions/0064_admin_deposit_repairs.py')
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    engine = core[1].kw['bind']
    with engine.begin() as connection:
        RepairCommand.__table__.drop(connection)
        RepairPreview.__table__.drop(connection)
        module.op = Operations(MigrationContext.configure(connection))
        module.upgrade()
        connection.execute(text("INSERT INTO wallet_repair_previews VALUES "
            "('preview','owner','DEPOSIT',:digest,'{}',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP + interval '90 seconds')"),
            {'digest': 'a'*64})
    for sql in ("UPDATE wallet_repair_previews SET digest='tampered' WHERE id='preview'",
                "DELETE FROM wallet_repair_previews WHERE id='preview'"):
        with pytest.raises(DBAPIError, match='append-only'):
            with engine.begin() as connection:
                connection.execute(text(sql))
