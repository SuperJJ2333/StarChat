from datetime import datetime, timezone
from decimal import Decimal

from httpx import ASGITransport, AsyncClient
import pytest

from test_admin_api import admin_app  # noqa: F401
from app.modules.ledger.models import LedgerEntry, LedgerTransaction


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
