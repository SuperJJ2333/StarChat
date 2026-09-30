from importlib.util import module_from_spec, spec_from_file_location
from io import StringIO
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, text


def migration():
    source = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0090_friend_discovery_index.py'
    assert source.is_file(), 'friend discovery index migration is required'
    spec = spec_from_file_location('discovery_migration', source)
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_discovery_migration_creates_only_nonunique_index_online():
    module = migration()
    engine = create_engine('sqlite://')
    with engine.begin() as connection:
        connection.execute(text('CREATE TABLE users (status VARCHAR(30), username_normalized VARCHAR(64))'))
        connection.execute(text("INSERT INTO users VALUES ('ACTIVE', 'a1111123')"))
        context = MigrationContext.configure(connection)
        with Operations.context(context): module.upgrade()
        indexes = connection.execute(text("PRAGMA index_list('users')")).all()
        assert [(row[1], row[2]) for row in indexes] == [('ix_users_discovery_handle', 0)]
        assert connection.execute(text('SELECT username_normalized FROM users')).scalar_one() == 'a1111123'
        with Operations.context(context): module.downgrade()
        assert connection.execute(text("PRAGMA index_list('users')")).first() is not None


def test_discovery_migration_offline_pg_uses_concurrent_nonunique_ddl():
    module = migration()
    output = StringIO()
    context = MigrationContext.configure(dialect_name='postgresql', opts={'as_sql': True, 'output_buffer': output})
    with Operations.context(context): module.upgrade()
    sql = output.getvalue()
    assert 'CREATE INDEX CONCURRENTLY' in sql
    assert 'CREATE UNIQUE' not in sql
    assert 'existing.indpred IS NOT NULL' in sql
    assert "existing.amname <> 'btree'" in sql
    assert 'existing.expressions IS DISTINCT FROM' in sql
    assert 'substr(username_normalized, 1, length(username_normalized) - 2)' in sql
    assert module.down_revision == '0089_username_claims'
