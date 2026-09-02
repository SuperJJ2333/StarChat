from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from io import BytesIO
import json
from uuid import uuid4

from PIL import Image, UnidentifiedImageError
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.integrations.private_storage import PrivateObjectStorage
from app.modules.audit.writer import AuditWriter
from sqlalchemy import case, func, or_, select
from app.modules.identity.models import AvatarUpload, User, Device
from app.modules.identity.enums import AccountStatus


ALLOWED_AVATAR_MIME = {"image/jpeg", "image/png", "image/webp"}
MAX_AVATAR_BYTES = 5 * 1024 * 1024
MAX_AVATAR_DIMENSION = 1024
AVATAR_URL_EXPIRES_IN = 300
_FORMAT_MIME = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
_MIME_SUFFIX = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}


@dataclass(frozen=True)
class ProfileResult:
    username: str
    nickname: str
    signature: str | None
    nudge_suffix: str | None
    masked_email: str
    avatar_url: str | None
    avatar_fallback_seed: str
    profile_updated_at: datetime


@dataclass(frozen=True)
class PublicProfileResult:
    user_id: str
    username: str
    nickname: str
    signature: str | None
    avatar_url: str | None
    matrix_user_id: str | None
    nudge_suffix: str | None


class ProfileService:
    def __init__(self, session_factory, *, storage: PrivateObjectStorage, now_factory=None):
        self._session_factory = session_factory
        self._storage = storage
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._audit = AuditWriter(session_factory, now_factory=self._now_factory)

    def get(self, user_id: str) -> ProfileResult:
        with self._session_factory() as session:
            user = session.get(User, user_id)
            if user is None:
                self._not_found()
            return self._profile(user)

    def read_public_profiles(
        self, user_ids: list[str] | set[str]
    ) -> dict[str, PublicProfileResult]:
        if not user_ids:
            return {}
        with self._session_factory() as session:
            users = list(session.scalars(select(User).where(User.id.in_(user_ids))))
            return {user.id: self._public_profile(user) for user in users}

    def search_public_profiles(
        self,
        query: str,
        *,
        exclude_user_ids: set[str],
        limit: int = 20,
    ) -> list[PublicProfileResult]:
        """畅聊号/邮箱前缀搜索（添加朋友候选）。

        - 匹配：输入与畅聊号或邮箱（大小写不敏感）的**开头**一致即命中；
        - 排序：畅聊号命中优先于邮箱命中，同级按最近活跃时间倒序
          （设备 last_seen_at 最大值），再按畅聊号字典序稳定排序；
        - 排除自己、被拉黑用户（exclude_user_ids 由调用方传入）。
        """
        normalized = query.strip().casefold()
        if len(normalized) < 2:
            return []
        backslash = chr(92)
        escaped = (
            normalized.replace(backslash, backslash * 2)
            .replace("%", backslash + "%")
            .replace("_", backslash + "_")
        )
        prefix = escaped + "%"
        username_hit = User.username_normalized.like(prefix, escape=backslash)
        email_hit = User.email_normalized.like(prefix, escape=backslash)
        seen = (
            select(Device.user_id, func.max(Device.last_seen_at).label("last_seen"))
            .where(Device.revoked_at.is_(None))
            .group_by(Device.user_id)
            .subquery()
        )
        with self._session_factory() as session:
            statement = (
                select(User)
                .outerjoin(seen, seen.c.user_id == User.id)
                .where(
                    User.status == AccountStatus.ACTIVE,
                    or_(username_hit, email_hit),
                )
                .order_by(
                    case((username_hit, 0), else_=1),
                    seen.c.last_seen.desc().nullslast(),
                    User.username_normalized,
                    User.id,
                )
                .limit(limit)
            )
            if exclude_user_ids:
                statement = statement.where(User.id.not_in(exclude_user_ids))
            users = list(session.scalars(statement))
            return [self._public_profile(user) for user in users]

    def update(
        self,
        user_id: str,
        changes: dict,
        *,
        idempotency_key: str,
        trace_id: str,
        source_ip: str | None,
    ) -> ProfileResult:
        normalized = self._normalize_changes(changes)
        request_hash = self._request_hash(normalized)
        now = self._now_factory()
        with self._session_factory.begin() as session:
            record = self._claim_idempotency(
                session,
                scope=f"identity.profile.update:{user_id}",
                key=idempotency_key,
                request_hash=request_hash,
                now=now,
            )
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if user is None:
                self._not_found()
            if record.status == "COMPLETED":
                return self._profile(user)
            before = {"nickname": user.nickname, "signature": user.signature, "nudge_suffix": user.nudge_suffix}
            if "nickname" in normalized:
                user.nickname = normalized["nickname"]
            if "signature" in normalized:
                user.signature = normalized["signature"]
            if "nudge_suffix" in normalized:
                user.nudge_suffix = normalized["nudge_suffix"]
            user.profile_updated_at = now
            user.updated_at = now
            self._enqueue_profile_changed(session, user_id, now)
            self._audit.record_in_session(
                session,
                actor_id=user_id,
                subject_type="user",
                subject_id=user_id,
                action="identity.profile.updated",
                result="SUCCESS",
                reason_code="SELF_PROFILE_UPDATE",
                trace_id=trace_id,
                source_ip=source_ip,
                before=before,
                after={"nickname": user.nickname, "signature": user.signature, "nudge_suffix": user.nudge_suffix},
            )
            self._complete_idempotency(record, now)
            return self._profile(user)

    def begin_avatar_upload(
        self,
        user_id: str,
        *,
        mime_type: str,
        byte_size: int,
        idempotency_key: str,
    ) -> AvatarUpload:
        if mime_type not in ALLOWED_AVATAR_MIME:
            raise AppError(
                code="AVATAR_MIME_UNSUPPORTED",
                message="仅支持 JPEG、PNG 或 WebP 头像",
                status_code=422,
            )
        if byte_size < 1 or byte_size > MAX_AVATAR_BYTES:
            raise AppError(
                code="AVATAR_SIZE_EXCEEDED",
                message="头像不得超过 5 MiB",
                status_code=422,
            )
        now = self._now_factory()
        with self._session_factory.begin() as session:
            existing = session.scalar(
                select(AvatarUpload).where(
                    AvatarUpload.owner_id == user_id,
                    AvatarUpload.idempotency_key == idempotency_key,
                )
            )
            if existing is not None:
                if existing.mime_type != mime_type or existing.byte_size != byte_size:
                    self._idempotency_reused()
                return existing
            if session.get(User, user_id) is None:
                self._not_found()
            upload_id = str(uuid4())
            upload = AvatarUpload(
                id=upload_id,
                owner_id=user_id,
                mime_type=mime_type,
                byte_size=byte_size,
                status="PENDING",
                object_key=(
                    f"avatars/{user_id}/{upload_id}{_MIME_SUFFIX[mime_type]}"
                ),
                idempotency_key=idempotency_key,
                created_at=now,
                expires_at=now + timedelta(minutes=30),
            )
            session.add(upload)
            return upload

    def put_avatar_content(
        self,
        user_id: str,
        upload_id: str,
        *,
        content_type: str,
        content: bytes,
    ) -> None:
        if len(content) > MAX_AVATAR_BYTES:
            raise AppError(
                code="AVATAR_SIZE_EXCEEDED",
                message="头像不得超过 5 MiB",
                status_code=422,
            )
        digest = sha256(content).hexdigest()
        with self._session_factory.begin() as session:
            upload = self._owned_upload(session, user_id, upload_id, for_update=True)
            self._ensure_upload_available(upload)
            if upload.mime_type != content_type:
                raise AppError(
                    code="AVATAR_CONTENT_TYPE_MISMATCH",
                    message="上传 Content-Type 与会话不一致",
                    status_code=422,
                )
            if len(content) != upload.byte_size:
                raise AppError(
                    code="AVATAR_SIZE_MISMATCH",
                    message="头像大小与上传会话不一致",
                    status_code=422,
                )
            if upload.content_hash is not None and upload.content_hash != digest:
                raise AppError(
                    code="AVATAR_UPLOAD_CONTENT_CONFLICT",
                    message="同一上传会话不能写入不同内容",
                    status_code=409,
                )
            self._storage.put(upload.object_key, content)
            upload.content_hash = digest
            upload.status = "UPLOADED"

    def complete_avatar_upload(
        self,
        user_id: str,
        upload_id: str,
        *,
        idempotency_key: str,
        trace_id: str,
        source_ip: str | None,
    ) -> ProfileResult:
        now = self._now_factory()
        old_object_key = None
        with self._session_factory.begin() as session:
            record = self._claim_idempotency(
                session,
                scope=f"identity.avatar.complete:{user_id}",
                key=idempotency_key,
                request_hash=self._request_hash({"upload_id": upload_id}),
                now=now,
            )
            upload = self._owned_upload(session, user_id, upload_id, for_update=True)
            if upload.status == "CANCELLED":
                raise AppError(
                    code="AVATAR_UPLOAD_CANCELLED",
                    message="头像上传已取消",
                    status_code=409,
                )
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if record.status == "COMPLETED" or upload.status == "COMPLETED":
                self._complete_idempotency(record, now)
                return self._profile(user)
            self._ensure_upload_available(upload)
            if upload.status != "UPLOADED" or not upload.content_hash:
                raise AppError(
                    code="AVATAR_CONTENT_REQUIRED",
                    message="请先上传头像内容",
                    status_code=409,
                )
            content = self._storage.get(upload.object_key)
            self._validate_image(content, upload.mime_type)
            old_object_key = user.avatar_object_key
            user.avatar_object_key = upload.object_key
            user.profile_updated_at = now
            user.updated_at = now
            upload.status = "COMPLETED"
            upload.completed_at = now
            self._enqueue_profile_changed(session, user_id, now)
            self._audit.record_in_session(
                session,
                actor_id=user_id,
                subject_type="user",
                subject_id=user_id,
                action="identity.profile.avatar.updated",
                result="SUCCESS",
                reason_code="SELF_AVATAR_UPDATE",
                trace_id=trace_id,
                source_ip=source_ip,
            )
            self._complete_idempotency(record, now)
            result = self._profile(user)
        if old_object_key and old_object_key != upload.object_key:
            self._storage.delete(old_object_key)
        return result

    def cancel_avatar_upload(self, user_id: str, upload_id: str) -> None:
        object_key = None
        with self._session_factory.begin() as session:
            upload = self._owned_upload(session, user_id, upload_id, for_update=True)
            if upload.status == "COMPLETED":
                raise AppError(
                    code="AVATAR_UPLOAD_COMPLETED",
                    message="已完成的头像上传不能取消",
                    status_code=409,
                )
            object_key = upload.object_key
            if upload.status != "CANCELLED":
                upload.status = "CANCELLED"
                upload.cancelled_at = self._now_factory()
        if object_key:
            self._storage.delete(object_key)

    def delete_avatar(
        self,
        user_id: str,
        *,
        idempotency_key: str,
        trace_id: str,
        source_ip: str | None,
    ) -> None:
        now = self._now_factory()
        old_object_key = None
        with self._session_factory.begin() as session:
            record = self._claim_idempotency(
                session,
                scope=f"identity.avatar.delete:{user_id}",
                key=idempotency_key,
                request_hash=self._request_hash({"delete": True}),
                now=now,
            )
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if user is None:
                self._not_found()
            if record.status == "COMPLETED":
                return
            old_object_key = user.avatar_object_key
            if old_object_key:
                user.avatar_object_key = None
                user.profile_updated_at = now
                user.updated_at = now
                self._enqueue_profile_changed(session, user_id, now)
                self._audit.record_in_session(
                    session,
                    actor_id=user_id,
                    subject_type="user",
                    subject_id=user_id,
                    action="identity.profile.avatar.deleted",
                    result="SUCCESS",
                    reason_code="SELF_AVATAR_DELETE",
                    trace_id=trace_id,
                    source_ip=source_ip,
                )
            self._complete_idempotency(record, now)
        if old_object_key:
            self._storage.delete(old_object_key)

    def _profile(self, user: User) -> ProfileResult:
        avatar_url = None
        if user.avatar_object_key:
            avatar_url = self._storage.signed_read_url(
                user.avatar_object_key,
                AVATAR_URL_EXPIRES_IN,
            )
        profile_updated_at = user.profile_updated_at
        if profile_updated_at.tzinfo is None:
            profile_updated_at = profile_updated_at.replace(tzinfo=timezone.utc)
        return ProfileResult(
            username=user.username,
            nickname=user.nickname,
            signature=user.signature,
            nudge_suffix=user.nudge_suffix,
            masked_email=self._mask_email(user.email),
            avatar_url=avatar_url,
            avatar_fallback_seed=sha256(
                user.username_normalized.encode("utf-8")
            ).hexdigest()[:16],
            profile_updated_at=profile_updated_at,
        )

    def _public_profile(self, user: User) -> PublicProfileResult:
        avatar_url = None
        if user.avatar_object_key:
            avatar_url = self._storage.signed_read_url(
                user.avatar_object_key,
                AVATAR_URL_EXPIRES_IN,
            )
        return PublicProfileResult(
            user_id=user.id,
            username=user.username,
            nickname=user.nickname,
            signature=user.signature,
            avatar_url=avatar_url,
            matrix_user_id=user.matrix_user_id,
            nudge_suffix=user.nudge_suffix,
        )

    @staticmethod
    def _normalize_changes(changes: dict) -> dict:
        normalized = {}
        if "nickname" in changes:
            nickname = changes["nickname"].strip()
            if not nickname or len(nickname) > 64:
                raise AppError(
                    code="PROFILE_NICKNAME_INVALID",
                    message="昵称长度必须为 1 到 64 个字符",
                    status_code=422,
                )
            normalized["nickname"] = nickname
        if "signature" in changes:
            signature = changes["signature"]
            signature = signature.strip() if signature is not None else None
            if signature and len(signature) > 140:
                raise AppError(
                    code="PROFILE_SIGNATURE_INVALID",
                    message="个性签名不得超过 140 个字符",
                    status_code=422,
                )
            normalized["signature"] = signature or None
        if "nudge_suffix" in changes:
            nudge_suffix = changes["nudge_suffix"]
            nudge_suffix = nudge_suffix.strip() if nudge_suffix is not None else None
            if nudge_suffix and len(nudge_suffix) > 10:
                raise AppError(
                    code="PROFILE_NUDGE_SUFFIX_INVALID",
                    message="拍一拍后缀不得超过 10 个字符",
                    status_code=422,
                )
            normalized["nudge_suffix"] = nudge_suffix or None
        return normalized

    @staticmethod
    def _validate_image(content: bytes, declared_mime: str) -> None:
        try:
            image = Image.open(BytesIO(content))
            actual_mime = _FORMAT_MIME.get(image.format or "")
            width, height = image.size
            if actual_mime is None:
                raise UnidentifiedImageError("unsupported image format")
            if actual_mime != declared_mime:
                raise AppError(
                    code="AVATAR_MIME_MISMATCH",
                    message="头像真实格式与声明格式不一致",
                    status_code=422,
                )
            if width != height:
                raise AppError(
                    code="AVATAR_NOT_SQUARE",
                    message="头像必须为正方形",
                    status_code=422,
                )
            if width > MAX_AVATAR_DIMENSION or height > MAX_AVATAR_DIMENSION:
                raise AppError(
                    code="AVATAR_DIMENSIONS_EXCEEDED",
                    message="头像尺寸不得超过 1024×1024",
                    status_code=422,
                )
            image.verify()
        except AppError:
            raise
        except (OSError, ValueError, UnidentifiedImageError, Image.DecompressionBombError):
            raise AppError(
                code="AVATAR_CONTENT_INVALID",
                message="头像内容无效",
                status_code=422,
            ) from None

    @staticmethod
    def _mask_email(email: str) -> str:
        local, separator, domain = email.partition("@")
        visible = local[:2] if len(local) > 1 else local[:1]
        return f"{visible}***{separator}{domain}"

    @staticmethod
    def _request_hash(payload: dict) -> str:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return sha256(encoded.encode("utf-8")).hexdigest()

    @staticmethod
    def _claim_idempotency(session, *, scope, key, request_hash, now):
        record = IdempotencyRecord(
            id=str(uuid4()),
            scope=scope,
            idempotency_key=key,
            request_hash=request_hash,
            status="IN_PROGRESS",
            created_at=now,
        )
        try:
            with session.begin_nested():
                session.add(record)
                session.flush()
            return record
        except IntegrityError:
            existing = session.scalar(
                select(IdempotencyRecord)
                .where(
                    IdempotencyRecord.scope == scope,
                    IdempotencyRecord.idempotency_key == key,
                )
                .with_for_update()
            )
            if existing is None:
                raise
            if existing.request_hash != request_hash:
                ProfileService._idempotency_reused()
            if existing.status != "COMPLETED":
                raise AppError(
                    code="IDEMPOTENCY_IN_PROGRESS",
                    message="幂等请求正在处理中",
                    status_code=409,
                )
            return existing

    @staticmethod
    def _complete_idempotency(record, now) -> None:
        record.status = "COMPLETED"
        record.response_status = 200
        record.response_body = {"completed": True}
        record.completed_at = now

    @staticmethod
    def _owned_upload(session, user_id, upload_id, *, for_update=False):
        statement = select(AvatarUpload).where(
            AvatarUpload.id == upload_id,
            AvatarUpload.owner_id == user_id,
        )
        if for_update:
            statement = statement.with_for_update()
        upload = session.scalar(statement)
        if upload is None:
            raise AppError(
                code="AVATAR_UPLOAD_NOT_FOUND",
                message="头像上传不存在",
                status_code=404,
            )
        return upload

    def _ensure_upload_available(self, upload: AvatarUpload) -> None:
        if upload.status == "CANCELLED":
            raise AppError(
                code="AVATAR_UPLOAD_CANCELLED",
                message="头像上传已取消",
                status_code=409,
            )
        expires_at = upload.expires_at
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at <= self._now_factory():
            raise AppError(
                code="AVATAR_UPLOAD_EXPIRED",
                message="头像上传已过期",
                status_code=409,
            )

    @staticmethod
    def _enqueue_profile_changed(session, user_id: str, now: datetime) -> None:
        OutboxPublisher.enqueue(
            session,
            topic="identity.profile",
            event_type="identity.profile.changed",
            aggregate_type="user",
            aggregate_id=user_id,
            payload={"user_id": user_id},
            now=now,
        )

    @staticmethod
    def _idempotency_reused() -> None:
        raise AppError(
            code="IDEMPOTENCY_KEY_REUSED",
            message="幂等键已用于不同请求",
            status_code=409,
        )

    @staticmethod
    def _not_found() -> None:
        raise AppError(code="PROFILE_NOT_FOUND", message="资料不存在", status_code=404)
