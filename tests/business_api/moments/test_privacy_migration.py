import importlib.util
from pathlib import Path

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, text


def test_privacy_migration_preserves_existing_preferences_and_defaults():
    path = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0058_moments_privacy.py'
    assert path.exists()
    spec = importlib.util.spec_from_file_location('privacy_migration', path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert migration.down_revision == '0057_merge_direct_room'
    engine = create_engine('sqlite://')
    with engine.begin() as connection:
        connection.execute(text('CREATE TABLE moments_preferences (user_id TEXT PRIMARY KEY, history_range TEXT, cover_url TEXT)'))
        connection.execute(text("INSERT INTO moments_preferences VALUES ('old', 'THREE_DAYS', 'cover')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
        row = connection.execute(text('SELECT * FROM moments_preferences')).mappings().one()
        assert dict(row) == {'user_id': 'old', 'history_range': 'THREE_DAYS', 'cover_url': 'cover', 'profile_entry_enabled': 1, 'excluded_user_ids': '[]'}
        connection.execute(text("INSERT INTO moments_preferences (user_id) VALUES ('new')"))
        assert connection.execute(text("SELECT profile_entry_enabled FROM moments_preferences WHERE user_id='new'")).scalar() == 1
