from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import event

from test_review_flow_api import env, get  # noqa: F401
from app.modules.identity.models import User
from app.modules.recharge.models import RechargeRequest


@pytest.mark.parametrize('path', ['pending', '?status=REJECTED'])
def test_admin_orders_show_real_public_identity_in_one_batch(env, path):
    app, factory, _, headers = env
    with factory.begin() as session:
        user = session.get(User, 'alice')
        user.nickname = '真实昵称'
        user.username = 'chatflow_008'
    engine = factory.kw['bind']
    profile_queries = []

    def capture(_conn, _cursor, statement, _parameters, _context, _many):
        if 'FROM users' in statement and ' IN (' in statement:
            profile_queries.append(statement)

    event.listen(engine, 'before_cursor_execute', capture)
    try:
        suffix = '/' + path if path == 'pending' else path
        response = get(app, headers['agent'], '/api/v1/recharge/admin/requests' + suffix)
    finally:
        event.remove(engine, 'before_cursor_execute', capture)
    assert response.status_code == 200, response.text
    rows = response.json()['items']
    assert rows
    for row in rows:
        assert row['user_display_name'] == '真实昵称'
        assert row['user_chat_id'] == 'chatflow_008'
        assert not {'email', 'phone', 'password_hash'} & row.keys()
    assert len(profile_queries) == 1


def test_mine_scope_filters_before_pagination_and_uses_session_actor(env):
    app, factory, _, headers = env
    now = app.state.recharge_service._utcnow()
    with factory.begin() as session:
        for i, owner in enumerate(['agent', 'agent', 'root', None]):
            session.add(RechargeRequest(id=f'scope-{i}', user_id='alice',
                amount_usdt=Decimal('10'), status='SUBMITTED', claimed_by=owner,
                claim_expires_at=now + timedelta(minutes=10),
                created_at=now + timedelta(seconds=i), updated_at=now))
    url = '/api/v1/recharge/admin/requests/pending?scope=mine&limit=1'
    first = get(app, headers['agent'], url)
    assert first.status_code == 200, first.text
    page = first.json()
    assert [r['id'] for r in page['items']] == ['scope-1']
    assert page['next_cursor']
    second = get(app, headers['agent'], url + '&cursor=' + page['next_cursor'])
    assert [r['id'] for r in second.json()['items']] == ['scope-0']
    assert second.json()['next_cursor'] is None
    assert get(app, headers['alice'], url).status_code == 401
    assert get(app, headers['agent'], url.replace('scope=mine', 'scope=other')).status_code == 422


def test_missing_public_profile_is_not_invented_from_internal_id(env):
    app, _, _, _ = env
    class MissingProfiles:
        def read_public_profile_identities(self, ids):
            return {}
    app.state.recharge_service.profile_reader = MissingProfiles()
    row = app.state.recharge_service.pending_page()['items'][0]
    assert row['user_display_name'] is None
    assert row['user_chat_id'] is None
