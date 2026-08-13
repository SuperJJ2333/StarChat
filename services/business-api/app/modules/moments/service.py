from datetime import datetime, timedelta, timezone
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.moments.models import (
    Moment,
    MomentComment,
    MomentLike,
    MomentReport,
    MomentsPreference,
)
from app.modules.moments.visibility import VisibilityPolicy
from app.modules.moments.recommendation import recommendation_score


class MomentsService:
    def __init__(self, factory):
        self.factory = factory

    @staticmethod
    def _audit(session, actor: str, moment_id: str, action: str, reason: str, key: str) -> None:
        now = datetime.now(timezone.utc)
        session.add(AuditEvent(
            id=str(uuid4()), actor_id=actor, subject_type="moment", subject_id=moment_id,
            action=action, result="SUCCESS", reason_code=reason, trace_id=key[:128], created_at=now,
        ))
        OutboxPublisher.enqueue(
            session, topic="moments.events", event_type=action, aggregate_type="moment",
            aggregate_id=moment_id, payload={"actor_id": actor}, now=now,
        )

    def create(self, actor, data, key):
        if len(data.get("image_urls", [])) > 9:
            raise AppError(code="MOMENT_IMAGE_LIMIT", message="最多上传9张图片", status_code=422)
        with self.factory.begin() as session:
            old = session.scalar(select(Moment).where(Moment.author_id == actor, Moment.idempotency_key == key))
            if old:
                return old
            now = datetime.now(timezone.utc)
            row = Moment(
                id=str(uuid4()), author_id=actor, text=data.get("text", ""), visibility=data["visibility"],
                image_urls=data.get("image_urls", []), include_user_ids=data.get("include_user_ids", []),
                exclude_user_ids=data.get("exclude_user_ids", []), location=data.get("location"),
                link_url=data.get("link_url"), status="PENDING_REVIEW" if data.get("image_urls") else "PUBLISHED", idempotency_key=key, created_at=now,
            )
            session.add(row)
            self._audit(session, actor, row.id, "moment.published", "MOMENT_PUBLISH", key)
            return row

    def feed(self, actor, q=None, mode="latest"):
        with self.factory() as session:
            preference = session.get(MomentsPreference, actor)
            cutoff = None
            if preference and preference.history_range != "ALL":
                cutoff = datetime.now(timezone.utc) - {
                    "THREE_DAYS": timedelta(days=3), "ONE_MONTH": timedelta(days=30),
                    "SIX_MONTHS": timedelta(days=183),
                }[preference.history_range]
            rows = session.scalars(
                select(Moment).where(Moment.deleted_at.is_(None), Moment.status == "PUBLISHED")
                .order_by(Moment.created_at.desc(), Moment.id.desc()).limit(50)
            ).all()
            policy = VisibilityPolicy(session)
            visible = [
                self.dto(session, moment) for moment in rows
                if policy.can_view(actor, moment)
                and (cutoff is None or moment.created_at >= cutoff)
                and (not q or q.casefold() in f"{moment.text} {moment.location or ''}".casefold())
            ]
            if mode == "recommended" and (preference is None or preference.personalized_recommendations):
                by_id = {moment.id: moment for moment in rows}
                visible.sort(key=lambda item: recommendation_score(by_id[item["id"]], like_count=item["like_count"], comment_count=item["comment_count"]), reverse=True)
            return visible

    def detail(self, actor, moment_id):
        with self.factory() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at or moment.status != "PUBLISHED" or not VisibilityPolicy(session).can_view(actor, moment):
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            result = self.dto(session, moment)
            result["comments"] = [self.comment_dto(row) for row in session.scalars(
                select(MomentComment).where(
                    MomentComment.moment_id == moment_id, MomentComment.deleted_at.is_(None),
                ).order_by(MomentComment.created_at, MomentComment.id)
            ).all()]
            return result

    def delete(self, actor, moment_id, key):
        with self.factory.begin() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at:
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            if moment.author_id != actor:
                raise AppError(code="MOMENT_DELETE_FORBIDDEN", message="无权删除该动态", status_code=403)
            moment.deleted_at = datetime.now(timezone.utc)
            self._audit(session, actor, moment_id, "moment.deleted", "MOMENT_DELETE", key)

    def like(self, actor, moment_id, key):
        with self.factory.begin() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at or not VisibilityPolicy(session).can_view(actor, moment):
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            existing = session.scalar(select(MomentLike).where(MomentLike.moment_id == moment_id, MomentLike.user_id == actor))
            if existing:
                return existing
            row = MomentLike(id=str(uuid4()), moment_id=moment_id, user_id=actor, idempotency_key=key, created_at=datetime.now(timezone.utc))
            session.add(row)
            self._audit(session, actor, moment_id, "moment.liked", "MOMENT_LIKE", key)
            return row

    def unlike(self, actor, moment_id, key):
        with self.factory.begin() as session:
            row = session.scalar(select(MomentLike).where(MomentLike.moment_id == moment_id, MomentLike.user_id == actor))
            if row:
                session.delete(row)
            self._audit(session, actor, moment_id, "moment.unliked", "MOMENT_UNLIKE", key)

    def comment(self, actor, moment_id, text, parent_id, key):
        with self.factory.begin() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at or not VisibilityPolicy(session).can_view(actor, moment):
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            existing = session.scalar(select(MomentComment).where(MomentComment.user_id == actor, MomentComment.idempotency_key == key))
            if existing:
                return existing
            if parent_id:
                parent = session.get(MomentComment, parent_id)
                if not parent or parent.moment_id != moment_id or parent.deleted_at:
                    raise AppError(code="COMMENT_PARENT_NOT_FOUND", message="回复的评论不存在", status_code=404)
            row = MomentComment(
                id=str(uuid4()), moment_id=moment_id, user_id=actor, parent_id=parent_id,
                text=text, idempotency_key=key, created_at=datetime.now(timezone.utc),
            )
            session.add(row)
            self._audit(session, actor, moment_id, "moment.commented", "MOMENT_COMMENT", key)
            return row

    def delete_comment(self, actor, moment_id, comment_id, key):
        with self.factory.begin() as session:
            moment, comment = session.get(Moment, moment_id), session.get(MomentComment, comment_id)
            if not moment or not comment or comment.moment_id != moment_id or comment.deleted_at:
                raise AppError(code="COMMENT_NOT_FOUND", message="评论不存在", status_code=404)
            if actor not in (moment.author_id, comment.user_id):
                raise AppError(code="COMMENT_DELETE_FORBIDDEN", message="无权删除该评论", status_code=403)
            comment.deleted_at = datetime.now(timezone.utc)
            self._audit(session, actor, moment_id, "moment.comment_deleted", "MOMENT_COMMENT_DELETE", key)

    def preferences(self, actor, data=None):
        with self.factory.begin() as session:
            row = session.get(MomentsPreference, actor)
            if row is None:
                row = MomentsPreference(user_id=actor, history_range="ALL", personalized_recommendations=True, updated_at=datetime.now(timezone.utc))
                session.add(row)
            if data:
                row.history_range = data["history_range"]
                row.personalized_recommendations = data["personalized_recommendations"]
                row.updated_at = datetime.now(timezone.utc)
            return {"history_range": row.history_range, "personalized_recommendations": row.personalized_recommendations, "cover_url": row.cover_url}

    def report(self, actor, moment_id, reason, key):
        with self.factory.begin() as session:
            if session.get(Moment, moment_id) is None:
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            old = session.scalar(select(MomentReport).where(MomentReport.reporter_id == actor, MomentReport.idempotency_key == key))
            if old:
                return old
            row = MomentReport(id=str(uuid4()), moment_id=moment_id, reporter_id=actor, reason_code=reason, idempotency_key=key, status="OPEN", created_at=datetime.now(timezone.utc))
            session.add(row)
            self._audit(session, actor, moment_id, "moment.reported", reason, key)
            return row

    @staticmethod
    def comment_dto(row):
        return {"id": row.id, "user_id": row.user_id, "parent_id": row.parent_id, "text": row.text, "created_at": row.created_at}

    def dto(self, session, moment):
        likes = len(session.scalars(select(MomentLike).where(MomentLike.moment_id == moment.id)).all())
        comments = len(session.scalars(select(MomentComment).where(MomentComment.moment_id == moment.id, MomentComment.deleted_at.is_(None))).all())
        return {"id": moment.id, "author_id": moment.author_id, "text": moment.text, "visibility": moment.visibility, "image_urls": moment.image_urls, "status": moment.status, "like_count": likes, "comment_count": comments, "created_at": moment.created_at}
