"""Release checks use synthetic schemas and never contact a custody service."""
import importlib
import importlib.util
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest
from sqlalchemy import Column, MetaData, String, Table, create_engine, event, text

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'services/business-api'))


def module():
    path = ROOT / 'scripts/wallet_release_preflight.py'
    assert path.exists(), 'Production needs a read-only wallet release preflight'
    spec = importlib.util.spec_from_file_location('wallet_release_preflight', path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def test_release_preflight_exists():
    module()


@pytest.fixture
def runtime(monkeypatch):
    helper = module()
    from app.core.database import Base
    for name in ('app.modules.friendship.models', 'app.modules.identity.operation_password_models', 'app.modules.wallet.models', 'app.modules.wallet.closing_models',
                 'app.modules.wallet.binding_models',
                 'app.modules.wallet.incident_models', 'app.modules.wallet.safety',
                 'app.modules.wallet.monitoring', 'app.modules.wallet.funding_models',
                 'app.modules.wallet.receipt_models', 'app.modules.wallet.manual_payout_models',
                 'app.modules.wallet.manual_control_models', 'app.modules.wallet.handover_models',
                 'app.modules.wallet.funding_scan_models', 'app.modules.wallet.funding_coverage_models',
                 'app.modules.ledger.manual_reserve',
                 'app.modules.ledger.restriction_models', 'app.core.outbox_handover_models',
                 'app.modules.ledger.models', 'app.modules.audit.models', 'app.core.outbox'):
        importlib.import_module(name)
    metadata = MetaData()
    for table in Base.metadata.tables.values():
        Table(table.name, metadata, *(Column(c.name, String) for c in table.columns))
    engine = create_engine('sqlite+pysqlite:///:memory:')
    metadata.create_all(engine)
    with engine.begin() as connection:
        connection.execute(text('CREATE TABLE alembic_version (version_num VARCHAR(64))'))
        connection.execute(text('INSERT INTO alembic_version VALUES (:head)'), {'head': helper.EXPECTED_HEAD})
    for name in tuple(os.environ):
        if name.startswith('BUSINESS_'):
            monkeypatch.delenv(name)
    values = dict(ENVIRONMENT='production', DATABASE_URL='sqlite+pysqlite:///:memory:',
                  TOTP_ISSUER='fixture', MATRIX_PUBLIC_HOMESERVER_URL='https://fixture.invalid',
                  AVATAR_PUBLIC_BASE_URL='https://fixture.invalid')
    for name in ('JWT_SECRET', 'EMAIL_VERIFICATION_SECRET', 'PASSWORD_RESET_SECRET',
                 'SYNAPSE_ADMIN_ACCESS_TOKEN', 'MATRIX_PROVISION_SECRET',
                 'AVATAR_URL_SIGNING_SECRET', 'REFERRAL_CODE_SECRET'):
        values[name] = 'sensitive-fixture-value-never-output'
    for name, value in values.items():
        monkeypatch.setenv('BUSINESS_' + name, value)
    monkeypatch.setattr(helper, 'create_engine', lambda *args, **kwargs: engine)
    yield helper, engine
    engine.dispose()


def result(helper, capsys):
    code = helper.main()
    output = capsys.readouterr()
    assert output.err == ''
    assert 'sensitive-fixture' not in output.out
    return code, json.loads(output.out)


def test_production_funding_disabled_is_release_ready_but_monitor_unavailable(runtime, capsys):
    helper, engine = runtime
    statements = []
    event.listen(engine, 'before_cursor_execute', lambda conn, cursor, statement, *args: statements.append(statement))
    code, payload = result(helper, capsys)
    assert code == 0
    assert payload['code'] == 'RELEASE_READY_FUNDS_DISABLED'
    assert payload['monitor'] == 'UNAVAILABLE_NO_PROVIDER'
    assert all(s.lstrip().upper().startswith(('SELECT', 'PRAGMA')) for s in statements)


@pytest.mark.parametrize('heads', [[], ['0038_app_settings_text'], ['0041_wallet_operations', 'other']])
def test_missing_stale_or_multiple_heads_fail(runtime, capsys, heads):
    helper, engine = runtime
    with engine.begin() as connection:
        connection.execute(text('DELETE FROM alembic_version'))
        for head in heads:
            connection.execute(text('INSERT INTO alembic_version VALUES (:head)'), {'head': head})
    assert result(helper, capsys) == (1, {'code': 'MIGRATION_HEAD_MISMATCH', 'ready': False})


def test_absent_migration_table_fails(runtime, capsys):
    helper, engine = runtime
    with engine.begin() as connection:
        connection.execute(text('DROP TABLE alembic_version'))
    assert result(helper, capsys) == (1, {'code': 'MIGRATION_HEAD_MISMATCH', 'ready': False})


def test_database_connection_failure_is_safe(runtime, capsys):
    helper, engine = runtime
    def broken(connection):
        raise RuntimeError('sensitive-fixture-connection-string')
    event.listen(engine, 'engine_connect', broken)
    assert result(helper, capsys) == (1, {'code': 'DATABASE_CHECK_FAILED', 'ready': False})


@pytest.mark.parametrize('ddl', ['DROP TABLE wallet_incidents',
    'ALTER TABLE wallet_monitor_heartbeats DROP COLUMN external_delivery_configured',
    'DROP TABLE wallet_funding_scan_state',
    'DROP TABLE wallet_funding_scan_items',
    'DROP TABLE wallet_funding_coverage_events',
    'DROP TABLE ledger_manual_reserve_evaluations',
    'ALTER TABLE wallet_monitor_heartbeats DROP COLUMN last_error_code',
    'ALTER TABLE wallet_withdrawals DROP COLUMN admin_approver_id',
    'ALTER TABLE ledger_entries DROP COLUMN amount'])
def test_incomplete_schema_fails(runtime, capsys, ddl):
    helper, engine = runtime
    with engine.begin() as connection:
        connection.execute(text(ddl))
    assert result(helper, capsys) == (1, {'code': 'SCHEMA_INCOMPLETE', 'ready': False})


@pytest.mark.parametrize(('name', 'value', 'code'), [
    ('BUSINESS_JWT_SECRET', '', 'SETTINGS_INVALID'),
    ('BUSINESS_ENVIRONMENT', 'test', 'ENVIRONMENT_NOT_PRODUCTION'),
    ('BUSINESS_WALLET_CONVERSIONS_ENABLED', 'true', 'CONVERSIONS_ENABLED'),
])
def test_unsafe_configuration_fails(runtime, capsys, monkeypatch, name, value, code):
    helper, _ = runtime
    monkeypatch.setenv(name, value)
    assert result(helper, capsys) == (1, {'code': code, 'ready': False})


def test_active_provider_fails_without_calling_provider(runtime, capsys, monkeypatch):
    helper, _ = runtime
    monkeypatch.setattr(helper, 'create_custody_provider', lambda settings: (object(), 'production'))
    assert result(helper, capsys) == (1, {'code': 'FUNDING_PROVIDER_ENABLED', 'ready': False})


@pytest.mark.parametrize('dependency', ['Settings', 'create_engine', 'create_custody_provider'])
def test_exception_details_are_never_printed(runtime, capsys, monkeypatch, dependency):
    helper, _ = runtime
    def broken(*args, **kwargs):
        raise RuntimeError('sensitive-fixture-password-and-database-url')
    monkeypatch.setattr(helper, dependency, broken)
    code, payload = result(helper, capsys)
    assert code == 1
    assert payload['ready'] is False


def test_environment_file_is_explicitly_disabled(runtime, capsys, monkeypatch):
    helper, _ = runtime
    original = helper.Settings
    def checked(**kwargs):
        assert kwargs == {'_env_file': None}
        return original(**kwargs)
    monkeypatch.setattr(helper, 'Settings', checked)
    assert result(helper, capsys)[0] == 0


def test_manual_preflight_never_labels_enabled_funds_disabled(runtime, capsys, monkeypatch):
    helper, _ = runtime
    settings = SimpleNamespace(**helper.Settings(_env_file=None).model_dump())
    settings.wallet_real_mode = 'manual_tron'
    settings.wallet_real_funds_enabled = True
    monkeypatch.setattr(helper, 'Settings', lambda **kwargs: settings)
    assert result(helper, capsys) == (1, {'code': 'REAL_FUNDS_ENABLED', 'ready': False})


@pytest.mark.parametrize(('field', 'code'), [
    ('wallet_deposits_enabled', 'DEPOSITS_ENABLED'),
    ('wallet_payout_requests_enabled', 'PAYOUT_REQUESTS_ENABLED'),
    ('wallet_payout_execution_enabled', 'PAYOUT_EXECUTION_ENABLED'),
])
def test_independent_funds_gate_cannot_be_certified_disabled(
    runtime, capsys, monkeypatch, field, code,
):
    helper, _ = runtime
    settings = SimpleNamespace(**helper.Settings(_env_file=None).model_dump())
    settings.wallet_real_mode = 'manual_tron'
    settings.wallet_real_funds_enabled = False
    setattr(settings, field, True)
    monkeypatch.setattr(helper, 'Settings', lambda **kwargs: settings)
    assert result(helper, capsys) == (1, {'code': code, 'ready': False})


def test_manual_disabled_release_does_not_claim_monitor_acceptance(runtime, capsys, monkeypatch):
    helper, _ = runtime
    settings = SimpleNamespace(**helper.Settings(_env_file=None).model_dump())
    settings.wallet_real_mode = 'manual_tron'
    monkeypatch.setattr(helper, 'Settings', lambda **kwargs: settings)
    assert result(helper, capsys) == (0, {
        'code': 'RELEASE_READY_MANUAL_FUNDS_DISABLED', 'ready': True,
        'monitor': 'MANUAL_ACCEPTANCE_PENDING'})


@pytest.mark.parametrize('table', ['wallet_manual_control_commands', 'wallet_handover_preparations',
    'outbox_handover_dispositions', 'wallet_deposit_receipts'])
def test_manual_release_requires_new_schema(runtime, capsys, table):
    helper, engine = runtime
    with engine.begin() as connection:
        connection.execute(text('DROP TABLE ' + table))
    assert result(helper, capsys) == (1, {'code': 'SCHEMA_INCOMPLETE', 'ready': False})
