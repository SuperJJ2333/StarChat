"""Recipient-only, paged Moments interaction history."""

import base64
import json
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete

from app.modules.friendship.models import Friendship
from app.modules.moments.models import Moment, MomentComment, MomentNotification, MomentsPreference
from test_moments_api import auth, ctx


def test_notification_page_openapi_declares_private_projection(ctx):
    app, _ = ctx
    schema = app.openapi()
    response = schema['paths']['/api/v1/moments/notifications']['get']['responses']['200']['content']['application/json']['schema']
    assert response['$ref'].endswith('/MomentNotificationsPage')
    page = schema['components']['schemas']['MomentNotificationsPage']
    assert {'items', 'next_cursor'} <= page['properties'].keys()
    row = schema['components']['schemas']['MomentNotificationRow']
    assert {'id', 'moment_id', 'comment_id', 'kind', 'actor', 'content_excerpt',
            'source_excerpt', 'target_available', 'created_at', 'read_at', 'unread'} <= row['properties'].keys()


@pytest.mark.asyncio
@pytest.mark.parametrize('malformed', [
    None, [], 7, {'created_at': None, 'id': 'x'},
    {'created_at': '2026-09-24T00:00:00', 'id': 'x'},
])
async def test_malformed_shared_keyset_cursor_is_422_for_notifications_and_feed(ctx, malformed):
    app, settings = ctx
    cursor = base64.urlsafe_b64encode(json.dumps(malformed).encode()).decode()
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for route in ['/api/v1/moments/notifications', '/api/v1/moments/feed?mode=latest']:
            response = await client.get(route, params={'cursor': cursor}, headers=auth(settings, 'u1'))
            assert response.status_code == 422


@pytest.mark.asyncio
async def test_reply_notifies_direct_parent_once_and_replay_is_idempotent(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'post'}, json={'text': 'post', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        route = f'/api/v1/moments/{moment_id}/comments'
        top = await client.post(route, headers={**auth(settings, 'u2'), 'Idempotency-Key': 'top'}, json={'text': 'top'})
        assert top.status_code == 201
        owner_reply = await client.post(route, headers={**auth(settings, 'u1'), 'Idempotency-Key': 'owner-reply'}, json={'text': 'owner reply', 'parent_id': top.json()['id']})
        assert owner_reply.status_code == 201
        assert (await client.post(route, headers={**auth(settings, 'u1'), 'Idempotency-Key': 'owner-reply'}, json={'text': 'owner reply', 'parent_id': top.json()['id']})).json()['id'] == owner_reply.json()['id']
        reader_reply = await client.post(route, headers={**auth(settings, 'u2'), 'Idempotency-Key': 'reader-reply'}, json={'text': 'reader reply', 'parent_id': owner_reply.json()['id']})
        assert reader_reply.status_code == 201
        own_reply = await client.post(route, headers={**auth(settings, 'u2'), 'Idempotency-Key': 'own-reply'}, json={'text': 'my follow-up', 'parent_id': top.json()['id']})
        assert own_reply.status_code == 201

        owner_rows = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))).json()['items']
        assert [(row['kind'], row['comment_id']) for row in owner_rows] == [('COMMENT', own_reply.json()['id']), ('REPLY', reader_reply.json()['id']), ('COMMENT', top.json()['id'])]
        reader_rows = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items']
        assert [(row['kind'], row['comment_id']) for row in reader_rows] == [('REPLY', owner_reply.json()['id'])]
        assert reader_rows[0]['content_excerpt'] == 'owner reply'
        assert reader_rows[0]['source_excerpt'] == 'post'


