import importlib.util
from pathlib import Path
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


def test_poster_expand_keeps_legacy_row_and_application_rollback_data():
    root=Path(__file__).resolve().parents[3]
    path=root/"services/business-api/migrations/versions/0091_moment_video_posters.py"
    spec=importlib.util.spec_from_file_location("moment_poster_expand",path)
    migration=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert migration.down_revision=="0090_friend_discovery_index"
    engine=create_engine("sqlite+pysqlite:///:memory:")
    with engine.begin() as connection:
        connection.execute(text("CREATE TABLE moments (id TEXT PRIMARY KEY)"))
        connection.execute(text("INSERT INTO moments (id) VALUES ('synthetic-legacy')"))
        context=MigrationContext.configure(connection)
        with Operations.context(context):
            migration.upgrade()
        assert connection.execute(text("SELECT id,video_poster_keys,request_fingerprint FROM moments")).one()==("synthetic-legacy",None,None)
        connection.execute(text("UPDATE moments SET video_poster_keys=:keys, request_fingerprint=:identity"),{"keys":"[null]","identity":"a"*64})
        with Operations.context(context):
            migration.downgrade()
        assert {"video_poster_keys","request_fingerprint"}.issubset({c["name"] for c in inspect(connection).get_columns("moments")})
        assert connection.execute(text("SELECT video_poster_keys,request_fingerprint FROM moments")).one()==("[null]","a"*64)
