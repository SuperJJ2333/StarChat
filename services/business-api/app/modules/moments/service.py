from datetime import datetime, timedelta, timezone
import base64
import json
from uuid import uuid4

from sqlalchemy import select

from app.modules.identity.models import User

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.friendship.models import ContactProfile, ContactTag, Friendship
from app.modules.moments.models import (
    Moment,
    MomentComment,
    MomentLike,
    MomentReport,
    MomentsPreference,
    MomentNotification,
    MomentDraft,
    NativeMomentAd,
)
from app.modules.moments.visibility import VisibilityPolicy
from app.modules.moments.recommendation import recommendation_score
from app.modules.moments.media import MomentMediaUpload


class MomentsService:
    def __init__(self, factory, *, avatar_storage=None):
        self.factory = factory
        self.avatar_storage = avatar_storage

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

    @staticmethod
    def _friend_ids(session, actor):
        rows = session.scalars(select(Friendship).where(
            (Friendship.user_low_id == actor) | (Friendship.user_high_id == actor),
        )).all()
        return {row.user_high_id if row.user_low_id == actor else row.user_low_id for row in rows}

    def _resolve_audience(self, session, actor, direct_ids, tag_ids):
        friend_ids = self._friend_ids(session, actor)
        direct_ids = set(direct_ids or [])
        if not direct_ids.issubset(friend_ids):
            raise AppError(code='MOMENT_AUDIENCE_NOT_FRIEND', message='只能选择好友', status_code=422)
        tag_ids = list(dict.fromkeys(tag_ids or []))
        tags = list(session.scalars(select(ContactTag).where(
            ContactTag.owner_id == actor, ContactTag.id.in_(tag_ids),
        )).all()) if tag_ids else []
        if len(tags) != len(tag_ids):
            raise AppError(code='MOMENT_AUDIENCE_TAG_NOT_FOUND', message='标签不存在', status_code=404)
        names = {tag.name for tag in tags}
        tag_members = {
            profile.contact_id for profile in session.scalars(select(ContactProfile).where(
                ContactProfile.owner_id == actor,
            )).all()
            if names.intersection(filter(None, (profile.tags or '').split(',')))
        }
        return sorted(direct_ids | (tag_members & friend_ids)), tag_ids

    def create(self, actor, data, key):
        if len(data.get("image_urls", [])) > 9:
            raise AppError(code="MOMENT_IMAGE_LIMIT", message="最多上传9张图片", status_code=422)
        with self.factory.begin() as session:
            old = session.scalar(select(Moment).where(Moment.author_id == actor, Moment.idempotency_key == key))
            if old:
                return old
            include_ids, include_tags = self._resolve_audience(
                session, actor, data.get('include_user_ids', []), data.get('include_tag_ids', []),
            )
            exclude_ids, exclude_tags = self._resolve_audience(
                session, actor, data.get('exclude_user_ids', []), data.get('exclude_tag_ids', []),
            )
            now = datetime.now(timezone.utc)
            row = Moment(
                id=str(uuid4()), author_id=actor, text=data.get("text", ""), visibility=data["visibility"],
                image_urls=data.get("image_urls", []), include_user_ids=include_ids,
                exclude_user_ids=exclude_ids, include_tag_ids=include_tags, exclude_tag_ids=exclude_tags, location=data.get("location"),
                # 带图与纯文字一致直接发布：原 PENDING_REVIEW 队列没有任何
                # 审核放行流程，导致带图动态永远不出现在 feed（产品缺陷）。
                # 内容安全依赖既有举报通道（POST /moments/{id}/reports）。
                link_url=data.get("link_url"), status="PUBLISHED", idempotency_key=key, created_at=now,
            )
            session.add(row)
            self._audit(session, actor, row.id, "moment.published", "MOMENT_PUBLISH", key)
            return row

    @staticmethod
    def _encode_cursor(moment):
        value = {'created_at': moment.created_at.isoformat(), 'id': moment.id}
        return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).decode()

    @staticmethod
    def _decode_cursor(cursor):
        if not cursor:
            return None
        try:
            value = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
            return datetime.fromisoformat(value['created_at']), str(value['id'])
        except (ValueError, KeyError, json.JSONDecodeError):
            raise AppError(code='MOMENT_CURSOR_INVALID', message='分页游标无效', status_code=422)

    def feed(self, actor, q=None, mode="latest", cursor=None, limit=20):
        marker = self._decode_cursor(cursor)
        with self.factory() as session:
            preference = session.get(MomentsPreference, actor)
            cutoff = None
            if preference and preference.history_range != "ALL":
                cutoff = datetime.now(timezone.utc) - {
                    "THREE_DAYS": timedelta(days=3), "ONE_MONTH": timedelta(days=30),
                    "SIX_MONTHS": timedelta(days=183),
                }[preference.history_range]
            statement = select(Moment).where(Moment.deleted_at.is_(None), Moment.status == "PUBLISHED", Moment.author_id.in_(self._friend_ids(session, actor) | {actor}))
            if marker and mode == 'latest':
                from sqlalchemy import and_, or_
                marker_time, marker_id = marker
                statement = statement.where(or_(Moment.created_at < marker_time, and_(Moment.created_at == marker_time, Moment.id < marker_id)))
            statement = statement.order_by(Moment.created_at.desc(), Moment.id.desc())
            if mode != 'latest':
                statement = statement.limit(500)
            rows = session.scalars(statement.execution_options(yield_per=100))
            policy = VisibilityPolicy(session)
            visible_rows = []
            for moment in rows:
                if (policy.can_view(actor, moment)
                    and (cutoff is None or (moment.created_at if moment.created_at.tzinfo else moment.created_at.replace(tzinfo=timezone.utc)) >= cutoff)
                    and (not q or q.casefold() in f"{moment.text} {moment.location or ''}".casefold())):
                    visible_rows.append(moment)
                    if mode == 'latest' and len(visible_rows) > limit:
                        break
            if mode == "recommended" and (preference is None or preference.personalized_recommendations):
                def score(moment):
                    likes = len(session.scalars(select(MomentLike).where(MomentLike.moment_id == moment.id)).all())
                    comments = len(session.scalars(select(MomentComment).where(MomentComment.moment_id == moment.id, MomentComment.deleted_at.is_(None))).all())
                    return recommendation_score(moment, like_count=likes, comment_count=comments)
                visible_rows.sort(key=score, reverse=True)
            if marker:
                marker_time, marker_id = marker
                visible_rows = [moment for moment in visible_rows if (moment.created_at, moment.id) < (marker_time, marker_id)]
            page_rows = visible_rows[:limit]
            return {'items': [self.dto(session, moment, actor) for moment in page_rows], 'next_cursor': self._encode_cursor(page_rows[-1]) if len(visible_rows) > limit else None}

    def new_posts(self, actor, since=None, cursor=None):
        now = datetime.now(timezone.utc)
        if since is None:
            return {'items': [], 'next_cursor': None, 'server_time': now.isoformat()}
        marker = self._decode_cursor(cursor)
        with self.factory() as session:
            preference = session.get(MomentsPreference, actor)
            cutoff = since
            if preference and preference.history_range != 'ALL':
                cutoff = max(cutoff, now - {'THREE_DAYS': timedelta(days=3), 'ONE_MONTH': timedelta(days=30), 'SIX_MONTHS': timedelta(days=183)}[preference.history_range])
            statement = select(Moment).where(
                Moment.deleted_at.is_(None), Moment.status == 'PUBLISHED',
                Moment.author_id != actor, Moment.created_at >= cutoff,
                Moment.author_id.in_(self._friend_ids(session, actor)),
            ).order_by(Moment.created_at.desc(), Moment.id.desc())
            if marker:
                from sqlalchemy import and_, or_
                marker_time, marker_id = marker
                statement = statement.where(or_(Moment.created_at < marker_time, and_(Moment.created_at == marker_time, Moment.id < marker_id)))
            policy = VisibilityPolicy(session)
            visible = []
            # Stream metadata candidates: unrelated posts must never consume a
            # global cap and hide a friend's newer post from the badge.
            for row in session.scalars(statement.execution_options(yield_per=100)):
                if policy.can_view(actor, row):
                    visible.append(row)
                    if len(visible) == 101:
                        break
            page = visible[:100]
            return {'items': [{'id': row.id, 'created_at': row.created_at.isoformat()} for row in page],
                    'next_cursor': self._encode_cursor(page[-1]) if len(visible) > 100 else None,
                    'server_time': now.isoformat()}

    def detail(self, actor, moment_id):
        with self.factory() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at or moment.status != "PUBLISHED" or not VisibilityPolicy(session).can_view(actor, moment):
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            return self.dto(session, moment, actor)

    def delete(self, actor, moment_id, key):
        with self.factory.begin() as session:
            moment = session.get(Moment, moment_id)
            if not moment or moment.deleted_at:
                raise AppError(code="MOMENT_NOT_FOUND", message="动态不存在", status_code=404)
            if moment.author_id != actor:
                raise AppError(code="MOMENT_DELETE_FORBIDDEN", message="无权删除该动态", status_code=403)
            moment.deleted_at = datetime.now(timezone.utc)
            self._audit(session, actor, moment_id, "moment.deleted", "MOMENT_DELETE", key)

    @staticmethod
    def _notify(session, recipient, moment_id, actor, kind, comment_id=None):
        if recipient == actor:
            return
        old = session.scalar(select(MomentNotification).where(MomentNotification.recipient_id == recipient, MomentNotification.kind == kind, MomentNotification.moment_id == moment_id, MomentNotification.actor_id == actor, MomentNotification.comment_id == comment_id))
        if old is None:
            session.add(MomentNotification(id=str(uuid4()), recipient_id=recipient, moment_id=moment_id, actor_id=actor, kind=kind, comment_id=comment_id, read_at=None, invalidated_at=None, created_at=datetime.now(timezone.utc)))

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
            self._notify(session, moment.author_id, moment_id, actor, "LIKE")
            self._audit(session, actor, moment_id, "moment.liked", "MOMENT_LIKE", key)
            return row

    def unlike(self, actor, moment_id, key):
        with self.factory.begin() as session:
            row = session.scalar(select(MomentLike).where(MomentLike.moment_id == moment_id, MomentLike.user_id == actor))
            if row:
                session.delete(row)
                for notification in session.scalars(select(MomentNotification).where(MomentNotification.moment_id == moment_id, MomentNotification.actor_id == actor, MomentNotification.kind == "LIKE", MomentNotification.invalidated_at.is_(None))).all():
                    notification.invalidated_at = datetime.now(timezone.utc)
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
            self._notify(session, moment.author_id, moment_id, actor, "COMMENT", row.id)
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
            for notification in session.scalars(select(MomentNotification).where(MomentNotification.comment_id == comment_id, MomentNotification.invalidated_at.is_(None))).all():
                notification.invalidated_at = comment.deleted_at
            self._audit(session, actor, moment_id, "moment.comment_deleted", "MOMENT_COMMENT_DELETE", key)

    def notifications(self, actor):
        with self.factory() as session:
            rows = session.scalars(select(MomentNotification).where(MomentNotification.recipient_id == actor, MomentNotification.invalidated_at.is_(None)).order_by(MomentNotification.created_at.desc(), MomentNotification.id.desc())).all()
            return [{'id': row.id, 'moment_id': row.moment_id, 'kind': row.kind, 'actor': self._user_projection(session, row.actor_id, actor), 'created_at': row.created_at, 'read_at': row.read_at} for row in rows]

    def notification_unread_count(self, actor):
        return sum(row['read_at'] is None for row in self.notifications(actor))

    def mark_notifications_read(self, actor, ids):
        with self.factory.begin() as session:
            for row in session.scalars(select(MomentNotification).where(MomentNotification.recipient_id == actor, MomentNotification.id.in_(ids), MomentNotification.invalidated_at.is_(None))).all():
                row.read_at = datetime.now(timezone.utc)

    def draft(self, actor):
        with self.factory() as session:
            row = session.get(MomentDraft, actor)
            if row is None:
                raise AppError(code='MOMENT_DRAFT_NOT_FOUND', message='草稿不存在', status_code=404)
            return row.payload

    def save_draft(self, actor, payload):
        with self.factory.begin() as session:
            row = session.get(MomentDraft, actor)
            if row is None:
                row = MomentDraft(owner_id=actor, payload=payload, updated_at=datetime.now(timezone.utc)); session.add(row)
            else:
                row.payload = payload; row.updated_at = datetime.now(timezone.utc)
            self._audit(session, actor, actor, 'moment.draft_saved', 'MOMENT_DRAFT_SAVE', 'draft')
            return row.payload

    def delete_draft(self, actor):
        with self.factory.begin() as session:
            row = session.get(MomentDraft, actor)
            if row: session.delete(row)

    def native_ads(self):
        with self.factory() as session:
            rows = session.scalars(select(NativeMomentAd).where(NativeMomentAd.status == 'ACTIVE').order_by(NativeMomentAd.created_at.desc())).all()
            return [{'kind':'AD','id':row.id,'ad':{'advertiser_name':row.advertiser_name,'avatar_url':row.avatar_url,'text':row.text,'image_urls':row.image_urls,'link_url':row.link_url,'disclaimer':'广告'}} for row in rows]

    def personal_timeline(self, actor, user_id):
        with self.factory() as session:
            rows = session.scalars(select(Moment).where(Moment.author_id == user_id, Moment.deleted_at.is_(None)).order_by(Moment.created_at.desc(), Moment.id.desc())).all()
            policy = VisibilityPolicy(session)
            return [self.dto(session, row, actor) for row in rows if (row.status == 'PUBLISHED' and policy.can_view(actor, row)) or actor == user_id]

    def preferences(self, actor, data=None):
        with self.factory.begin() as session:
            row = session.get(MomentsPreference, actor)
            if row is None:
                row = MomentsPreference(user_id=actor, history_range="ALL", personalized_recommendations=True, updated_at=datetime.now(timezone.utc))
                session.add(row)
            if data:
                row.history_range = data["history_range"]
                row.personalized_recommendations = data["personalized_recommendations"]
                if data.get('cover_url') is not None:
                    row.cover_url = data['cover_url']
                row.updated_at = datetime.now(timezone.utc)
            cover_url = row.cover_url
            if row.cover_object_key and self.avatar_storage:
                cover_url = self.avatar_storage.signed_read_url(
                    row.cover_object_key, self.MOMENT_MEDIA_URL_TTL
                )
            return {"history_range": row.history_range, "personalized_recommendations": row.personalized_recommendations, "cover_url": cover_url}

    def set_cover(self, actor, upload_id, key):
        with self.factory.begin() as session:
            upload = session.get(MomentMediaUpload, upload_id)
            if (
                upload is None
                or upload.owner_id != actor
                or upload.purpose != "MOMENT_COVER"
                or upload.status != "COMPLETED"
            ):
                raise AppError(
                    code="MOMENT_COVER_INVALID",
                    message="封面上传无效或尚未完成",
                    status_code=422,
                )
            row = session.get(MomentsPreference, actor)
            if row is None:
                row = MomentsPreference(
                    user_id=actor,
                    history_range="ALL",
                    personalized_recommendations=True,
                    cover_url=None,
                    cover_object_key=upload.object_key,
                    updated_at=datetime.now(timezone.utc),
                )
                session.add(row)
            else:
                row.cover_object_key = upload.object_key
                row.cover_url = None
                row.updated_at = datetime.now(timezone.utc)
            self._audit(
                session,
                actor,
                actor,
                "moment.cover_updated",
                "MOMENT_COVER_UPDATE",
                key,
            )
            cover_url = (
                self.avatar_storage.signed_read_url(upload.object_key, 300)
                if self.avatar_storage
                else None
            )
            return {
                "history_range": row.history_range,
                "personalized_recommendations": row.personalized_recommendations,
                "cover_url": cover_url,
            }

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

    # 朋友圈媒体链接的有效期：feed 每次输出时动态重签，7 天内有效，
    # 旧动态（含历史上以 300s 短签持久化的链接）也会被重新签名救活。
    MOMENT_MEDIA_URL_TTL = 604800

    def _resign_media_url(self, url: str) -> str:
        # 对持久化的媒体链接重新签发长期签名。历史实现把上传完成时刻
        # 签发的短时（300s）签名 URL 原样入库，feed 返回的必然是过期
        # 链接，带图动态的图片因此永远无法显示。
        marker = "/api/v1/profile/avatar/content/"
        if not url or marker not in url:
            return url
        token = url.split(marker, 1)[1].split("?", 1)[0]
        try:
            from urllib.parse import unquote

            resign = getattr(self.avatar_storage, "resign_read_url", None)
            if resign is None:
                return url
            return resign(unquote(token), self.MOMENT_MEDIA_URL_TTL)
        except Exception:
            return url

    def _user_projection(self, session, user_id, viewer_id=None):
        user = session.get(User, user_id)
        if user is None:
            return {
                'user_id': user_id,
                'username': '',
                'nickname': '',
                'display_name': '',
                'avatar_url': None,
            }
        username = user.username.strip()
        nickname = (user.nickname or '').strip()
        # 隐私红线：好友备注仅对设置者本人可见（存于 contact_profiles.owner_id 维度），
        # 朋友圈任何投影（动态/评论/点赞/通知的作者展示）一律使用主昵称，
        # 绝不读取备注字段，也绝不在响应中携带 remark。
        avatar_url = self.avatar_storage.signed_read_url(user.avatar_object_key, 300) if self.avatar_storage and user.avatar_object_key else None
        return {
            'user_id': user.id,
            'username': username,
            'nickname': nickname,
            'display_name': nickname or username,
            'avatar_url': avatar_url,
        }

    def comment_dto(self, session, row, viewer_id=None):
        parent = session.get(MomentComment, row.parent_id) if row.parent_id else None
        return {'id': row.id, 'user_id': row.user_id, 'parent_id': row.parent_id, 'text': row.text, 'created_at': row.created_at, 'author': self._user_projection(session, row.user_id, viewer_id), 'parent_author': self._user_projection(session, parent.user_id, viewer_id) if parent else None}

    def dto(self, session, moment, viewer_id=None):
        like_rows = session.scalars(select(MomentLike).where(MomentLike.moment_id == moment.id).order_by(MomentLike.created_at, MomentLike.id)).all()
        comment_rows = session.scalars(
            select(MomentComment)
            .where(
                MomentComment.moment_id == moment.id,
                MomentComment.deleted_at.is_(None),
            )
            .order_by(MomentComment.created_at, MomentComment.id)
        ).all()
        return {
            'id': moment.id,
            'author_id': moment.author_id,
            'author': self._user_projection(session, moment.author_id, viewer_id),
            'text': moment.text,
            'visibility': moment.visibility,
            'image_urls': [
                self._resign_media_url(url) for url in moment.image_urls
            ],
            'include_user_ids': moment.include_user_ids,
            'exclude_user_ids': moment.exclude_user_ids,
            'include_tag_ids': moment.include_tag_ids,
            'exclude_tag_ids': moment.exclude_tag_ids,
            'location': moment.location,
            'link_url': moment.link_url,
            'status': moment.status,
            'like_count': len(like_rows),
            'like_users': [
                self._user_projection(session, row.user_id, viewer_id)
                for row in like_rows[:20]
            ],
            'viewer_has_liked': bool(
                viewer_id and any(row.user_id == viewer_id for row in like_rows)
            ),
            'comment_count': len(comment_rows),
            'comments': [
                self.comment_dto(session, row, viewer_id) for row in comment_rows
            ],
            'created_at': moment.created_at,
        }
