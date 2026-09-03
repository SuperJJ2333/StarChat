"""统一邀请码（规格 §6.2，2026-09-03 修订）测试。

覆盖：
- ReferralCodec.derive_static：固定个人注册邀请码确定性派生、用户区分、字符表；
- GET /invitations/mine：鉴权、首次派生落库、重复读取同码、形状与分享链接；
- 个人码经既有 /invitations/validate 校验（哈希链路兼容）；
- 注册消耗个人码 → 与码归属人建立邀请关系（referral_bindings）；
- 注册消耗管理员签发码 → 不建立邀请关系；
- 旧客户端显式 referral_code 参数在未建立关系时仍兼容受理。
"""

from datetime import datetime, timedelta, timezone

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import ReferralBinding, User
from app.modules.identity.referral import ReferralCodec
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
REFERRAL_SECRET = "test-referral-code-secret-32-bytes-min"
PASSWORD = "correct horse battery staple"


def _settings() -> Settings:
    return Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        referral_code_secret=REFERRAL_SECRET,
    )


def _token(factory, user_id: str) -> str:
    return (
        TokenService(
            factory,
            jwt_secret=JWT_SECRET,
            jwt_issuer="liuhetong",
        )
        .issue_pair(
            user_id=user_id,
            device_key=f"device-{user_id}",
            display_name="Personal invite test device",
        )
        .access_token
    )


@pytest.fixture()
def personal_invite_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    invitation_service = InvitationService(factory)
    # 管理员签发的注册邀请码（非个人码）。
    invitation_service.issue(
        code="API-INVITE",
        max_uses=10,
        expires_at=now + timedelta(days=1),
        created_by="admin-1",
    )
    with factory.begin() as session:
        session.add(
            User(
                id="inviter-user",
                username="inviter",
                username_normalized="inviter",
                email="inviter@example.com",
                email_normalized="inviter@example.com",
                password_hash="hash",
                status=AccountStatus.ACTIVE,
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    settings = _settings()
    yield create_app(settings, session_factory=factory), factory, invitation_service
    engine.dispose()


def _register(client, *, username: str, email: str, invitation: str, key: str, referral: str | None = None):
    payload = {
        "username": username,
        "email": email,
        "password": PASSWORD,
        "invitation_code": invitation,
    }
    if referral is not None:
        payload["referral_code"] = referral
    return client.post(
        "/api/v1/auth/register",
        headers={"Idempotency-Key": key},
        json=payload,
    )


def test_derive_static_is_stable_and_user_scoped() -> None:
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    code = codec.derive_static("inviter-user")
    # 固定：任意时刻重复派生结果一致；与轮换码域隔离。
    assert code == codec.derive_static("inviter-user")
    assert code != codec.derive_static("other-user")
    assert code != codec.derive("inviter-user", datetime.now(timezone.utc))
    # 字符表与长度：8 位、无易混字符。
    assert len(code) == 8
    assert set(code) <= set(ReferralCodec.ALPHABET)
    assert not ({"0", "O", "1", "I", "L"} & set(code))
    # 多实例（不同 rotation 配置）同 secret 派生一致。
    assert code == ReferralCodec(
        secret=REFERRAL_SECRET, rotation_seconds=600
    ).derive_static("inviter-user")


@pytest.mark.asyncio
async def test_mine_requires_auth(personal_invite_components) -> None:
    app, _, _ = personal_invite_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/invitations/mine")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_mine_creates_stable_personal_code(personal_invite_components) -> None:
    app, factory, _ = personal_invite_components
    auth = {"Authorization": f"Bearer {_token(factory, 'inviter-user')}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await client.get("/api/v1/invitations/mine", headers=auth)
        second = await client.get("/api/v1/invitations/mine", headers=auth)
        validated = await client.post(
            "/api/v1/invitations/validate",
            json={"invitation_code": first.json()["code"]},
        )
    assert first.status_code == 200
    body = first.json()
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    assert body["code"] == codec.derive_static("inviter-user")
    assert body["max_uses"] == 20
    assert body["use_count"] == 0
    assert body["expires_at"]
    assert body["code"] in body["share_url"]
    # 重复读取：同一码（固定不轮换）。
    assert second.status_code == 200
    assert second.json()["code"] == body["code"]
    # 哈希链路兼容：个人码可经公开校验端点校验通过。
    assert validated.status_code == 200
    assert validated.json() == {"valid": True, "reason": "OK"}


@pytest.mark.asyncio
async def test_register_with_personal_code_binds_owner(personal_invite_components) -> None:
    app, factory, _ = personal_invite_components
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    personal_code = codec.derive_static("inviter-user")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # 先让邀请人打开"我"页发布个人码（生产路径一致）。
        mine = await client.get(
            "/api/v1/invitations/mine",
            headers={"Authorization": f"Bearer {_token(factory, 'inviter-user')}"},
        )
        assert mine.status_code == 200
        response = await _register(
            client,
            username="newbie",
            email="newbie@example.com",
            invitation=personal_code,
            key="register-personal-1",
        )
    assert response.status_code == 202
    with factory() as session:
        binding = session.scalar(select(ReferralBinding))
        invited = session.scalar(select(User).where(User.username == "newbie"))
        assert invited is not None
        assert binding is not None
        assert binding.inviter_user_id == "inviter-user"
        assert binding.invited_user_id == invited.id
        # 仅存 sha256（不落明文码）。
        assert len(binding.code_hash) == 64
    # 个人码被消耗一次。
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        mine_after = await client.get(
            "/api/v1/invitations/mine",
            headers={"Authorization": f"Bearer {_token(factory, 'inviter-user')}"},
        )
    assert mine_after.json()["use_count"] == 1


@pytest.mark.asyncio
async def test_register_with_admin_code_creates_no_binding(personal_invite_components) -> None:
    app, factory, _ = personal_invite_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await _register(
            client,
            username="admininvited",
            email="admininvited@example.com",
            invitation="API-INVITE",
            key="register-admin-1",
        )
    assert response.status_code == 202
    with factory() as session:
        assert session.scalar(select(ReferralBinding)) is None


@pytest.mark.asyncio
async def test_legacy_referral_code_still_binds(personal_invite_components) -> None:
    """旧客户端（注册页仍提交 referral_code）过渡期兼容。"""
    app, factory, _ = personal_invite_components
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    now = datetime.now(timezone.utc)
    rotating = codec.derive("inviter-user", now)
    # 邀请人先发布当前窗口轮换码。
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        published = await client.get(
            "/api/v1/invitations/referral",
            headers={"Authorization": f"Bearer {_token(factory, 'inviter-user')}"},
        )
        assert published.status_code == 200
        response = await _register(
            client,
            username="legacyclient",
            email="legacy@example.com",
            invitation="API-INVITE",
            referral=rotating,
            key="register-legacy-1",
        )
    assert response.status_code == 202
    with factory() as session:
        binding = session.scalar(select(ReferralBinding))
        assert binding is not None
        assert binding.inviter_user_id == "inviter-user"
