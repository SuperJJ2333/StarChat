from datetime import datetime, timezone
from pathlib import Path
import struct
from urllib.parse import parse_qs, unquote, urlparse
import zlib

import httpx
import pytest
from sqlalchemy import create_engine, func, select

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService


FIXTURES = Path(__file__).with_name("fixtures")
JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
NOW = datetime.now(timezone.utc)


class MemoryPrivateStorage:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    def put(self, object_key: str, content: bytes) -> None:
        self.objects[object_key] = content

    def get(self, object_key: str) -> bytes:
        return self.objects[object_key]

    def delete(self, object_key: str) -> None:
        self.objects.pop(object_key, None)

    def signed_read_url(self, object_key: str, expires_in: int) -> str:
        assert object_key in self.objects
        assert expires_in == 300
        return "https://media.example.test/private/avatar/signed"


def _components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    storage = MemoryPrivateStorage()
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
    )
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    return engine, factory, storage, app


def _add_user(factory, user_id: str, username: str, email: str) -> str:
    with factory.begin() as session:
        session.add(
            User(
                id=user_id,
                username=username,
                username_normalized=username.casefold(),
                email=email,
                email_normalized=email.casefold(),
                password_hash="hash",
                status=AccountStatus.ACTIVE,
                matrix_user_id=f"@{username.casefold()}:matrix.example.test",
                email_verified_at=NOW,
                nickname=username,
                signature=None,
                profile_updated_at=NOW,
                created_at=NOW,
                updated_at=NOW,
            )
        )
    return TokenService(
        factory,
        jwt_secret=JWT_SECRET,
        jwt_issuer="liuhetong",
        now_factory=lambda: NOW,
    ).issue_pair(
        user_id=user_id,
        device_key=f"device-{user_id}",
        display_name="Profile test device",
    ).access_token


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _png(width: int, height: int) -> bytes:
    def chunk(name: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + name
            + payload
            + struct.pack(">I", zlib.crc32(name + payload) & 0xFFFFFFFF)
        )

    scanline = b"\x00" + b"\x22\x88\xcc" * width
    pixels = scanline * height
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk("IHDR".encode(), struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels, level=9))
        + chunk(b"IEND", b"")
    )


async def _begin(client, token, key, mime_type="image/png", byte_size=98):
    return await client.post(
        "/api/v1/profile/avatar/uploads",
        headers={**_auth(token), "Idempotency-Key": key},
        json={"mime_type": mime_type, "byte_size": byte_size},
    )


@pytest.mark.asyncio
async def test_profile_read_masks_email_and_never_exposes_private_object_key() -> None:
    engine, factory, storage, app = _components()
    token = _add_user(factory, "user-1", "Alice", "alice@example.test")
    storage.put("avatars/user-1/private.png", (FIXTURES / "avatar.png").read_bytes())
    with factory.begin() as session:
        session.get(User, "user-1").avatar_object_key = "avatars/user-1/private.png"

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get("/api/v1/profile/me", headers=_auth(token))

    assert response.status_code == 200
    body = response.json()
    assert body["username"] == "Alice"
    assert body["nickname"] == "Alice"
    assert body["signature"] is None
    assert body["masked_email"] == "al***@example.test"
    assert body["avatar_url"] == "https://media.example.test/private/avatar/signed"
    assert body["avatar_fallback_seed"]
    serialized = str(body)
    assert "alice@example.test" not in serialized
    assert "avatars/user-1/private.png" not in serialized
    assert "user-1" not in serialized
    engine.dispose()


