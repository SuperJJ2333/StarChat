"""Expanded handle claims retain existing accounts and reject ambiguous ownership."""
from datetime import datetime, timezone
from pathlib import Path
import runpy
from io import StringIO

from alembic import op
from alembic.migration import MigrationContext
from alembic.operations import Operations
import pytest
import sqlalchemy as sa


MIGRATION = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0089_username_claims.py'


def test_offline_upgrade_emits_conflict_check_and_backfill_without_reading_database():
    output = StringIO()
    context = MigrationContext.configure(dialect_name='postgresql', opts={
        'as_sql': True, 'literal_binds': True, 'output_buffer': output})
    with Operations.context(context):
        runpy.run_path(str(MIGRATION))['upgrade']()
    sql = output.getvalue()
    assert 'ambiguous username ownership' in sql
    assert sql.index('ambiguous username ownership') < sql.index('ADD COLUMN username_changed_at')
    assert 'INSERT INTO identity_username_claims' in sql
    assert 'ix_identity_username_claims_owner_user_id' in sql


@pytest.mark.parametrize('conflict', [False, True])
def test_expand_backfills_handles_and_stable_matrix_localparts(conflict):
    engine = sa.create_engine('sqlite+pysqlite:///:memory:')
    metadata = sa.MetaData()
    users = sa.Table('users', metadata,
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('username_normalized', sa.String(64), nullable=False, unique=True),
        sa.Column('matrix_user_id', sa.String(255)),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    metadata.create_all(engine)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(users.insert(), [
            {'id': 'a', 'username_normalized': 'newalice', 'matrix_user_id': '@oldalice:matrix.test', 'created_at': now},
            {'id': 'b', 'username_normalized': 'oldalice' if conflict else 'bobby', 'matrix_user_id': '@bobby:matrix.test', 'created_at': now}])
        namespace = runpy.run_path(str(MIGRATION))
        with Operations.context(MigrationContext.configure(connection)):
            if conflict:
                with pytest.raises(RuntimeError, match='ambiguous username ownership'):
                    namespace['upgrade']()
            else:
                namespace['upgrade']()
                rows = dict(connection.execute(sa.text('SELECT normalized, owner_user_id FROM identity_username_claims')).all())
                assert rows == {'newalice': 'a', 'oldalice': 'a', 'bobby': 'b'}
                assert connection.scalar(sa.text('SELECT count(*) FROM users')) == 2
                columns = {item['name'] for item in sa.inspect(connection).get_columns('users')}
                assert 'username_changed_at' in columns
                with pytest.raises(RuntimeError, match='retained'):
                    namespace['downgrade']()
    engine.dispose()
