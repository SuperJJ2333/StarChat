from datetime import datetime, timedelta, timezone
from uuid import uuid4
from io import BytesIO
from struct import error as StructError
from PIL import Image, UnidentifiedImageError

from sqlalchemy import DateTime, ForeignKey, Integer, String, UniqueConstraint, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.errors import AppError


IMAGE_SUFFIX_BY_MIME = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}
ALLOWED_IMAGE_MIME = set(IMAGE_SUFFIX_BY_MIME)
MAX_IMAGE_BYTES = 20 * 1024 * 1024
MAX_GIF_PIXELS = 4 * 1024 * 1024
MAX_GIF_TOTAL_PIXELS = 128 * 1024 * 1024


def _validate_gif_container(content, width, height):
    """Bound every block before decoding; Pillow tolerates missing trailers."""
    offset = 13

    def take(count):
        nonlocal offset
        if count > len(content) - offset:
            raise ValueError("truncated GIF block")
        start = offset
        offset += count
        return content[start:offset]

    def sub_blocks():
        while True:
            size = take(1)[0]
            if not size:
                return
            take(size)

    if content[10] & 0x80:
        take(3 * (1 << ((content[10] & 7) + 1)))
    frames = 0
    while True:
        marker = take(1)[0]
        if marker == 0x3b:
            if not frames or offset != len(content):
                raise ValueError("invalid GIF termination")
            return
        if marker == 0x21:
            take(1)  # Extension label; its bounded data follows as sub-blocks.
            sub_blocks()
            continue
        if marker != 0x2c:
            raise ValueError("invalid GIF block")
        descriptor = take(9)
        left = int.from_bytes(descriptor[0:2], "little")
        top = int.from_bytes(descriptor[2:4], "little")
        frame_width = int.from_bytes(descriptor[4:6], "little")
        frame_height = int.from_bytes(descriptor[6:8], "little")
        if not frame_width or not frame_height or left + frame_width > width or top + frame_height > height:
            raise ValueError("GIF frame exceeds canvas")
        frames += 1
        if frames * width * height > MAX_GIF_TOTAL_PIXELS:
            raise ValueError("animation exceeds decoded pixel budget")
        packed = descriptor[8]
        if packed & 0x80:
            take(3 * (1 << ((packed & 7) + 1)))
        if not 2 <= take(1)[0] <= 8:
            raise ValueError("invalid GIF code size")
        sub_blocks()


def validate_gif(content):
    """Validate a bounded animation without replacing its original bytes."""
    if len(content) < 13 or content[:6] not in (b"GIF87a", b"GIF89a"):
        raise AppError(code="MOMENT_MEDIA_INVALID", message="GIF 文件已损坏", status_code=422)
    width = int.from_bytes(content[6:8], "little")
    height = int.from_bytes(content[8:10], "little")
    if not width or not height or width * height > MAX_GIF_PIXELS:
        raise AppError(code="MOMENT_MEDIA_INVALID", message="GIF 不能超过400万像素", status_code=422)
    try:
        _validate_gif_container(content, width, height)
        with Image.open(BytesIO(content)) as image:
            if image.format != "GIF":
                raise ValueError("invalid format")
            total_pixels = 0
            frame = 0
            while True:
                total_pixels += image.width * image.height
                if image.width * image.height > MAX_GIF_PIXELS or total_pixels > MAX_GIF_TOTAL_PIXELS:
                    raise ValueError("animation exceeds decoded pixel budget")
                image.load()
                frame += 1
                try:
                    image.seek(frame)
                except EOFError:
                    break
    except (UnidentifiedImageError, OSError, ValueError, EOFError, IndexError, StructError) as exc:
        raise AppError(code="MOMENT_MEDIA_INVALID", message="GIF 文件已损坏", status_code=422) from exc


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
            raise AppError(code="MOMENT_MEDIA_INVALID", message="仅支持20MiB以内 JPG/PNG/WebP/GIF", status_code=422)
        with self.factory.begin() as session:
            old = session.scalar(select(MomentMediaUpload).where(MomentMediaUpload.owner_id == actor, MomentMediaUpload.idempotency_key == key))
            if old: return old
            now = datetime.now(timezone.utc); upload_id = str(uuid4())
            suffix = IMAGE_SUFFIX_BY_MIME[mime_type]
            directory = "moments/covers" if purpose == "MOMENT_COVER" else "moments"
            row = MomentMediaUpload(id=upload_id, owner_id=actor, file_name=file_name, mime_type=mime_type, byte_size=byte_size, status="PENDING", object_key=f"{directory}/{actor}/{upload_id}{suffix}", purpose=purpose, idempotency_key=key, created_at=now, expires_at=now + timedelta(minutes=30))
            session.add(row); return row
    def complete(self, actor, upload_id):
        with self.factory.begin() as session:
            row = session.scalar(select(MomentMediaUpload).where(
                MomentMediaUpload.id == upload_id).with_for_update())
            if not row or row.owner_id != actor: raise AppError(code="MOMENT_MEDIA_NOT_FOUND", message="上传不存在", status_code=404)
            if row.status == "COMPLETED":
                return row
            if row.expires_at.replace(tzinfo=row.expires_at.tzinfo or timezone.utc) <= datetime.now(timezone.utc): raise AppError(code="MOMENT_MEDIA_EXPIRED", message="上传已过期", status_code=409)
            if row.status != "UPLOADED":
                row.status = "SCANNING"
            else:
                row.status = "COMPLETED"
            return row

    def put_content(self, actor, upload_id, content, content_type):
        with self.factory.begin() as session:
            row = session.scalar(select(MomentMediaUpload).where(
                MomentMediaUpload.id == upload_id).with_for_update())
            if not row or row.owner_id != actor:
                raise AppError(code="MOMENT_MEDIA_NOT_FOUND", message="上传不存在", status_code=404)
            if row.status == "COMPLETED":
                raise AppError(code="MOMENT_MEDIA_COMPLETED", message="已完成的媒体不可覆盖，请重新上传", status_code=409)
            if content_type != row.mime_type or len(content) != row.byte_size:
                raise AppError(code="MOMENT_MEDIA_INVALID", message="媒体内容校验失败", status_code=422)
            if content[:6] in (b"GIF87a", b"GIF89a") and row.mime_type != "image/gif":
                raise AppError(code="MOMENT_MEDIA_INVALID", message="媒体格式与声明不一致", status_code=422)
            if row.mime_type == "image/gif":
                validate_gif(content)
            if self.storage:
                self.storage.put(row.object_key, content)
            row.status = "UPLOADED"
            return row
