"""API regressions for moderation of comments on one's own Moments."""

from datetime import datetime, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.moments.models import Moment, MomentComment, MomentNotification
from test_moments_api import auth, ctx  # noqa: F401


async def create_thread(client, settings):
    owner = {**auth(settings, "u1"), "Idempotency-Key": "post"}
    commenter = {**auth(settings, "u2"), "Idempotency-Key": "comment"}
    post = await client.post(
        "/api/v1/moments", headers=owner,
        json={"text": "post", "visibility": "FRIENDS"},
    )
    assert post.status_code == 201
    route = f"/api/v1/moments/{post.json()['id']}"
    comment = await client.post(
        f"{route}/comments", headers=commenter, json={"text": "comment"},
    )
    assert comment.status_code == 201
    reply = await client.post(
        f"{route}/comments", headers={**owner, "Idempotency-Key": "reply"},
        json={"text": "reply", "parent_id": comment.json()["id"]},
    )
    assert reply.status_code == 201
    return route, comment.json()["id"], reply.json()["id"]


def deletion_events(factory):
    with factory() as session:
        audits = session.scalars(select(AuditEvent).where(
            AuditEvent.action == "moment.comment_deleted",
        )).all()
        events = session.scalars(select(OutboxEvent).where(
            OutboxEvent.event_type == "moment.comment_deleted",
        )).all()
        return audits, events


@pytest.mark.asyncio
@pytest.mark.parametrize("actor", ["u1", "u2"])
async def test_author_or_commenter_can_delete_once_with_audit_and_safe_replies(ctx, actor):
    app, settings = ctx
    factory = app.state.session_factory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        route, comment_id, reply_id = await create_thread(client, settings)
        headers = {**auth(settings, actor), "Idempotency-Key": "delete-comment"}
        deleted = await client.delete(f"{route}/comments/{comment_id}", headers=headers)
        assert deleted.status_code == 204
        # Replays have the existing 404 contract and must not emit duplicate events.
        replay = await client.delete(f"{route}/comments/{comment_id}", headers=headers)
        assert replay.status_code == 404
        assert replay.json()["error"]["code"] == "COMMENT_NOT_FOUND"
        detail = await client.get(route, headers=auth(settings, "u1"))
        feed = await client.get("/api/v1/moments/feed", headers=auth(settings, "u1"))
        for dto in [detail.json(), feed.json()["items"][0]]:
            assert dto["comment_count"] == 1
            assert [row["id"] for row in dto["comments"]] == [reply_id]
            assert dto["comments"][0]["parent_id"] is None
            assert dto["comments"][0]["parent_author"] is None
        response = await client.post(
            f"{route}/comments", headers={**headers, "Idempotency-Key": "late-reply"},
            json={"text": "reply", "parent_id": comment_id},
        )
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "COMMENT_PARENT_NOT_FOUND"
    with factory() as session:
        deleted_row = session.get(MomentComment, comment_id)
        assert deleted_row.deleted_at is not None
        assert session.get(MomentComment, reply_id).deleted_at is None
        notifications = session.scalars(select(MomentNotification).where(
            MomentNotification.comment_id == comment_id,
        )).all()
        assert notifications
        assert all(row.invalidated_at == deleted_row.deleted_at for row in notifications)
    audits, events = deletion_events(factory)
    assert len(audits) == len(events) == 1
    assert audits[0].actor_id == actor
    assert audits[0].reason_code == "MOMENT_COMMENT_DELETE"
    assert audits[0].trace_id == "delete-comment"
    assert audits[0].subject_id == route.rsplit("/", 1)[1]
    assert events[0].payload == {"actor_id": actor}


@pytest.mark.asyncio
@pytest.mark.parametrize("case,status,code", [
    ("unrelated", 403, "COMMENT_DELETE_FORBIDDEN"),
    ("missing_comment", 404, "COMMENT_NOT_FOUND"),
    ("missing_moment", 404, "COMMENT_NOT_FOUND"),
    ("wrong_moment", 404, "COMMENT_NOT_FOUND"),
    ("deleted_moment", 404, "MOMENT_NOT_FOUND"),
    ("visibility_revoked", 404, "MOMENT_NOT_FOUND"),
])
async def test_comment_delete_rejects_invalid_targets_without_mutation(ctx, case, status, code):
    app, settings = ctx
    factory = app.state.session_factory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        route, comment_id, reply_id = await create_thread(client, settings)
        target = f"{route}/comments/{comment_id}"
        actor = "u3" if case == "unrelated" else "u2"
        if case == "missing_comment":
            target = f"{route}/comments/missing"
        elif case == "missing_moment":
            target = f"/api/v1/moments/missing/comments/{comment_id}"
        elif case == "wrong_moment":
            other = await client.post(
                "/api/v1/moments",
                headers={**auth(settings, "u2"), "Idempotency-Key": "other"},
                json={"visibility": "SELF"},
            )
            assert other.status_code == 201
            target = f"/api/v1/moments/{other.json()['id']}/comments/{comment_id}"
        elif case in ("deleted_moment", "visibility_revoked"):
            with factory.begin() as session:
                moment = session.get(Moment, route.rsplit("/", 1)[1])
                if case == "deleted_moment":
                    moment.deleted_at = datetime.now(timezone.utc)
                else:
                    moment.visibility = "SELF"
        response = await client.delete(
            target, headers={**auth(settings, actor), "Idempotency-Key": "denied"},
        )
        assert response.status_code == status
        assert response.json()["error"]["code"] == code
    with factory() as session:
        assert session.get(MomentComment, comment_id).deleted_at is None
        assert session.get(MomentComment, reply_id).deleted_at is None
        assert all(row.invalidated_at is None for row in session.scalars(
            select(MomentNotification).where(MomentNotification.comment_id == comment_id),
        ))
    assert deletion_events(factory) == ([], [])


@pytest.mark.asyncio
async def test_comment_delete_requires_authentication_and_idempotency_header(ctx):
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        route, comment_id, _ = await create_thread(client, settings)
        target = f"{route}/comments/{comment_id}"
        unauthenticated = await client.delete(target, headers={"Idempotency-Key": "delete"})
        assert unauthenticated.status_code == 401
        missing_key = await client.delete(target, headers=auth(settings, "u1"))
        assert missing_key.status_code == 422
    assert deletion_events(app.state.session_factory) == ([], [])
