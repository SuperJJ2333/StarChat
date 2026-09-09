from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete

from test_moments_api import auth, ctx
from app.main import create_app
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.friendship.models import Friendship, UserBlock, ContactProfile
from app.modules.moments.models import Moment, MomentComment, MomentLike, MomentsPreference
from app.modules.moments.service import MomentsService


@pytest.mark.asyncio
@pytest.mark.parametrize('revoke', ['stranger', 'removed', 'block', 'reverse_block', 'hidden', 'excluded', 'entry'])
async def test_viewer_relative_reactions_and_saved_comment_media(ctx, tmp_path, revoke):
    original, settings = ctx
    factory = original.state.session_factory
    now = datetime.now(timezone.utc)
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret='x' * 32, public_base_url='http://test')
    key = 'moments/u3/comment.png'
    storage.put(key, b'png')
    with factory.begin() as s:
        # Both interactors know the post author, but need not know each other.
        s.add(Friendship(id='f13', user_low_id='u1', user_high_id='u3', created_at=now))
        if revoke != 'stranger':
            s.add(Friendship(id='f23', user_low_id='u2', user_high_id='u3', created_at=now))
        s.add(Moment(id='post', author_id='u1', text='post', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key='post', created_at=now))
        for uid in ['u1', 'u2', 'u3']:
            s.add(MomentLike(id='like-' + uid, moment_id='post', user_id=uid, idempotency_key='like-' + uid, created_at=now))
            s.add(MomentComment(id='comment-' + uid, moment_id='post', user_id=uid, text=uid, image_object_keys=[key] if uid == 'u3' else [], idempotency_key='comment-' + uid, created_at=now))
        s.add(MomentComment(id='reply', moment_id='post', user_id='u1', parent_id='comment-u3', text='reply', image_object_keys=[], idempotency_key='reply', created_at=now))
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as c:
        headers = auth(settings, 'u2')
        before = (await c.get('/api/v1/moments/post', headers=headers)).json()
        if revoke != 'stranger':
            assert before['like_count'] == 3
            saved = next(row for row in before['comments'] if row['user_id'] == 'u3')['image_urls'][0]
            assert (await c.get(saved)).status_code == 200
        with factory.begin() as s:
            if revoke == 'removed':
                s.execute(delete(Friendship).where(Friendship.id == 'f23'))
            elif revoke in ('block', 'reverse_block'):
                blocker, blocked = ('u2', 'u3') if revoke == 'block' else ('u3', 'u2')
                s.add(UserBlock(id='block', blocker_id=blocker, blocked_id=blocked, idempotency_key='block', created_at=now))
            elif revoke == 'hidden':
                s.add(ContactProfile(id='hide', owner_id='u3', contact_id='u2', moments_permission='HIDE_MINE'))
            elif revoke in ('excluded', 'entry'):
                s.add(MomentsPreference(user_id='u3', history_range='ALL', personalized_recommendations=True, profile_entry_enabled=revoke != 'entry', excluded_user_ids=['u2'] if revoke == 'excluded' else [], updated_at=now))
        detail = (await c.get('/api/v1/moments/post', headers=headers)).json()
        feed = (await c.get('/api/v1/moments/feed', headers=headers)).json()['items'][0]
        personal = MomentsService(factory, avatar_storage=storage).personal_timeline('u2', 'u1')[0]
        for dto in [detail, feed, personal]:
            assert dto['like_count'] == 2
            assert {row['user_id'] for row in dto['like_users']} == {'u1', 'u2'}
            assert dto['viewer_has_liked'] is True
            assert dto['comment_count'] == 3
            assert {row['user_id'] for row in dto['comments']} == {'u1', 'u2'}
            reply = next(row for row in dto['comments'] if row['id'] == 'reply')
            assert reply['parent_author'] is None
            assert reply['parent_id'] is None
            assert all(datetime.fromisoformat(row['created_at']).tzinfo is not None for row in dto['comments'])
        if revoke != 'stranger':
            assert (await c.get(saved)).status_code == 404
        # Guessing a hidden parent ID must not reveal that person's identity.
        response = await c.post('/api/v1/moments/post/comments', headers={**headers, 'Idempotency-Key': 'hidden-reply'}, json={'text': 'reply', 'parent_id': 'comment-u3'})
        assert response.status_code == 404


def test_reaction_projection_batches_relationship_and_identity_queries(ctx):
    from sqlalchemy import event

    app, _ = ctx
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as s:
        s.add(Moment(id='post', author_id='u1', text='', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key='post', created_at=now))
        for i in range(80):
            s.add(MomentComment(id=f'c{i}', moment_id='post', user_id='u1', parent_id=f'c{i-1}' if i else None, text='reply', image_object_keys=[], idempotency_key=f'c{i}', created_at=now))
    statements = []
    engine = factory.kw['bind']
    def count(connection, cursor, statement, parameters, context, executemany):
        statements.append(statement)
    event.listen(engine, 'before_cursor_execute', count)
    try:
        dto = MomentsService(factory).detail('u2', 'post')
    finally:
        event.remove(engine, 'before_cursor_execute', count)
    assert dto['comment_count'] == 80
    assert len(statements) < 20


def test_all_visible_likers_are_returned_beyond_twenty(ctx):
    from app.modules.identity.models import User
    from app.modules.identity.enums import AccountStatus

    app, _ = ctx
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as s:
        s.add(Moment(id='post', author_id='u1', text='', visibility='FRIENDS', image_urls=[], status='PUBLISHED', idempotency_key='post', created_at=now))
        for i in range(25):
            uid = f'friend-{i:02d}'
            low, high = sorted(('u1', uid))
            s.add(User(id=uid, username=uid, username_normalized=uid, email=uid+'@x', email_normalized=uid+'@x', password_hash='x', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
            s.add(Friendship(id='f'+uid, user_low_id=low, user_high_id=high, created_at=now))
            s.add(MomentLike(id='l'+uid, moment_id='post', user_id=uid, idempotency_key='l'+uid, created_at=now))
    dto = MomentsService(factory).detail('u1', 'post')
    assert dto['like_count'] == 25
    assert len(dto['like_users']) == 25
