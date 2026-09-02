"""服务端图片压缩接口测试（业务域媒体，非 E2EE 聊天媒体）。

覆盖需求三.3：支持 JPEG/PNG/GIF/WebP 输入，按需生成多规格尺寸；
鉴权、限流、大小/格式校验、签名读回。
"""

from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path

from httpx import ASGITransport, AsyncClient
import pytest
from PIL import Image
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


def _png_bytes(width: int = 2000, height: int = 1500, color=(30, 144, 255)) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), color).save(buffer, format="PNG")
    return buffer.getvalue()


def _jpeg_bytes(width: int = 1200, height: int = 900) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), (200, 60, 60)).save(buffer, format="JPEG")
    return buffer.getvalue()


def _gif_bytes() -> bytes:
    buffer = BytesIO()
    Image.new("P", (640, 480)).save(buffer, format="GIF")
    return buffer.getvalue()


def _webp_bytes() -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (900, 700), (10, 120, 10)).save(buffer, format="WEBP")
    return buffer.getvalue()


@pytest.fixture()
def media_components(tmp_path):
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(
            User(
                id="media-user",
                username="mediauser",
                username_normalized="mediauser",
                email="media@example.com",
                email_normalized="media@example.com",
                password_hash="hash",
                status=AccountStatus.ACTIVE,
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    storage = LocalPrivateObjectStorage(
        root=str(tmp_path / "private-media"),
        signing_secret="test-media-signing-secret-32-bytes",
        public_base_url="http://mediatest.local",
    )
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
    token = (
        TokenService(
            factory,
            jwt_secret=JWT_SECRET,
            jwt_issuer="liuhetong",
        )
        .issue_pair(
            user_id="media-user",
            device_key="device-media",
            display_name="Media test device",
        )
        .access_token
    )
    yield app, factory, storage, {"Authorization": f"Bearer {token}"}
    engine.dispose()


def _decode_image(payload: bytes) -> tuple[int, int, str]:
    with Image.open(BytesIO(payload)) as image:
        return image.width, image.height, (image.format or "").casefold()


@pytest.mark.asyncio
async def test_compress_requires_auth(media_components) -> None:
    app, _, _, _ = media_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/media/images/compress?sizes=320",
            content=_png_bytes(),
            headers={"Content-Type": "image/png"},
        )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_compress_png_to_multiple_sizes(media_components) -> None:
    app, _, storage, auth = media_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/media/images/compress?sizes=320,800",
            content=_png_bytes(2000, 1500),
            headers={**auth, "Content-Type": "image/png"},
        )
        assert response.status_code == 200
        body = response.json()
        assert body["source"]["width"] == 2000
        assert body["source"]["height"] == 1500
        assert [item["size"] for item in body["items"]] == [320, 800]
        for item in body["items"]:
            assert item["format"] == "webp"
            assert item["width"] <= item["size"]
            assert item["height"] <= item["size"]
            assert item["byte_size"] > 0
            assert item["url"].startswith("/api/v1/media/images/content/")
            # 产物可经签名读回并解码。
            read = await client.get(item["url"])
            assert read.status_code == 200
            width, height, fmt = _decode_image(read.content)
            assert fmt == "webp"
            assert max(width, height) == item["size"]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "content_type,payload",
    [
        ("image/jpeg", _jpeg_bytes()),
        ("image/gif", _gif_bytes()),
        ("image/webp", _webp_bytes()),
    ],
    ids=["jpeg", "gif", "webp"],
)
async def test_compress_accepts_common_formats(content_type, payload, media_components) -> None:
    app, _, _, auth = media_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/media/images/compress?sizes=240",
            content=payload,
            headers={**auth, "Content-Type": content_type},
        )
    assert response.status_code == 200
    assert len(response.json()["items"]) == 1


@pytest.mark.asyncio
async def test_compress_rejects_unsupported_type_and_bad_content(media_components) -> None:
    app, _, _, auth = media_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        unsupported = await client.post(
            "/api/v1/media/images/compress?sizes=320",
            content=b"GIF89a-not-really",
            headers={**auth, "Content-Type": "video/mp4"},
        )
        corrupted = await client.post(
            "/api/v1/media/images/compress?sizes=320",
            content=b"this is not an image",
            headers={**auth, "Content-Type": "image/png"},
        )
    assert unsupported.status_code == 415
    assert unsupported.json()["error"]["code"] == "MEDIA_FORMAT_UNSUPPORTED"
    assert corrupted.status_code == 422
    assert corrupted.json()["error"]["code"] == "MEDIA_INVALID"


@pytest.mark.asyncio
async def test_compress_enforces_size_and_specs_limits(media_components) -> None:
    app, _, _, auth = media_components
    huge = b"\0" * (10 * 1024 * 1024 + 1)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        too_large = await client.post(
            "/api/v1/media/images/compress?sizes=320",
            content=huge,
            headers={**auth, "Content-Type": "image/png"},
        )
        bad_spec = await client.post(
            "/api/v1/media/images/compress?sizes=999",
            content=_png_bytes(64, 64),
            headers={**auth, "Content-Type": "image/png"},
        )
        too_many = await client.post(
            "/api/v1/media/images/compress?sizes=160,240,320,480,640",
            content=_png_bytes(64, 64),
            headers={**auth, "Content-Type": "image/png"},
        )
    assert too_large.status_code == 413
    assert too_large.json()["error"]["code"] == "MEDIA_TOO_LARGE"
    assert bad_spec.status_code == 422
    assert too_many.status_code == 422


@pytest.mark.asyncio
async def test_compress_downscales_smaller_than_requested_dimensions(
    media_components,
) -> None:
    """小图不放大：请求规格大于原图最长边时，保持原尺寸输出。"""
    app, _, _, auth = media_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/media/images/compress?sizes=800",
            content=_png_bytes(300, 200),
            headers={**auth, "Content-Type": "image/png"},
        )
    assert response.status_code == 200
    item = response.json()["items"][0]
    assert (item["width"], item["height"]) == (300, 200)