@pytest.mark.asyncio
async def test_reply_to_a_friend_comment_notifies_parent_and_post_author_separately(ctx):
    app, settings = ctx
    with app.state.session_factory.begin() as session:
        now = datetime.now(timezone.utc)
        session.add(Friendship(id='friend-13', user_low_id='u1', user_high_id='u3', created_at=now))
        session.add(Friendship(id='friend-23', user_low_id='u2', user_high_id='u3', created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        source = 'source  ' + 'a' * 100
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'third-party-post'}, json={'text': source, 'visibility': 'FRIENDS'})
        route = f"/api/v1/moments/{created.json()['id']}/comments"
        parent = await client.post(route, headers={**auth(settings, 'u2'), 'Idempotency-Key': 'third-party-parent'}, json={'text': 'parent'})
        reply = await client.post(route, headers={**auth(settings, 'u3'), 'Idempotency-Key': 'third-party-reply'}, json={'text': 'hello  \n  friend', 'parent_id': parent.json()['id']})
        assert reply.status_code == 201
        replay = await client.post(route, headers={**auth(settings, 'u3'), 'Idempotency-Key': 'third-party-reply'}, json={'text': 'hello  \n  friend', 'parent_id': parent.json()['id']})
        assert replay.json()['id'] == reply.json()['id']
        owner_rows = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))).json()['items']
        parent_rows = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items']
        assert [row['kind'] for row in owner_rows] == ['COMMENT', 'COMMENT']
        assert [row['kind'] for row in parent_rows] == ['REPLY']
        assert owner_rows[0]['content_excerpt'] == 'hello friend'
        assert parent_rows[0]['content_excerpt'] == 'hello friend'
        assert len(owner_rows[0]['source_excerpt']) == 80


@pytest.mark.asyncio
async def test_unpublished_moments_reject_likes_and_comments(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'pending'}, json={'text': 'pending', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        with app.state.session_factory.begin() as session:
            session.get(Moment, moment_id).status = 'PENDING_REVIEW'
        liked = await client.post(f'/api/v1/moments/{moment_id}/likes', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'like'})
        commented = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'comment'}, json={'text': 'hidden'})
        assert liked.status_code == 404
        assert commented.status_code == 404
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 0


@pytest.mark.asyncio
async def test_visible_image_only_interaction_has_safe_source_and_content_labels(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'image-only-post'}, json={'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        with app.state.session_factory.begin() as session:
            now = datetime.now(timezone.utc)
            session.add(MomentComment(id='image-comment', moment_id=moment_id, user_id='u2', text='', image_object_keys=['opaque-image'], idempotency_key='image-comment', created_at=now))
            session.add(MomentNotification(id='image-notice', recipient_id='u1', moment_id=moment_id, actor_id='u2', kind='COMMENT', comment_id='image-comment', created_at=now))
        row = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))).json()['items'][0]
        assert row['content_excerpt'] == '图片'
        assert row['source_excerpt'] == '动态'


