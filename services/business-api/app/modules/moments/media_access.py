"""Viewer-scoped media capabilities, checked against live Moment visibility."""
import json
from pathlib import Path
from urllib.parse import urlparse, unquote
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.moments.media import MomentMediaUpload
from app.modules.moments.models import Moment, MomentComment
from app.modules.moments.visibility import VisibilityPolicy, moment_comment_audience


def invalid(status=404):
    raise AppError(code="MOMENT_MEDIA_INVALID", message="动态媒体不可用", status_code=status)


def resolve_reference(storage, reference):
    if reference.startswith("media://moments/"):
        return reference[len("media://"):]
    capability_marker = "/api/v1/moments/media/content/"
    if capability_marker in urlparse(reference).path and hasattr(storage, "decode_key"):
        try:
            data = json.loads(storage.decode_key(urlparse(reference).path.split(capability_marker, 1)[1]))
            if data.get("domain") in ("moment-media-v1", "moment-upload-v1"):
                return data["key"]
        except (ValueError, KeyError, TypeError, AttributeError):
            pass
        invalid(422)
    marker = "/api/v1/profile/avatar/content/"
    parsed = urlparse(reference)
    if marker in parsed.path and hasattr(storage, "decode_key"):
        return storage.decode_key(unquote(parsed.path.split(marker, 1)[1]))
    invalid(422)


def owned_key(session, storage, reference, owner):
    try:
        key = resolve_reference(storage, reference)
    except AppError:
        invalid(422)
    upload = session.scalar(select(MomentMediaUpload).where(
        MomentMediaUpload.object_key == key, MomentMediaUpload.owner_id == owner,
        MomentMediaUpload.status == "COMPLETED", MomentMediaUpload.purpose == "MOMENT_IMAGE"))
    if upload is None:
        invalid(422)
    return key


def signed_url(storage, key, moment_id, viewer):
    if not viewer or not hasattr(storage, "moment_read_url"):
        return ""
    return storage.moment_read_url(json.dumps({"domain":"moment-media-v1", "key":key, "moment":moment_id, "viewer":viewer}, separators=(",", ":")))


def upload_url(storage, upload):
    if not hasattr(storage, "moment_read_url"):
        return "media://" + upload.object_key
    return storage.moment_read_url(json.dumps({"domain":"moment-upload-v1", "key":upload.object_key, "upload":upload.id, "viewer":upload.owner_id}, separators=(",", ":")))


def read_content(factory, storage, token):
    if not hasattr(storage, "decode_key"):
        invalid()
    try:
        data = json.loads(storage.decode_key(token, ttl=300))
        if data.get("domain") == "moment-upload-v1":
            with factory() as session:
                upload = session.get(MomentMediaUpload, data["upload"])
                if not upload or upload.owner_id != data["viewer"] or upload.object_key != data["key"] or upload.status != "COMPLETED" or upload.purpose != "MOMENT_IMAGE":
                    invalid()
                return storage.get(upload.object_key), upload.mime_type
        if data.get("domain") != "moment-media-v1":
            invalid()
        key, moment_id, viewer = data["key"], data["moment"], data["viewer"]
    except (AppError, ValueError, KeyError, TypeError, AttributeError):
        invalid()
    with factory() as session:
        moment = session.get(Moment, moment_id)
        if not moment or moment.deleted_at or moment.status != "PUBLISHED" or not VisibilityPolicy(session).can_view(viewer, moment):
            invalid()
        attached = False
        for reference in moment.image_urls:
            try:
                if owned_key(session, storage, reference, moment.author_id) == key:
                    attached = True
                    break
            except AppError:
                continue
        if not attached:
            comments = session.scalars(select(MomentComment).where(MomentComment.moment_id == moment_id, MomentComment.deleted_at.is_(None), MomentComment.user_id.in_(moment_comment_audience(session, viewer, moment.author_id))))
            attached = any(key in (comment.image_object_keys or []) for comment in comments)
        if not attached:
            invalid()
        mime = {".jpg":"image/jpeg", ".jpeg":"image/jpeg", ".png":"image/png", ".webp":"image/webp", ".gif":"image/gif"}.get(Path(key).suffix.lower())
        if not mime:
            invalid()
        return storage.get(key), mime
