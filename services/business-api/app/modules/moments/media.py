from datetime import datetime, timedelta, timezone
from uuid import uuid4
from pathlib import Path

from sqlalchemy import DateTime, ForeignKey, Integer, String, UniqueConstraint, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.errors import AppError


ALLOWED_IMAGE_MIME = {"image/jpeg", "image/png", "image/webp"}
MAX_IMAGE_BYTES = 20 * 1024 * 1024


class MomentMediaUpload(Base):
    __tablename__ = "moment_media_uploads"
    __table_args__ = (UniqueConstraint("owner_id", "idempotency_key", name="uq_moment_media_upload_idempotency"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    file_name: Mapped[str] = mapped_column(String(255))
    mime_type: Mapped[str] = mapped_column(String(100))
    byte_size: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), index=True)
    object_key: Mapped[str] = mapped_column(String(512), unique=True)
    purpose: Mapped[str] = mapped_column(String(30), default="MOMENT_IMAGE")
    idempotency_key: Mapped[str] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class MomentMediaService:
    def __init__(self, factory, storage=None):
        self.factory = factory
        self.storage = storage
    def begin(self, actor, file_name, mime_type, byte_size, key, *, purpose="MOMENT_IMAGE"):
        if mime_type not in ALLOWED_IMAGE_MIME or byte_size < 1 or byte_size > MAX_IMAGE_BYTES:
            raise AppError(code="MOMENT_MEDIA_INVALID", message="仅支持20MiB以内 JPG/PNG/WebP", status_code=422)
        with self.factory.begin() as session:
            old = session.scalar(select(MomentMediaUpload).where(MomentMediaUpload.owner_id == actor, MomentMediaUpload.idempotency_key == key))
            if old: return old
            now = datetime.now(timezone.utc); upload_id = str(uuid4())
            suffix = Path(file_name).suffix.casefold()
            directory = "moments/covers" if purpose == "MOMENT_COVER" else "moments"
            row = MomentMediaUpload(id=upload_id, owner_id=actor, file_name=file_name, mime_type=mime_type, byte_size=byte_size, status="PENDING", object_key=f"{directory}/{actor}/{upload_id}{suffix}", purpose=purpose, idempotency_key=key, created_at=now, expires_at=now + timedelta(minutes=30))
            session.add(row); return row
    def complete(self, actor, upload_id):
        with self.factory.begin() as session:
            row = session.get(MomentMediaUpload, upload_id)
            if not row or row.owner_id != actor: raise AppError(code="MOMENT_MEDIA_NOT_FOUND", message="上传不存在", status_code=404)
            if row.expires_at.replace(tzinfo=row.expires_at.tzinfo or timezone.utc) <= datetime.now(timezone.utc): raise AppError(code="MOMENT_MEDIA_EXPIRED", message="上传已过期", status_code=409)
            if row.status != "UPLOADED":
                row.status = "SCANNING"
            else:
                row.status = "COMPLETED"
            return row

    def put_content(self, actor, upload_id, content, content_type):
        with self.factory.begin() as session:
            row = session.get(MomentMediaUpload, upload_id)
            if not row or row.owner_id != actor:
                raise AppError(code="MOMENT_MEDIA_NOT_FOUND", message="上传不存在", status_code=404)
            if content_type != row.mime_type or len(content) != row.byte_size:
                raise AppError(code="MOMENT_MEDIA_INVALID", message="媒体内容校验失败", status_code=422)
            if self.storage:
                self.storage.put(row.object_key, content)
            row.status = "UPLOADED"
            return row
