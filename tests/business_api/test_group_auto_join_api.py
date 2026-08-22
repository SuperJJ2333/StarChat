import pytest
from httpx import ASGITransport, AsyncClient
from tests.business_api.friendship.test_friendship_api import ctx, bearer

@pytest.mark.asyncio
async def test_group_auto_join_preference_defaults_enabled_and_can_change(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        initial = await client.get('/api/v1/profile/privacy', headers=bearer(settings, 'u1'))
        assert initial.status_code == 200
        assert initial.json() == {'auto_allow_group_join': True}
        changed = await client.put('/api/v1/profile/privacy/auto-allow-group-join', headers=bearer(settings, 'u1'), json={'enabled': False})
        assert changed.status_code == 200
        assert changed.json() == {'auto_allow_group_join': False}

