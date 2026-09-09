from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from test_moments_api import auth, ctx
from app.modules.moments.models import Moment, MomentsPreference, MomentNotification
from app.modules.moments.visibility import VisibilityPolicy
from app.modules.friendship.models import Friendship, UserBlock, ContactProfile


def seed(factory, days=10):
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(Moment(id='old', author_id='u1', text='private text', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key='old', created_at=now - timedelta(days=days)))
    return now


@pytest.mark.asyncio
async def test_range_belongs_to_author_not_viewer(ctx):
    app, settings = ctx
    now = seed(app.state.session_factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        prefs = {'history_range': 'THREE_DAYS', 'personalized_recommendations': True}
        await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u2'), json=prefs)
        for route in ['/feed?mode=latest', '/feed?mode=recommended', '/search?q=private', '/users/u1']:
            assert [x['id'] for x in (await client.get('/api/v1/moments' + route, headers=auth(settings, 'u2'))).json()['items']] == ['old']
        assert len((await client.get('/api/v1/moments/new-posts', params={'since': (now - timedelta(days=11)).isoformat()}, headers=auth(settings, 'u2'))).json()['items']) == 1
        await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u1'), json=prefs)
        assert (await client.get('/api/v1/moments/old', headers=auth(settings, 'u2'))).status_code == 404
        assert (await client.get('/api/v1/moments/users/u1', headers=auth(settings, 'u2'))).json()['items'] == []
        assert (await client.get('/api/v1/moments/old', headers=auth(settings, 'u1'))).status_code == 200


@pytest.mark.asyncio
@pytest.mark.parametrize('privacy', [{'profile_entry_enabled': False}, {'excluded_user_ids': ['u2']}])
async def test_privacy_blocks_all_foreign_routes_and_old_client_preserves(ctx, privacy):
    app, settings = ctx
    now = seed(app.state.session_factory, days=0)
    with app.state.session_factory.begin() as session:
        session.add(MomentNotification(id='notice', recipient_id='u2', moment_id='old', actor_id='u1', kind='COMMENT', created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        payload = {'history_range': 'ALL', 'personalized_recommendations': True}
        saved = await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u1'), json={**payload, **privacy})
        assert saved.status_code == 200, saved.text
        preserved = (await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u1'), json=payload)).json()
        for key, value in privacy.items():
            assert preserved[key] == value
        for viewer in ['u2', 'u3']:
            headers = {**auth(settings, viewer), 'Idempotency-Key': 'privacy-test'}
            for route in ['/feed', '/search?q=private', '/users/u1', '/notifications', '/new-posts?since=2020-01-01T00:00:00Z']:
                assert (await client.get('/api/v1/moments' + route, headers=headers)).json()['items'] == []
            assert (await client.get('/api/v1/moments/users/u1/preview', headers=headers)).json() == {'entry_visible': False, 'items': []}
            assert (await client.get('/api/v1/moments/old', headers=headers)).status_code == 404
            for suffix, body in [('/likes', None), ('/comments', {'text': 'hidden'}), ('/reports', {'reason_code': 'SPAM'})]:
                assert (await client.post('/api/v1/moments/old' + suffix, headers=headers, json=body)).status_code == 404
            assert (await client.delete('/api/v1/moments/old/likes', headers=headers)).status_code == 404
        assert (await client.get('/api/v1/moments/users/u1/preview', headers=auth(settings, 'u1'))).json()['entry_visible'] is True
        assert (await client.get('/api/v1/moments/old', headers=auth(settings, 'u1'))).status_code == 200


@pytest.mark.asyncio
async def test_preview_empty_authorized_and_filters_posts(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        assert (await client.get('/api/v1/moments/users/u1/preview', headers=auth(settings, 'u2'))).json() == {'entry_visible': True, 'items': []}
        for i in range(7):
            await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': str(i)}, json={'text': str(i), 'visibility': 'SELF' if i == 6 else 'FRIENDS'})
        preview = (await client.get('/api/v1/moments/users/u1/preview', headers=auth(settings, 'u2'))).json()
        assert [item['text'] for item in preview['items']] == ['5', '4', '3', '2']
        assert all(item['include_user_ids'] == [] and item['exclude_user_ids'] == [] for item in preview['items'])


@pytest.mark.asyncio
@pytest.mark.parametrize('invalid', [{'profile_entry_enabled': None}, {'profile_entry_enabled': 'false'}, {'excluded_user_ids': None}, {'excluded_user_ids': ['']}, {'excluded_user_ids': [1]}, {'excluded_user_ids': ['u3']}])
async def test_invalid_privacy_preferences(ctx, invalid):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u1'), json={'history_range': 'ALL', 'personalized_recommendations': True, **invalid})
        assert response.status_code == 422


@pytest.mark.parametrize('history,days', [('THREE_DAYS', 3), ('ONE_MONTH', 30), ('SIX_MONTHS', 183)])
def test_utc_range_boundary(ctx, history, days):
    app, _ = ctx
    now = seed(app.state.session_factory, days)
    with app.state.session_factory.begin() as session:
        session.add(MomentsPreference(user_id='u1', history_range=history, personalized_recommendations=True, updated_at=now))
    with app.state.session_factory() as session:
        policy = VisibilityPolicy(session, now=now)
        moment = session.get(Moment, 'old')
        assert policy.can_view('u2', moment)
        moment.created_at -= timedelta(microseconds=1)
        assert not policy.can_view('u2', moment)
        assert policy.can_view('u1', moment)


def test_privacy_openapi_documents_optional_inputs_and_preview(ctx):
    app, _ = ctx
    schema = app.openapi()
    preferences = schema['components']['schemas']['Preferences']
    assert 'profile_entry_enabled' not in preferences['required']
    assert 'excluded_user_ids' not in preferences['required']
    preview = schema['paths']['/api/v1/moments/users/{user_id}/preview']['get']['responses']['200']['content']['application/json']['schema']
    assert preview['$ref'].endswith('/MomentsProfilePreview')


@pytest.mark.asyncio
async def test_global_exclusion_is_directional_and_audience_lists_are_private(ctx):
    app, settings = ctx
    now = seed(app.state.session_factory, 0)
    with app.state.session_factory.begin() as session:
        session.add(Friendship(id='f13', user_low_id='u1', user_high_id='u3', created_at=now))
        moment = session.get(Moment, 'old')
        moment.visibility = 'EXCLUDE'
        moment.exclude_user_ids = ['u2']
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        saved = await client.put('/api/v1/moments/preferences', headers=auth(settings, 'u1'), json={'history_range': 'ALL', 'personalized_recommendations': False, 'excluded_user_ids': ['u2']})
        assert saved.status_code == 200
        other_friend = (await client.get('/api/v1/moments/users/u1/preview', headers=auth(settings, 'u3'))).json()
        assert other_friend['entry_visible'] is True
        assert other_friend['items'][0]['id'] == 'old'
        assert other_friend['items'][0]['exclude_user_ids'] == []
        own = (await client.get('/api/v1/moments/old', headers=auth(settings, 'u1'))).json()
        assert own['exclude_user_ids'] == ['u2']
        foreign_preferences = (await client.get('/api/v1/moments/preferences', headers=auth(settings, 'u3'))).json()
        assert foreign_preferences['excluded_user_ids'] == []


@pytest.mark.asyncio
@pytest.mark.parametrize('restriction', ['author_block', 'viewer_block', 'author_hide', 'viewer_hide'])
async def test_preview_respects_existing_relationship_restrictions(ctx, restriction):
    app, settings = ctx
    now = seed(app.state.session_factory, 0)
    owner, contact = ('u1', 'u2') if restriction.startswith('author') else ('u2', 'u1')
    with app.state.session_factory.begin() as session:
        if restriction.endswith('block'):
            session.add(UserBlock(id='block', blocker_id=owner, blocked_id=contact, idempotency_key='block', created_at=now))
        else:
            session.add(ContactProfile(id='hide', owner_id=owner, contact_id=contact, remark='', moments_permission='HIDE_MINE' if owner == 'u1' else 'HIDE_THEIRS'))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.get('/api/v1/moments/users/u1/preview', headers=auth(settings, 'u2'))
        assert response.json() == {'entry_visible': False, 'items': []}
