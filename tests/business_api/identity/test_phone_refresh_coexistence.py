"""Phone rollout must preserve the deployed mobile refresh operation contract."""
import base64

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.modules.identity.models import RefreshTokenFamily
from test_identity_api import api_components


@pytest.mark.asyncio
async def test_phone_routes_and_recoverable_refresh_share_same_live_router(api_components):
    app, factory = api_components
    op = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        # Protected route proves the new API is mounted without sending any SMS.
        missing_auth = await client.post('/api/v1/auth/phone/rebind/old-request')
        assert missing_auth.status_code == 401, missing_auth.text
        assert missing_auth.json()['error']['code'] == 'AUTH_REQUIRED'
        login = await client.post('/api/v1/auth/login', json=dict(username='active',
            password='correct horse battery staple', device_key='phone', device_name='Phone'))
        assert login.status_code == 200, login.text
        parent = login.json()['refresh_token']
        body = dict(refresh_token=parent, operation_id=op)
        first = await client.post('/api/v1/auth/refresh', json=body)
        retry = await client.post('/api/v1/auth/refresh', json=body)
        assert first.status_code == retry.status_code == 200
        assert first.json()['refresh_token'] == retry.json()['refresh_token']
        # Legacy requests still advance the result, and a stale operation cannot revoke it.
        current = await client.post('/api/v1/auth/refresh', json=dict(refresh_token=first.json()['refresh_token']))
        assert current.status_code == 200
        stale = await client.post('/api/v1/auth/refresh', json=body)
        assert stale.status_code == 409
        assert stale.json()['error']['code'] == 'REFRESH_RESULT_SUPERSEDED'
        privacy = await client.patch('/api/v1/auth/phone/privacy', json={'phone_findable': False},
            headers={'Authorization': 'Bearer ' + current.json()['access_token']})
        assert privacy.status_code == 200, privacy.text
        assert privacy.json() == {'phone_findable': False}
    with factory() as session:
        assert session.scalar(select(RefreshTokenFamily)).revoked_at is None
