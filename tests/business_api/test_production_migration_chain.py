"""Run real Alembic history using disposable, synthetic PostgreSQL schemas."""
import io
import os
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import MetaData, Table, create_engine, inspect, text
from sqlalchemy.engine import make_url


API_ROOT = Path(__file__).resolve().parents[2] / 'services/business-api'


def migration_config(url, output=None):
    config = Config(str(API_ROOT / 'alembic.ini'), output_buffer=output)
    config.set_main_option('script_location', str(API_ROOT / 'migrations'))
    config.set_main_option('path_separator', 'os')
    config.set_main_option('sqlalchemy.url', url.replace('%', '%%'))
    return config


@pytest.fixture
def isolated_database(monkeypatch):
    url = os.getenv('REPORTING_PG_URL')
    if not url:
        pytest.skip('REPORTING_PG_URL required for isolated PostgreSQL migration')
    schema = 'production_migration_' + uuid4().hex
    admin = create_engine(url)
    engine = None
    try:
        with admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        scoped_url = make_url(url).update_query_dict({'options': f'-csearch_path={schema}'})
        scoped_string = scoped_url.render_as_string(hide_password=False)
        monkeypatch.setenv('BUSINESS_DATABASE_URL', scoped_string)
        engine = create_engine(scoped_url)
        yield migration_config(scoped_string), engine
    finally:
        if engine is not None:
            engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA IF EXISTS {schema} CASCADE'))
        admin.dispose()


def assert_head(config, engine):
    with engine.connect() as connection:
        assert connection.execute(text('SELECT version_num FROM alembic_version')).scalars().all() == ScriptDirectory.from_config(config).get_heads()
        assert {'wallet_daily_closes', 'wallet_incidents', 'wallet_deposit_addresses'} <= set(inspect(connection).get_table_names())


def test_fresh_full_history_and_repeat_head(isolated_database):
    config, engine = isolated_database
    command.upgrade(config, 'head')
    assert_head(config, engine)
    command.upgrade(config, 'head')
    assert_head(config, engine)


@pytest.mark.parametrize('revision', ['0014_moments_prefs', '0024_moment_notifications'])
def test_existing_cover_survives_full_upgrade(isolated_database, revision):
    config, engine = isolated_database
    command.upgrade(config, revision)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        users = Table('users', MetaData(), autoload_with=connection)
        values = dict(id='synthetic-user', username='synthetic', username_normalized='synthetic', email='synthetic@example.invalid', email_normalized='synthetic@example.invalid', password_hash='synthetic-not-a-password', status='ACTIVE', created_at=now, updated_at=now)
        if 'nickname' in users.c:
            values.update(nickname='Synthetic', profile_updated_at=now)
        connection.execute(users.insert().values(**values))
        connection.execute(text("INSERT INTO moments_preferences (user_id, history_range, personalized_recommendations, cover_url, updated_at) VALUES ('synthetic-user', 'ALL', false, 'https://example.invalid/synthetic-cover', :now)"), {'now': now})
    command.upgrade(config, '0025_moment_drafts_native_ads')
    command.downgrade(config, '0024_moment_notifications')
    with engine.connect() as connection:
        assert connection.scalar(text('SELECT cover_url FROM moments_preferences')) == 'https://example.invalid/synthetic-cover'
    command.upgrade(config, 'head')
    assert_head(config, engine)
    with engine.connect() as connection:
        assert connection.scalar(text('SELECT cover_url FROM moments_preferences')) == 'https://example.invalid/synthetic-cover'
        assert connection.scalar(text('SELECT nickname FROM users')) in ('synthetic', 'Synthetic')


def test_missing_legacy_cover_is_added_and_downgrade_retains_it(isolated_database):
    config, engine = isolated_database
    command.upgrade(config, '0024_moment_notifications')
    # Simulate only the known legacy drift in this newly created empty schema.
    with engine.begin() as connection:
        connection.execute(text('ALTER TABLE moments_preferences DROP COLUMN cover_url'))
    command.upgrade(config, '0025_moment_drafts_native_ads')
    command.downgrade(config, '0024_moment_notifications')
    with engine.connect() as connection:
        columns = {c['name']: c for c in inspect(connection).get_columns('moments_preferences')}
        assert columns['cover_url']['nullable']
        assert columns['cover_url']['type'].length == 2048
    command.upgrade(config, 'head')
    assert_head(config, engine)


def test_0025_downgrade_preserves_0014_cover_column(isolated_database):
    config, engine = isolated_database
    command.upgrade(config, '0025_moment_drafts_native_ads')
    command.downgrade(config, '0024_moment_notifications')
    with engine.connect() as connection:
        assert 'cover_url' in {c['name'] for c in inspect(connection).get_columns('moments_preferences')}


def test_offline_full_history_uses_compatible_cover_ddl(monkeypatch):
    monkeypatch.delenv('BUSINESS_DATABASE_URL', raising=False)
    output = io.StringIO()
    config = migration_config('postgresql+psycopg://synthetic@localhost/synthetic', output)
    command.upgrade(config, 'head', sql=True)
    sql = ' '.join(output.getvalue().lower().split())
    assert 'alter table moments_preferences add column if not exists cover_url varchar(2048)' in sql
    output = io.StringIO()
    config.output_buffer = output
    command.downgrade(config, '0025_moment_drafts_native_ads:0024_moment_notifications', sql=True)
    assert 'drop column cover_url' not in output.getvalue().lower()


def test_actual_settings_branch_preserves_wallet_journal_and_withdrawal(isolated_database):
    config, engine = isolated_database
    command.upgrade(config, '0038_app_settings_text')
    with engine.begin() as connection:
        assert connection.scalar(text('SELECT version_num FROM alembic_version')) == '0038_app_settings_text'
        assert 'wallet_deposit_addresses' not in inspect(connection).get_table_names()
        connection.execute(text("INSERT INTO wallet_ledger_transactions VALUES ('synthetic-tx', 'USDT', 'synthetic', 'synthetic-key', 'synthetic-user', 'SYNTHETIC_MIGRATION', now())"))
        connection.execute(text("INSERT INTO wallet_ledger_entries VALUES ('synthetic-credit', 'synthetic-tx', 'synthetic-user', 'USDT', 12.345678, now()), ('synthetic-debit', 'synthetic-tx', 'synthetic-offset', 'USDT', -12.345678, now())"))
        connection.execute(text("INSERT INTO wallet_withdrawals (id, user_id, client_order_id, address, amount, status, created_at, updated_at) VALUES ('synthetic-withdrawal', 'synthetic-user', 'synthetic-order', 'synthetic-invalid-address', 2.123456, 'PENDING_FINANCE', now(), now())"))
        before = connection.execute(text('SELECT id, account_id, amount FROM wallet_ledger_entries ORDER BY id')).all()
    command.upgrade(config, 'head')
    command.upgrade(config, 'head')
    assert_head(config, engine)
    with engine.connect() as connection:
        assert connection.execute(text('SELECT id, account_id, amount FROM wallet_ledger_entries ORDER BY id')).all() == before
        assert connection.scalar(text('SELECT sum(amount) FROM wallet_ledger_entries')) == Decimal('0')
        assert connection.execute(text('SELECT amount, status FROM wallet_withdrawals')).one() == (Decimal('2.123456'), 'PENDING_FINANCE')
