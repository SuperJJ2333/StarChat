"""Five-account API privacy contract, including historical interaction metadata."""
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete

from test_moments_api import auth, ctx
from app.modules.friendship.models import Friendship
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.moments.models import Moment, MomentComment, MomentLike, MomentNotification


def seed_audience(factory):
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        # A=u2, B=u1, C=u3, D=u4, E=u5. A/B already friends.
        for uid in ['u4', 'u5']:
            session.add(User(id=uid, username=uid, username_normalized=uid,
                nickname='name-' + uid, email=uid + '@x', email_normalized=uid + '@x',
                password_hash='x', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        for left, right in [('u1', 'u3'), ('u1', 'u4'), ('u2', 'u4')]:
            session.add(Friendship(id=left + right, user_low_id=left,
                user_high_id=right, created_at=now))
        for number in range(2):
            mid = f'post-{number}'
            session.add(Moment(id=mid, author_id='u1', text='audience', visibility='FRIENDS',
                image_urls=[], status='PUBLISHED', idempotency_key=mid,
                created_at=now + timedelta(seconds=number)))
            for uid in ['u1', 'u2', 'u3', 'u4', 'u5']:
                cid = mid + uid
                session.add(MomentComment(id=cid, moment_id=mid, user_id=uid,
                    text='body-' + uid, image_object_keys=[], idempotency_key=cid,
                    created_at=now))
                session.add(MomentLike(id=cid, moment_id=mid, user_id=uid,
                    idempotency_key=cid, created_at=now))
                # Includes legacy rows; recipient ACL must not disclose hidden actors.
                session.add(MomentNotification(id=cid, recipient_id='u2', moment_id=mid,
                    actor_id=uid, kind='COMMENT', comment_id=cid, created_at=now))
            session.add(MomentComment(id=mid + '-reply', moment_id=mid, user_id='u4',
                parent_id=mid + 'u3', text='safe-reply', image_object_keys=[],
                idempotency_key=mid + '-reply', created_at=now))


def assert_filtered(dto, visible):
    assert {row['user_id'] for row in dto['comments']} == visible
    assert {row['user_id'] for row in dto['like_users']} == visible
    assert dto['like_count'] == len(visible)
    assert dto['comment_count'] == len(visible) + ('u4' in visible)
    for row in dto['comments']:
        if row['id'].endswith('-reply'):
            assert row['parent_id'] is None
            assert row['parent_author'] is None
    serialized = str(dto)
    for hidden in {'u3', 'u5'}:
        assert hidden not in serialized


@pytest.mark.asyncio
async def test_five_accounts_all_read_paths_pagination_and_reply_mutation(ctx):
    app, settings = ctx
    seed_audience(app.state.session_factory)
    headers = auth(settings, 'u2')
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for route in ['/feed?mode=latest', '/feed?mode=recommended', '/search?q=audience',
                      '/users/u1', '/users/u1/preview']:
            response = await client.get('/api/v1/moments' + route, headers=headers)
            assert response.status_code == 200
            for dto in response.json()['items']:
                assert_filtered(dto, {'u1', 'u2', 'u4'})
        first = (await client.get('/api/v1/moments/feed?mode=latest&limit=1', headers=headers)).json()
        second = (await client.get('/api/v1/moments/feed', headers=headers,
            params={'mode': 'latest', 'limit': 1, 'cursor': first['next_cursor']})).json()
        assert first['items'][0]['id'] != second['items'][0]['id']
        assert second['next_cursor'] is None
        for dto in first['items'] + second['items']:
            assert_filtered(dto, {'u1', 'u2', 'u4'})
        for hidden in ['u3', 'u5']:
            reply = await client.post('/api/v1/moments/post-0/comments',
                headers={**headers, 'Idempotency-Key': 'reply-' + hidden},
                json={'text': 'reply', 'parent_id': 'post-0' + hidden})
            assert reply.status_code == 404
        own = (await client.get('/api/v1/moments/post-0', headers=auth(settings, 'u1'))).json()
        assert {row['user_id'] for row in own['comments']} == {'u1', 'u2', 'u3', 'u4'}
        assert next(row for row in own['comments'] if row['id'].endswith('-reply'))['parent_author']['user_id'] == 'u3'


@pytest.mark.asyncio
async def test_hidden_notification_actor_and_unread_count_use_reaction_policy(ctx):
    app, settings = ctx
    seed_audience(app.state.session_factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        headers = auth(settings, 'u2')
        response = await client.get('/api/v1/moments/notifications', headers=headers)
        assert {row['actor']['user_id'] for row in response.json()['items']} == {'u1', 'u2', 'u4'}
        count = await client.get('/api/v1/moments/notifications/unread-count', headers=headers)
        assert count.json()['count'] == 6
        with app.state.session_factory.begin() as session:
            session.execute(delete(Friendship).where(Friendship.id == 'u2u4'))
        response = await client.get('/api/v1/moments/notifications', headers=headers)
        assert {row['actor']['user_id'] for row in response.json()['items']} == {'u1', 'u2'}
        count = await client.get('/api/v1/moments/notifications/unread-count', headers=headers)
        assert count.json()['count'] == 4
        detail = (await client.get('/api/v1/moments/post-0', headers=headers)).json()
        assert_filtered(detail, {'u1', 'u2'})


@pytest.mark.asyncio
async def test_former_author_friend_hidden_in_reads_and_replayed_reply(ctx):
    app, settings = ctx
    seed_audience(app.state.session_factory)
    headers = {**auth(settings, 'u2'), 'Idempotency-Key': 'existing-reply'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        route = '/api/v1/moments/post-0/comments'
        body = {'text': 'own-safe-reply', 'parent_id': 'post-0u4'}
        before = await client.post(route, headers=headers, json=body)
        assert before.status_code == 201
        assert before.json()['parent_author']['user_id'] == 'u4'
        with app.state.session_factory.begin() as session:
            session.execute(delete(Friendship).where(Friendship.id == 'u1u4'))
        detail = (await client.get('/api/v1/moments/post-0', headers=headers)).json()
        assert {row['user_id'] for row in detail['comments']} == {'u1', 'u2'}
        # This is a comment-only policy change: preserve existing like semantics.
        assert {row['user_id'] for row in detail['like_users']} == {'u1', 'u2', 'u4'}
        replay = await client.post(route, headers=headers, json=body)
        assert replay.status_code == 201
        assert replay.json()['id'] == before.json()['id']
        assert replay.json()['parent_id'] is None
        assert replay.json()['parent_author'] is None
        denied = await client.post(route,
            headers={**headers, 'Idempotency-Key': 'new-reply'}, json=body)
        assert denied.status_code == 404


@pytest.mark.asyncio
async def test_like_notifications_preserve_original_post_visibility_policy(ctx):
    app, settings = ctx
    seed_audience(app.state.session_factory)
    with app.state.session_factory.begin() as session:
        session.add(MomentNotification(id='legacy-like', recipient_id='u2',
            moment_id='post-0', actor_id='u5', kind='LIKE',
            created_at=datetime.now(timezone.utc)))
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.get('/api/v1/moments/notifications', headers=auth(settings, 'u2'))
        likes = [row for row in response.json()['items'] if row['kind'] == 'LIKE']
        assert [row['actor']['user_id'] for row in likes] == ['u5']
