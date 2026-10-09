"""Finance-only report access, export contract and audit boundaries."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.api.admin import create_admin_router
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.staff_activation import StaffActivation, staff_identity
from app.modules.wallet.service import WalletLedger


@pytest.fixture
def reports_http():
    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment='test', jwt_secret='test-' * 8)
    with factory.begin() as session:
        now = datetime.now(timezone.utc)
        user = User(id='finance', username='finance', username_normalized='finance',
            email='finance@example.test', email_normalized='finance@example.test',
            email_verified_at=now, password_hash='fixture', status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now)
        session.add(user)
        session.add(User(id='ordinary-user', username='ordinary', username_normalized='ordinary',
            email='ordinary@example.test', email_normalized='ordinary@example.test',
            password_hash='fixture', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(UserRole(id='finance-role', user_id='finance', role_code=RoleCode.FINANCE_SUPPORT,
            assigned_by='fixture', assigned_at=now))
        session.flush()
        _, _, digest = staff_identity(session, user)
        session.add(StaffActivation(user_id=user.id, identity_digest=digest, activated_at=now))
    WalletLedger(factory).post(entries={'report-user': Decimal('12.345678'),
        'PLATFORM_CUSTODY': Decimal('-12.345678')}, actor_id='fixture',
        reason_code='REPORT_TEST', scope='report-test', idempotency_key='seed')
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_admin_router(settings, factory), prefix='/api/v1')
    def headers(user, scope='admin'):
        now = datetime.now(timezone.utc)
        token = jwt.encode({'sub': user, 'iss': settings.jwt_issuer,
            'iat': now, 'exp': now + timedelta(minutes=5), 'session_scope': scope}, settings.jwt_secret, algorithm='HS256')
        return {'Authorization': 'Bearer ' + token}
    yield TestClient(app), headers, factory
    engine.dispose()


def day_query():
    # A current Hong Kong day may be incomplete, so it is explicitly a preview.
    day = (datetime.now(timezone.utc) + timedelta(hours=8)).date()
    return f'/api/v1/admin/wallet/reports/daily?day={day.isoformat()}'


def test_reports_require_auth_and_finance_permission(reports_http):
    client, headers, _ = reports_http
    for response, status in [(client.get(day_query()), 401),
                             (client.get(day_query(), headers=headers('ordinary-user')), 403)]:
        assert response.status_code == status
        assert response.headers['cache-control'] == 'no-store'


def test_report_has_decimal_evidence_and_audit(reports_http):
    client, headers, factory = reports_http
    response = client.get(day_query(), headers=headers('finance'))
    assert response.status_code == 200
    report = response.json()
    assert report['finalized'] is False
    assert len(report['digest']) == 64
    assert '12.345678' in response.text
    assert response.headers['cache-control'] == 'no-store'
    with factory() as session:
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == 'wallet.report.viewed'))
        assert audit is not None and audit.actor_id == 'finance'
        assert audit.after_data['digest'] == report['digest']


def test_reports_reject_app_session_and_revoked_activation(reports_http):
    client, headers, factory = reports_http
    assert client.get(day_query(), headers=headers('finance', scope='app')).status_code == 403
    with factory.begin() as session:
        session.delete(session.get(StaffActivation, 'finance'))
    assert client.get(day_query(), headers=headers('finance')).status_code == 403
    with factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == 'wallet.report.viewed')) is None


def test_csv_export_is_audited_attachment(reports_http):
    client, headers, factory = reports_http
    response = client.get(day_query() + '&format=csv', headers=headers('finance'))
    assert response.status_code == 200
    assert response.headers['content-type'].startswith('text/csv')
    assert 'attachment;' in response.headers['content-disposition']
    assert response.headers['cache-control'] == 'no-store'
    assert '12.345678' in response.text
    with factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == 'wallet.report.exported'))


@pytest.mark.parametrize('query', ['day=invalid', 'day=2999-01-01', 'day=2026-01-01&format=xlsx'])
def test_invalid_report_parameters(reports_http, query):
    client, headers, _ = reports_http
    response = client.get('/api/v1/admin/wallet/reports/daily?' + query, headers=headers('finance'))
    assert response.status_code == 422
    assert response.headers['cache-control'] == 'no-store'


def test_report_refuses_oversize_without_partial_export(reports_http, monkeypatch):
    from app.modules.wallet.reporting import WalletReportService
    client, headers, factory = reports_http
    def oversized(self, day):
        raise OverflowError('fixture cap')
    monkeypatch.setattr(WalletReportService, 'daily', oversized)
    response = client.get(day_query() + '&format=csv', headers=headers('finance'))
    assert response.status_code == 413
    assert response.headers['cache-control'] == 'no-store'
    assert response.json()['error']['code'] == 'WALLET_REPORT_TOO_LARGE'
    with factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == 'wallet.report.exported')) is None


def test_corrupt_asset_is_not_mislabeled_as_bad_request_date(reports_http):
    from sqlalchemy import update
    from app.modules.wallet.models import WalletLedgerEntry
    client, headers, factory = reports_http
    with factory.begin() as session:
        session.execute(update(WalletLedgerEntry).values(asset='CORRUPT'))
    response = client.get(day_query(), headers=headers('finance'))
    assert response.status_code == 409
    assert response.headers['cache-control'] == 'no-store'
    assert response.json()['error']['code'] == 'WALLET_REPORT_DATA_INVALID'
