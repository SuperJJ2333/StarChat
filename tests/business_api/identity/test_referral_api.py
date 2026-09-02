"""Referral 邀请码（30 分钟轮换）API 与服务测试。

覆盖需求：
- 当前用户专属邀请码 + 30 分钟窗口轮换，旧码窗口切换后立即失效；
- 公开校验接口限流、失败不枚举、不回显邀请人；
- 注册时选填 referral_code，同一事务绑定，重放不重复绑定；
- 无效推荐码不阻断注册（管理员邀请码仍是硬门槛）；
- 万级用户规模下的校验性能（纯 HMAC，无 DB 查询）。
"""

from datetime import datetime, timedelta, timezone
from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import ReferralBinding, User
from app.modules.identity.referral import ReferralCodec, ReferralService
from app.modules.identity.tokens import TokenService

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
REFERRAL_SECRET = "test-referral-code-secret-32-bytes-min"
PASSWORD = "correct horse battery staple"


class RecordingRateLimiter:
    def __init__(self) -> None:
        self.calls: list[tuple[str, int, int]] = []

    def hit(self, key: str, *, limit: int, window_seconds: int) -> None:
        self.calls.append((key, limit, window_seconds))


class ThrottlingRateLimiter(RecordingRateLimiter):
    """超过 limit 后抛 429（模拟 RedisRateLimiter 行为）。"""

    def hit(self, key: str, *, limit: int, window_seconds: int) -> None:
        super().hit(key, limit=limit, window_seconds=window_seconds)
        same_key = [c for c in self.calls if c[0] == key]
        if len(same_key) > limit:
            raise AppError(
                code="RATE_LIMITED",
                message="请求过于频繁，请稍后再试",
                status_code=429,
            )


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
            display_name="Referral test device",
        )
        .access_token
    )


