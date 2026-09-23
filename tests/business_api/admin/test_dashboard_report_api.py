from datetime import datetime, timezone
from decimal import Decimal

from httpx import ASGITransport, AsyncClient
import pytest

from test_admin_api import admin_app  # noqa: F401
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.identity.models import UserRole
from app.modules.identity.enums import RoleCode
from app.modules.identity.staff_activation import StaffActivation, staff_identity
from app.modules.identity.models import User
from sqlalchemy import select


@pytest.mark.asyncio
@pytest.mark.parametrize('role', [RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_AGENT])
async def test_activated_staff_share_aggregate_overview_without_admin_module_access(admin_app, role):
    app, admin_token, staff_token = admin_app
    with app.state.session_factory.begin() as session:
        session.scalar(select(UserRole).where(UserRole.user_id == 'finance-1')).role_code = role
        session.flush()
        _, _, digest = staff_identity(session, session.get(User, 'finance-1'))
        session.get(StaffActivation, 'finance-1').identity_digest = digest
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        admin = await client.get('/api/v1/admin/overview', headers={'Authorization':f'Bearer {admin_token}'})
        headers = {'Authorization':f'Bearer {staff_token}'}
        overview = await client.get('/api/v1/admin/overview', headers=headers)
        context = await client.get('/api/v1/admin/context', headers=headers)
        settings = await client.get('/api/v1/admin/app-update-settings', headers=headers)
        detail = await client.get('/api/v1/admin/point-issuance', headers=headers)
    assert overview.status_code == 200, overview.text
    def metrics(value):
        data = value.copy()
        data["point_supply"] = data["point_supply"].copy()
        datetime.fromisoformat(data["point_supply"].pop("as_of"))
        return data
    assert metrics(overview.json()) == metrics(admin.json())
    assert context.status_code == 200, context.text
    assert metrics(context.json()['overview']) == metrics(admin.json())
    assert 'admin.overview.read' in context.json()['permissions']
    assert '*' not in context.json()['permissions']
    assert 'wallet' not in context.json()['modules']
    assert settings.status_code == detail.status_code == 403


@pytest.mark.asyncio
async def test_staff_overview_rechecks_activation_and_rejects_regular_app_session(admin_app):
    from app.modules.identity.tokens import TokenService
    app, _, staff_token = admin_app
    from app.core.config import Settings
    settings = Settings(_env_file=None, environment="test", jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    tokens = TokenService(app.state.session_factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    pair = tokens.issue_pair(user_id='finance-1', device_key='app-only', display_name='app')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        app_response = await client.get('/api/v1/admin/overview', headers={'Authorization':f'Bearer {pair.access_token}'})
        with app.state.session_factory.begin() as session:
            session.delete(session.get(StaffActivation, 'finance-1'))
        denied = await client.get('/api/v1/admin/overview', headers={'Authorization':f'Bearer {staff_token}'})
    assert app_response.status_code in (401, 403)
    assert denied.status_code == 403


@pytest.mark.asyncio
async def test_overview_report_contract_days_context_and_caibi_volume(admin_app):
    app, token, _ = admin_app
    now = datetime.now(timezone.utc)
    with app.state.session_factory.begin() as session:
        session.add(LedgerTransaction(id='usdt-volume', asset='USDT', scope='test', idempotency_key='usdt',
            actor_id='admin-1', reason_code='TEST', created_at=now))
        session.add(LedgerEntry(id='usdt-entry', transaction_id='usdt-volume', asset='USDT',
            account_id='u1', amount=Decimal('17'), created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test',
            headers={'Authorization': f'Bearer {token}'}) as client:
        response = await client.get('/api/v1/admin/overview?days=7')
        context = await client.get('/api/v1/admin/context')
        invalid = await client.get('/api/v1/admin/overview?days=8')
    assert response.status_code == 200
    assert len(response.json()['registration_trend']) == 7
    assert response.json()['registration_timezone'] == 'Asia/Hong_Kong'
    assert response.json()['registration_today_partial'] is True
    assert response.json()['today_point_volume'] == '0.00'
    assert response.json()['point_supply']['total'] == '0.00'
    assert len(context.json()['overview']['registration_trend']) == 30
    assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_issuance_route_permission_pagination_validation_and_missing_detail(admin_app):
    app, token, finance = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        denied = await client.get('/api/v1/admin/point-issuance', headers={'Authorization': f'Bearer {finance}'})
        headers = {'Authorization': f'Bearer {token}'}
        empty = await client.get('/api/v1/admin/point-issuance', headers=headers)
        detail = await client.get('/api/v1/admin/point-issuance/missing', headers=headers)
        bad_cursor = await client.get('/api/v1/admin/point-issuance?cursor=bad', headers=headers)
        bad_limit = await client.get('/api/v1/admin/point-issuance?limit=101', headers=headers)
    assert denied.status_code == 403
    assert empty.status_code == 200 and empty.json() == {'items': [], 'next_cursor': None}
    assert detail.status_code == 404
    assert bad_cursor.status_code == bad_limit.status_code == 422
