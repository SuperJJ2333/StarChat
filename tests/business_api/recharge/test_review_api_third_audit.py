"""HTTP boundary checks for review identity and stale operator actions."""
from test_review_flow_api import env, get, post


def test_review_requires_binding_identity(env):
    app, factory, ledger, headers = env
    result = post(app, headers['agent'], '/api/v1/recharge/admin/requests/req-nr/review',
        {'action': 'retry'})
    assert result.status_code == 422


def test_stale_review_binding_is_rejected(env):
    app, factory, ledger, headers = env
    result = post(app, headers['agent'], '/api/v1/recharge/admin/requests/req-nr/review',
        {'action': 'retry', 'binding_id': 'previous-binding'})
    assert result.status_code == 409
    assert result.json()['error']['code'] == 'RECHARGE_BINDING_CHANGED'


def test_review_queue_rejects_invalid_cursor(env):
    app, factory, ledger, headers = env
    result = get(app, headers['agent'], '/api/v1/recharge/admin/review-queue?cursor=not-a-cursor')
    assert result.status_code == 400


def test_review_requires_http_idempotency_header(env):
    import asyncio
    from httpx import ASGITransport, AsyncClient
    app, factory, ledger, headers = env
    async def call():
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            return await client.post('/api/v1/recharge/admin/requests/req-nr/review',
                headers=headers['agent'], json={'action':'retry','binding_id':'bind-nr'})
    result = asyncio.run(call())
    assert result.status_code == 422
    assert any(field['loc'] == ['header','Idempotency-Key'] for field in result.json()['error']['fields'])