@pytest.fixture()
def referral_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    InvitationService(factory).issue(
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
        session.add(
            User(
                id="banned-user",
                username="banned",
                username_normalized="banned",
                email="banned@example.com",
                email_normalized="banned@example.com",
                password_hash="hash",
                status=AccountStatus.SUSPENDED,
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )
    settings = _settings()
    yield create_app(settings, session_factory=factory), factory
    engine.dispose()


def _register(client: dict, *, username: str, email: str, referral: str | None, key: str):
    payload = {
        "username": username,
        "email": email,
        "password": PASSWORD,
        "invitation_code": "API-INVITE",
    }
    if referral is not None:
        payload["referral_code"] = referral
    return client.post(
        "/api/v1/auth/register",
        headers={"Idempotency-Key": key},
        json=payload,
    )


@pytest.mark.asyncio
async def test_referral_current_code_requires_auth(referral_components) -> None:
    app, _ = referral_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/invitations/referral")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_current_code_shape_and_short_term_stability(referral_components) -> None:
    app, factory = referral_components
    auth = {"Authorization": f"Bearer {_token(factory, 'inviter-user')}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await client.get("/api/v1/invitations/referral", headers=auth)
        second = await client.get("/api/v1/invitations/referral", headers=auth)
    assert first.status_code == 200
    body = first.json()
    code = body["code"]
    assert len(code) == 8
    assert code.isalnum()
    assert 0 < body["rotates_in_seconds"] <= 1800
    assert body["rotates_at"]
    assert code in body["share_url"]
    # 同一窗口内两次获取返回同一码。
    assert second.json()["code"] == code


def test_codec_rotates_and_old_window_code_stops_validating() -> None:
    anchor = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
    early = anchor + timedelta(minutes=5)
    late = anchor + timedelta(minutes=35)
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    code_early = codec.derive("inviter-user", early)
    assert code_early == codec.derive("inviter-user", anchor)
    assert code_early != codec.derive("inviter-user", late)
    # 窗口切换后，旧码按"当前时间"校验失败。
    assert codec.window_index(early) != codec.window_index(late)
    # 不同用户码不同；确定可复现（多实例一致）。
    assert code_early != codec.derive("other-user", early)
    assert codec.derive("inviter-user", early) == ReferralCodec(
        secret=REFERRAL_SECRET, rotation_seconds=1800
    ).derive("inviter-user", early)
    # 码字符表无易混字符（0/O/1/I/L 缺席）。
    allowed = set(ReferralCodec.ALPHABET)
    assert set(code_early) <= allowed
    assert not ({"0", "O", "1", "I", "L"} & allowed)


def test_service_resolve_and_bind_in_session(referral_components) -> None:
    _, factory = referral_components
    now = datetime.now(timezone.utc)
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    code = codec.derive("inviter-user", now)
    service = ReferralService(
        factory, codec=codec, now_factory=lambda: now
    )
    # 邀请人先"发布"当前窗口码（客户端打开邀请页即触发）。
    published = service.current_code("inviter-user")
    assert published["code"] == code
    assert published["rotates_in_seconds"] > 0
    with factory.begin() as session:
        binding = service.bind_in_session(
            session,
            invited_user_id="new-user",
            referral_code=code,
            now=now,
        )
        assert binding.inviter_user_id == "inviter-user"
        assert binding.code_window_index == codec.window_index(now)
        assert len(binding.code_hash) == 64  # 仅存 sha256
        assert binding.code_hash != code.casefold()
        assert binding.reward_state == "NOT_CONFIGURED"
    assert service.peek(code) is True
    # 重复绑定同一名新用户 → 幂等冲突。
    with pytest.raises(AppError) as excinfo:
        with factory.begin() as session:
            service.bind_in_session(
                session,
                invited_user_id="new-user",
                referral_code=code,
                now=now,
            )
    assert excinfo.value.code == "REFERRAL_ALREADY_BOUND"
    # 停用邀请人的码不可绑定（静默跳过，不抛错）。
    banned_code = codec.derive("banned-user", now)
    service.current_code("banned-user")
    assert service.peek(banned_code) is False
    with factory.begin() as session:
        assert (
            service.bind_in_session(
                session,
                invited_user_id="another-user",
                referral_code=banned_code,
                now=now,
            )
            is None
        )


def test_stale_window_code_is_rejected_after_rotation(referral_components) -> None:
    """窗口切换后旧码立即失效：发布表停留在旧窗口 → 反查命中但窗口不匹配。"""
    _, factory = referral_components
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    earlier = datetime.now(timezone.utc) - timedelta(minutes=35)
    now = datetime.now(timezone.utc)
    service_earlier = ReferralService(
        factory, codec=codec, now_factory=lambda: earlier
    )
    old_code = service_earlier.current_code("inviter-user")["code"]
    service_now = ReferralService(
        factory, codec=codec, now_factory=lambda: now
    )
    assert service_now.peek(old_code) is False
    with factory.begin() as session:
        assert (
            service_now.bind_in_session(
                session,
                invited_user_id="late-user",
                referral_code=old_code,
                now=now,
            )
            is None
        )


@pytest.mark.asyncio
async def test_register_with_referral_code_binds_and_audits(referral_components) -> None:
    app, factory = referral_components
    now = datetime.now(timezone.utc)
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    # 真实流程：邀请人打开"邀请码"页 → 发布当前窗口码 → 好友注册时填写。
    ReferralService(factory, codec=codec, now_factory=lambda: now).current_code(
        "inviter-user"
    )
    code = codec.derive("inviter-user", now)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await _register(
            client,
            username="newbie",
            email="newbie@example.com",
            referral=code,
            key="referral-bind-1",
        )
        assert created.status_code == 202
        # 重放同一幂等键：不得产生第二条绑定。
        replay = await _register(
            client,
            username="newbie",
            email="newbie@example.com",
            referral=code,
            key="referral-bind-1",
        )
        assert replay.status_code == 202
    with factory() as session:
        bindings = session.scalars(select(ReferralBinding)).all()
        assert len(bindings) == 1
        assert bindings[0].inviter_user_id == "inviter-user"
        invited_id = bindings[0].invited_user_id
        audits = session.scalars(
            select(AuditEvent).where(AuditEvent.action == "identity.referral.bound")
        ).all()
        assert len(audits) == 1
        assert audits[0].subject_id == invited_id


@pytest.mark.asyncio
async def test_register_with_invalid_referral_still_succeeds(referral_components) -> None:
    app, factory = referral_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await _register(
            client,
            username="noref",
            email="noref@example.com",
            referral="WRONGCODE",
            key="referral-invalid-1",
        )
    assert response.status_code == 202
    with factory() as session:
        assert session.scalars(select(ReferralBinding)).all() == []


@pytest.mark.asyncio
async def test_referral_validate_endpoint_limiting_and_behavior(referral_components) -> None:
    app, factory = referral_components
    now = datetime.now(timezone.utc)
    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    ReferralService(factory, codec=codec, now_factory=lambda: now).current_code(
        "inviter-user"
    )
    code = codec.derive("inviter-user", now)
    limiter = RecordingRateLimiter()
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    limited_app = create_app(
        _settings(), session_factory=factory, rate_limiter=limiter
    )
    async with AsyncClient(
        transport=ASGITransport(app=limited_app), base_url="http://test"
    ) as client:
        good = await client.post(
            "/api/v1/invitations/referral/validate",
            json={"referral_code": code},
        )
        bad = await client.post(
            "/api/v1/invitations/referral/validate",
            json={"referral_code": "ZZZZZZZZ"},
        )
    assert good.status_code == 200
    assert good.json() == {"valid": True}
    assert bad.status_code == 200
    assert bad.json() == {"valid": False}
    # 限流存在：每次命中都记录，且包含针对码的窄桶与针对 IP 的宽桶。
    keys = [c[0] for c in limiter.calls]
    assert any(k.startswith("referral:validate:code:") for k in keys)
    assert any(k.startswith("referral:validate:ip:") for k in keys)
    engine.dispose()


@pytest.mark.asyncio
async def test_referral_validate_blocks_brute_force_after_limit() -> None:
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    limiter = ThrottlingRateLimiter()
    app = create_app(_settings(), session_factory=factory, rate_limiter=limiter)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        codes = [
            {"referral_code": f"GUESS{i:04d}"} for i in range(40)
        ]
        responses = [
            await client.post("/api/v1/invitations/referral/validate", json=payload)
            for payload in codes
        ]
    assert any(r.status_code == 429 for r in responses)
    engine.dispose()


def test_validation_throughput_supports_ten_thousand_users() -> None:
    """万级用户规模：单码校验为 1 次 HMAC，1000 次校验应在 1s 内完成
    （对应需求"响应不超过 200ms"留出 5 倍裕量）。"""
    import time

    codec = ReferralCodec(secret=REFERRAL_SECRET, rotation_seconds=1800)
    now = datetime.now(timezone.utc)
    code = codec.derive("inviter-user", now)
    start = time.perf_counter()
    matched = 0
    for _ in range(1000):
        if codec.matches("inviter-user", code, now):
            matched += 1
    elapsed = time.perf_counter() - start
    assert matched == 1000
    assert elapsed < 1.0, f"1000 validations took {elapsed:.3f}s"