@pytest.mark.asyncio
async def test_profile_patch_is_strict_atomic_and_idempotent() -> None:
    engine, factory, _, app = _components()
    token = _add_user(factory, "user-1", "Alice", "alice@example.test")
    headers = {**_auth(token), "Idempotency-Key": "profile-update-1"}

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        first = await client.patch(
            "/api/v1/profile/me",
            headers=headers,
            json={"nickname": "  Alice Chen  ", "signature": "  Hello  "},
        )
        replay = await client.patch(
            "/api/v1/profile/me",
            headers=headers,
            json={"nickname": "  Alice Chen  ", "signature": "  Hello  "},
        )
        changed_payload = await client.patch(
            "/api/v1/profile/me",
            headers=headers,
            json={"nickname": "Different", "signature": "Hello"},
        )
        username_change = await client.patch(
            "/api/v1/profile/me",
            headers={**_auth(token), "Idempotency-Key": "profile-update-2"},
            json={"username": "mallory", "nickname": "Alice Chen"},
        )
        empty_nickname = await client.patch(
            "/api/v1/profile/me",
            headers={**_auth(token), "Idempotency-Key": "profile-update-3"},
            json={"nickname": "   "},
        )
        null_nickname = await client.patch(
            "/api/v1/profile/me",
            headers={**_auth(token), "Idempotency-Key": "profile-update-null"},
            json={"nickname": None},
        )
        long_signature = await client.patch(
            "/api/v1/profile/me",
            headers={**_auth(token), "Idempotency-Key": "profile-update-4"},
            json={"signature": "x" * 141},
        )

    assert first.status_code == replay.status_code == 200
    assert first.json() == replay.json()
    assert first.json()["nickname"] == "Alice Chen"
    assert first.json()["signature"] == "Hello"
    assert changed_payload.status_code == 409
    assert changed_payload.json()["error"]["code"] == "IDEMPOTENCY_KEY_REUSED"
    assert username_change.status_code == empty_nickname.status_code == 422
    assert null_nickname.status_code == 422
    assert long_signature.status_code == 422
    with factory() as session:
        user = session.get(User, "user-1")
        assert user.username == "Alice"
        assert user.nickname == "Alice Chen"
        assert user.signature == "Hello"
        events = list(
            session.scalars(
                select(OutboxEvent).where(
                    OutboxEvent.event_type == "identity.profile.changed"
                )
            )
        )
        audits = list(
            session.scalars(
                select(AuditEvent).where(AuditEvent.action == "identity.profile.updated")
            )
        )
        assert len(events) == len(audits) == 1
        assert events[0].payload == {"user_id": "user-1"}
    engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("mime_type", "fixture_name"),
    [
        ("image/jpeg", "avatar.jpg"),
        ("image/png", "avatar.png"),
        ("image/webp", "avatar.webp"),
    ],
)
async def test_avatar_upload_accepts_real_square_jpeg_png_and_webp(
    mime_type,
    fixture_name,
) -> None:
    engine, factory, storage, app = _components()
    token = _add_user(factory, "user-1", "Alice", "alice@example.test")
    content = (FIXTURES / fixture_name).read_bytes()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        first = await _begin(client, token, f"begin-{fixture_name}", mime_type, len(content))
        replay = await _begin(client, token, f"begin-{fixture_name}", mime_type, len(content))
        upload_id = first.json()["upload_id"]
        upload_url = first.json()["upload_url"]
        put_first = await client.put(
            upload_url,
            headers={**_auth(token), "Content-Type": mime_type},
            content=content,
        )
        put_retry = await client.put(
            upload_url,
            headers={**_auth(token), "Content-Type": mime_type},
            content=content,
        )
        complete = await client.post(
            f"/api/v1/profile/avatar/uploads/{upload_id}/complete",
            headers={**_auth(token), "Idempotency-Key": f"complete-{fixture_name}"},
        )
        complete_retry = await client.post(
            f"/api/v1/profile/avatar/uploads/{upload_id}/complete",
            headers={**_auth(token), "Idempotency-Key": f"complete-{fixture_name}"},
        )

    assert first.status_code == replay.status_code == 201
    assert first.json()["upload_id"] == replay.json()["upload_id"]
    assert put_first.status_code == put_retry.status_code == 204
    assert complete.status_code == complete_retry.status_code == 200
    assert complete.json() == complete_retry.json()
    assert complete.json()["avatar_url"].startswith("https://media.example.test/")
    with factory() as session:
        object_key = session.get(User, "user-1").avatar_object_key
        assert object_key in storage.objects
        assert session.scalar(
            select(func.count())
            .select_from(OutboxEvent)
            .where(OutboxEvent.event_type == "identity.profile.changed")
        ) == 1
    assert object_key not in str(complete.json())
    engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("declared_mime", "content", "expected_code"),
    [
        ("image/jpeg", (FIXTURES / "avatar.png").read_bytes(), "AVATAR_MIME_MISMATCH"),
        ("image/png", _png(8, 7), "AVATAR_NOT_SQUARE"),
        ("image/png", _png(1025, 1025), "AVATAR_DIMENSIONS_EXCEEDED"),
        ("image/png", b"not-an-image", "AVATAR_CONTENT_INVALID"),
    ],
)
async def test_avatar_completion_revalidates_real_mime_and_dimensions(
    declared_mime,
    content,
    expected_code,
) -> None:
    engine, factory, _, app = _components()
    token = _add_user(factory, "user-1", "Alice", "alice@example.test")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        begun = await _begin(client, token, expected_code, declared_mime, len(content))
        upload_id = begun.json()["upload_id"]
        uploaded = await client.put(
            begun.json()["upload_url"],
            headers={**_auth(token), "Content-Type": declared_mime},
            content=content,
        )
        completed = await client.post(
            f"/api/v1/profile/avatar/uploads/{upload_id}/complete",
            headers={**_auth(token), "Idempotency-Key": f"complete-{expected_code}"},
        )

    assert uploaded.status_code == 204
    assert completed.status_code == 422
    assert completed.json()["error"]["code"] == expected_code
    with factory() as session:
        assert session.get(User, "user-1").avatar_object_key is None
    engine.dispose()