@pytest.mark.asyncio
async def test_notification_keyset_is_stable_recipient_only_and_unread_is_unpaged(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'page-post'}, json={'text': 'source', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        for index in range(4):
            response = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': f'page-{index}'}, json={'text': f'comment {index}'})
            assert response.status_code == 201
        with app.state.session_factory.begin() as session:
            rows = session.query(MomentNotification).filter_by(recipient_id='u1').all()
            fixed = datetime(2026, 9, 24, tzinfo=timezone.utc)
            for row in rows:
                row.created_at = fixed
        first = (await client.get('/api/v1/moments/notifications?limit=2', headers=auth(settings, 'u1'))).json()
        assert len(first['items']) == 2 and first['next_cursor']
        assert all(row['unread'] is True for row in first['items'])
        second = (await client.get('/api/v1/moments/notifications', params={'limit': 2, 'cursor': first['next_cursor']}, headers=auth(settings, 'u1'))).json()
        assert len(second['items']) == 2 and second['next_cursor'] is None
        assert len({row['id'] for row in first['items'] + second['items']}) == 4
        assert [row['id'] for row in first['items'] + second['items']] == sorted((row['id'] for row in first['items'] + second['items']), reverse=True)
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 4
        assert (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u3'))).json()['items'] == []
        await client.post('/api/v1/moments/notifications/read', headers=auth(settings, 'u3'), json=[first['items'][0]['id']])
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 4
        invalid = await client.get('/api/v1/moments/notifications?limit=2&cursor=invalid', headers=auth(settings, 'u1'))
        assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_history_retained_with_generic_copy_after_revocation_delete_and_expiry(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'history-post'}, json={'text': 'secret source', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        comment = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'history-comment'}, json={'text': 'secret reply'})
        assert comment.status_code == 201
        before = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))).json()['items'][0]
        assert before['target_available'] is True
        assert before['content_excerpt'] == 'secret reply'
        assert before['source_excerpt'] == 'secret source'
        with app.state.session_factory.begin() as session:
            session.get(Moment, moment_id).deleted_at = datetime.now(timezone.utc)
        after = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u1'))).json()['items'][0]
        assert after['id'] == before['id'] and after['target_available'] is False
        assert after['content_excerpt'] is None and after['source_excerpt'] is None and after['actor'] is None
        assert 'secret' not in str(after)
        assert (await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u1'))).status_code == 404
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u1'))).json()['count'] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('visibility,include,exclude', [
    ('SELF', [], []), ('INCLUDE', ['u3'], []), ('EXCLUDE', [], ['u2']),
])
async def test_reply_history_is_generic_after_per_post_audience_revocation(ctx, visibility, include, exclude):
    app, settings = ctx
    if visibility == 'INCLUDE':
        with app.state.session_factory.begin() as session:
            session.add(Friendship(id='include-friend-13', user_low_id='u1', user_high_id='u3', created_at=datetime.now(timezone.utc)))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'audience-post'}, json={'text': 'private source', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        route = f'/api/v1/moments/{moment_id}/comments'
        parent = await client.post(route, headers={**auth(settings, 'u2'), 'Idempotency-Key': 'audience-parent'}, json={'text': 'my parent'})
        reply = await client.post(route, headers={**auth(settings, 'u1'), 'Idempotency-Key': 'audience-reply'}, json={'text': 'private reply', 'parent_id': parent.json()['id']})
        assert reply.status_code == 201
        notice = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items'][0]
        assert notice['target_available'] and notice['content_excerpt'] == 'private reply'
        changed = await client.patch(f'/api/v1/moments/{moment_id}/visibility', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'audience-change'}, json={'visibility': visibility, 'include_user_ids': include, 'exclude_user_ids': exclude})
        assert changed.status_code == 200, changed.text
        history = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items']
        assert len(history) == 1 and history[0]['id'] == notice['id']
        assert history[0]['actor'] is None and history[0]['content_excerpt'] is None
        assert history[0]['source_excerpt'] is None and not history[0]['target_available']
        assert 'private' not in str(history[0])
        assert (await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u2'))).status_code == 404
        assert (await client.get('/api/v1/moments/notifications/unread-count', headers=auth(settings, 'u2'))).json()['count'] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('history_range,days', [
    ('THREE_DAYS', 4), ('ONE_MONTH', 31), ('SIX_MONTHS', 184),
])
async def test_reply_recipient_loses_body_when_audience_or_history_expires(ctx, history_range, days):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'expiry-post'}, json={'text': 'private source', 'visibility': 'FRIENDS'})
        moment_id = created.json()['id']
        top = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u2'), 'Idempotency-Key': 'expiry-top'}, json={'text': 'parent'})
        reply = await client.post(f'/api/v1/moments/{moment_id}/comments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'expiry-reply'}, json={'text': 'private reply', 'parent_id': top.json()['id']})
        assert reply.status_code == 201
        visible = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items'][0]
        assert visible['content_excerpt'] == 'private reply'
        with app.state.session_factory.begin() as session:
            session.execute(delete(Friendship).where(Friendship.id == 'fixture-f12'))
        hidden = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items'][0]
        assert hidden['id'] == visible['id'] and hidden['target_available'] is False
        assert 'private' not in str(hidden)
        with app.state.session_factory.begin() as session:
            session.add(Friendship(id='fixture-f12-again', user_low_id='u1', user_high_id='u2', created_at=datetime.now(timezone.utc)))
            session.add(MomentsPreference(user_id='u1', history_range=history_range, personalized_recommendations=True, updated_at=datetime.now(timezone.utc)))
            session.get(Moment, moment_id).created_at = datetime.now(timezone.utc) - timedelta(days=days)
        expired = (await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))).json()['items'][0]
        assert expired['target_available'] is False and 'private' not in str(expired)
        assert (await client.get(f'/api/v1/moments/{moment_id}', headers=auth(settings, 'u2'))).status_code == 404
