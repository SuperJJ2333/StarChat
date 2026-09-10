"""Read-only administrator user records: permissions, literal search and cursors."""
from datetime import datetime, timezone
import base64
import json
import hashlib

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import event

from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.ledger.supply_reports import issuance_page, issuance_detail
from test_admin_api import admin_app as admin_app
from test_dashboard_reports import factory as factory, post


def seed(factory, *, count=5):
    stamp = datetime(2026, 9, 10, 1, 2, 3, tzinfo=timezone.utc)
    with factory.begin() as session:
        for i in range(count):
            session.add(User(id=f'record-{i:03}', username=f'handle{i:03}', username_normalized=f'handle{i:03}',
                nickname=f'用户{i}', email=f'private{i}@example.test', email_normalized=f'private{i}@example.test',
                password_hash='never-expose', status=AccountStatus.ACTIVE, email_verified_at=stamp if i else None,
                created_at=stamp, updated_at=stamp))


@pytest.mark.asyncio
@pytest.mark.parametrize('module', ['security', 'analytics'])
async def test_user_pages_ties_total_safe_fields_and_utc(admin_app, module):
    app, token, _ = admin_app
    seed(app.state.session_factory)
    found, cursor = [], None
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test',
            headers={'Authorization': f'Bearer {token}'}) as client:
        for _ in range(3):
            params = {'q': 'handle', 'limit': 2}
            if cursor:
                params['cursor'] = cursor
            response = await client.get(f'/api/v1/admin/modules/{module}', params=params)
            assert response.status_code == 200
            body = response.json()
            assert body['total'] == 5
            found.extend(body['items'])
            cursor = body['next_cursor']
    assert [u['id'] for u in found] == [f'record-{i:03}' for i in range(4, -1, -1)]
    assert cursor is None
    assert found[0]['nickname'] == '用户4'
    assert found[0]['created_at'] == '2026-09-10T01:02:03+00:00'
    assert found[0]['email_verified_at'] == '2026-09-10T01:02:03+00:00'
    assert found[-1]['email_verified_at'] is None
    assert 'updated_at' in found[0]
    assert not {'email', 'email_normalized', 'password_hash', 'matrix_user_id'} & found[0].keys()


@pytest.mark.asyncio
@pytest.mark.parametrize('query,expected', [('HANDLE002', 'record-002'), ('用户3', 'record-003'),
    ('PRIVATE4@EXAMPLE.TEST', 'record-004'), ('%_\\', 'literal')])
async def test_search_username_nickname_email_and_literal_wildcards(admin_app, query, expected):
    app, token, _ = admin_app
    seed(app.state.session_factory)
    with app.state.session_factory.begin() as session:
        stamp = datetime.now(timezone.utc)
        session.add(User(id='literal', username='literal%_\\', username_normalized='literal%_\\', nickname='literal',
            email='literal@example.test', email_normalized='literal@example.test', password_hash='hidden',
            status=AccountStatus.ACTIVE, created_at=stamp, updated_at=stamp))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test',
            headers={'Authorization': f'Bearer {token}'}) as client:
        response = await client.get('/api/v1/admin/modules/security', params={'q': query})
    assert response.status_code == 200
    assert [u['id'] for u in response.json()['items']] == [expected]
    assert response.json()['total'] == 1


@pytest.mark.asyncio
async def test_search_rbac_invalid_cursor_limit_and_legacy_context(admin_app):
    app, token, finance = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for module in ['security', 'analytics']:
            path = f'/api/v1/admin/modules/{module}'
            assert (await client.get(path, params={'q': 'private'})).status_code == 401
            assert (await client.get(path, params={'q': 'private'}, headers={'Authorization': f'Bearer {finance}'})).status_code == 403
            for params in [{'cursor': 'bad'}, {'limit': 0}, {'limit': 101}, {'q': 'x'*129}]:
                assert (await client.get(path, params=params, headers={'Authorization': f'Bearer {token}'})).status_code == 422
        context = await client.get('/api/v1/admin/context', headers={'Authorization': f'Bearer {token}'})
        legacy = await client.get('/api/v1/admin/modules/security', headers={'Authorization': f'Bearer {token}'})
    assert context.status_code == legacy.status_code == 200
    assert len(legacy.json()['items']) == 3
    assert legacy.json()['total'] == 3