@pytest.mark.asyncio
async def test_avatar_size_limits_cancellation_and_upload_ownership() -> None:
    engine, factory, storage, app = _components()
    alice = _add_user(factory, "user-1", "Alice", "alice@example.test")
    bob = _add_user(factory, "user-2", "Bob", "bob@example.test")
    content = (FIXTURES / "avatar.png").read_bytes()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        too_large = await _begin(
            client, alice, "too-large", "image/png", 5 * 1024 * 1024 + 1
        )
        begun = await _begin(client, alice, "cancel-me", "image/png", len(content))
        upload_id = begun.json()["upload_id"]
        forbidden = await client.put(
            begun.json()["upload_url"],
            headers={**_auth(bob), "Content-Type": "image/png"},
            content=content,
        )
        uploaded = await client.put(
            begun.json()["upload_url"],
            headers={**_auth(alice), "Content-Type": "image/png"},
            content=content,
        )
        cancelled = await client.delete(
            f"/api/v1/profile/avatar/uploads/{upload_id}", headers=_auth(alice)
        )
        cancel_retry = await client.delete(
            f"/api/v1/profile/avatar/uploads/{upload_id}", headers=_auth(alice)
        )
        complete_cancelled = await client.post(
            f"/api/v1/profile/avatar/uploads/{upload_id}/complete",
            headers={**_auth(alice), "Idempotency-Key": "complete-cancelled"},
        )

    assert too_large.status_code == 422
    assert too_large.json()["error"]["code"] == "AVATAR_SIZE_EXCEEDED"
    assert forbidden.status_code == 404
    assert forbidden.json()["error"]["code"] == "AVATAR_UPLOAD_NOT_FOUND"
    assert uploaded.status_code == cancelled.status_code == cancel_retry.status_code == 204
    assert complete_cancelled.status_code == 409
    assert complete_cancelled.json()["error"]["code"] == "AVATAR_UPLOAD_CANCELLED"
    assert storage.objects == {}
    engine.dispose()


@pytest.mark.asyncio
async def test_avatar_delete_restores_default_and_is_idempotent() -> None:
    engine, factory, storage, app = _components()
    token = _add_user(factory, "user-1", "Alice", "alice@example.test")
    storage.put("avatars/user-1/current.png", (FIXTURES / "avatar.png").read_bytes())
    with factory.begin() as session:
        session.get(User, "user-1").avatar_object_key = "avatars/user-1/current.png"
    headers = {**_auth(token), "Idempotency-Key": "delete-avatar-1"}

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        first = await client.delete("/api/v1/profile/avatar", headers=headers)
        replay = await client.delete("/api/v1/profile/avatar", headers=headers)
        profile = await client.get("/api/v1/profile/me", headers=_auth(token))

    assert first.status_code == replay.status_code == 204
    assert profile.json()["avatar_url"] is None
    assert profile.json()["avatar_fallback_seed"]
    assert storage.objects == {}
    with factory() as session:
        assert session.get(User, "user-1").avatar_object_key is None
        assert session.scalar(
            select(func.count())
            .select_from(OutboxEvent)
            .where(OutboxEvent.event_type == "identity.profile.changed")
        ) == 1
    engine.dispose()


def test_local_avatar_storage_uses_tamper_resistant_five_minute_urls(tmp_path) -> None:
    storage = LocalPrivateObjectStorage(
        root=str(tmp_path / "private"),
        signing_secret="test-avatar-signing-secret",
        public_base_url="https://api.example.test",
    )
    content = (FIXTURES / "avatar.png").read_bytes()
    storage.put("avatars/user-1/avatar.png", content)

    url = storage.signed_read_url("avatars/user-1/avatar.png", 300)
    parsed = urlparse(url)
    token = unquote(parsed.path.rsplit("/", 1)[-1])

    assert parsed.netloc == "api.example.test"
    assert parse_qs(parsed.query) == {"expires_in": ["300"]}
    assert "avatars/user-1/avatar.png" not in url
    assert storage.read_signed(token, 300) == (content, "image/png")
    tampered = token[:20] + ("A" if token[20] != "A" else "B") + token[21:]
    with pytest.raises(AppError, match="头像链接无效或已过期"):
        storage.read_signed(tampered, 300)
    with pytest.raises(AppError, match="头像链接无效或已过期"):
        storage.read_signed(token, 301)