def test_issuance_actor_names_are_batched_and_raw_ids_preserved(factory):
    seed(factory, count=1)
    with factory.begin() as session:
        for i in range(4):
            post(session, f'issue-{i}', [('PLATFORM_CLEARING', '-1'), ('u', '1')])
        operator = session.get(User, 'record-000')
        operator.id = 'operator'
    selects = []
    def record(conn, cursor, statement, parameters, context, executemany):
        if 'FROM users' in statement:
            selects.append(statement)
    engine = factory.kw['bind']
    event.listen(engine, 'before_cursor_execute', record)
    try:
        with factory() as session:
            page = issuance_page(session)
    finally:
        event.remove(engine, 'before_cursor_execute', record)
    assert len(selects) == 1
    assert all(item['actor_id'] == 'operator' and item['actor_username'] == 'handle000'
        and item['actor_display_name'] == '用户0' for item in page['items'])
    with factory() as session:
        detail = issuance_detail(session, 'issue-0')
    assert detail['audits'][0]['actor_id'] == 'operator'
    assert detail['audits'][0]['actor_display_name'] == '用户0'
    assert detail['amount'] == '1.00'


def test_system_actor_projection_is_nullable_and_keeps_raw_id(factory):
    with factory.begin() as session:
        post(session, 'system', [('PLATFORM_CLEARING', '-1'), ('u', '1')])
    with factory() as session:
        detail = issuance_detail(session, 'system')
    assert detail['actor_id'] == 'operator'
    assert detail['actor_username'] is None and detail['actor_display_name'] is None


def test_default_user_page_reaches_beyond_old_hundred_row_limit(factory):
    from app.modules.admin.user_reports import user_page
    seed(factory, count=105)
    with factory() as session:
        first = user_page(session)
        second = user_page(session, cursor=first['next_cursor'])
    assert len(first['items']) == 100 and len(second['items']) == 5
    assert first['total'] == second['total'] == 105
    assert second['next_cursor'] is None
    assert not ({u['id'] for u in first['items']} & {u['id'] for u in second['items']})


def test_cursor_binds_search_without_copying_email_search_into_token(factory):
    from app.modules.admin.user_reports import user_page
    seed(factory)
    with factory() as session:
        first = user_page(session, q='@example.test', limit=1)
        assert '@example.test' not in base64.urlsafe_b64decode(first['next_cursor']).decode()
        with pytest.raises(ValueError, match='cursor'):
            user_page(session, q='different', cursor=first['next_cursor'])


@pytest.mark.parametrize('value', [['2026-09-10T01:02:03', 'id', ''],
    ['2026-09-10T01:02:03+00:00', '', ''], {'id': 'bad'}, [None, 'id', '']])
def test_malformed_and_naive_cursor_rejected(factory, value):
    from app.modules.admin.user_reports import user_page
    cursor = base64.urlsafe_b64encode(json.dumps(value).encode()).decode()
    with factory() as session, pytest.raises(ValueError, match='cursor'):
        user_page(session, cursor=cursor)


@pytest.mark.asyncio
@pytest.mark.parametrize('module', ['security', 'analytics'])
@pytest.mark.parametrize('timestamp', ['0001-01-01T00:00:00+14:00',
    '9999-12-31T23:59:59-14:00', 'invalid-timestamp'])
async def test_extreme_and_corrupt_cursor_returns_safe_422(admin_app, module, timestamp):
    app, token, _ = admin_app
    cursor = base64.urlsafe_b64encode(json.dumps([
        timestamp, 'record-000', hashlib.sha256(b'').hexdigest()
    ]).encode()).decode()
    async with AsyncClient(transport=ASGITransport(app=app, raise_app_exceptions=False),
            base_url='http://test', headers={'Authorization': f'Bearer {token}'}) as client:
        response = await client.get(f'/api/v1/admin/modules/{module}', params={'cursor': cursor})
    assert response.status_code == 422
    assert response.json()['error']['code'] == 'ADMIN_USER_FILTER_INVALID'
    assert timestamp not in response.text
