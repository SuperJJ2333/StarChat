"""Referral 邀请码：用户专属、30 分钟确定性轮换。

设计要点（对应需求"每 30 分钟自动变更、旧码立即失效、校验严谨、万级用户 <200ms"）：

- 码由 ``HMAC-SHA256(secret, "{user_id}:{window_index}")`` 截断推导，
  ``window_index = epoch // 1800``：跨窗口码值必然变化，旧码无需显式注销即失效；
- 服务端只存 sha256（发布表 + 绑定记录），不落明文码；
- 校验走 ``referral_invites.code_hash`` 唯一索引 O(1) 反查邀请人，
  再比对服务端当前 ``window_index``（时间戳/有效期校验在服务端完成），
  避免按码反查时的全表扫描，万级用户单次校验为一次索引命中；
- 明文码不写入日志与审计。
"""

import hmac
from datetime import datetime, timezone
from hashlib import sha256
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import ReferralBinding, ReferralInvite, User


class ReferralCodec:
    """确定性轮换码编解码（纯函数，可注入时钟测试）。"""

    # 32 个无易混字符（剔除 0/O/1/I/L），8 位码约 2^40 空间，配合限流防枚举。
    ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

    CODE_LENGTH = 8

    def __init__(self, *, secret: str, rotation_seconds: int = 1800) -> None:
        if rotation_seconds <= 0:
            raise ValueError("rotation_seconds must be positive")
        if len(secret) < 16:
            raise ValueError("referral secret must be at least 16 characters")
        self._secret = secret.encode("utf-8")
        self._rotation_seconds = rotation_seconds

    def window_index(self, now: datetime) -> int:
        return int(self._epoch_seconds(now)) // self._rotation_seconds

    def derive(self, user_id: str, now: datetime) -> str:
        digest = hmac.new(
            self._secret,
            f"{user_id}:{self.window_index(now)}".encode("utf-8"),
            sha256,
        ).digest()
        return self._encode(digest)

    def derive_static(self, user_id: str) -> str:
        """用户固定的个人注册邀请码（统一邀请码体系，永不轮换）。

        与轮换码域隔离（"personal-invite:" 前缀）；明文可随时确定性
        重derive，库中仍只存 sha256。
        """
        digest = hmac.new(
            self._secret,
            f"personal-invite:{user_id}".encode("utf-8"),
            sha256,
        ).digest()
        return self._encode(digest)

    def _encode(self, digest: bytes) -> str:
        value = int.from_bytes(digest[:8], "big")
        alphabet = self.ALPHABET
        base = len(alphabet)
        chars: list[str] = []
        for _ in range(self.CODE_LENGTH):
            chars.append(alphabet[value % base])
            value //= base
        return "".join(chars)

    @staticmethod
    def normalize(code: str) -> str:
        return (code or "").strip().upper()

    def code_hash(self, code: str) -> str:
        return sha256(self.normalize(code).encode("utf-8")).hexdigest()

    def matches(self, user_id: str, code: str, now: datetime) -> bool:
        """常数时间比较：码是否等于该用户当前窗口的码。"""
        expected = self.derive(user_id, now)
        return hmac.compare_digest(
            expected.encode("utf-8"), self.normalize(code).encode("utf-8")
        )

    def rotates_at(self, now: datetime) -> datetime:
        epoch = int(self._epoch_seconds(now))
        next_boundary = (epoch // self._rotation_seconds + 1) * self._rotation_seconds
        return datetime.fromtimestamp(next_boundary, tz=timezone.utc)

    def _epoch_seconds(self, now: datetime) -> float:
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        return now.timestamp()


class ReferralService:
    """当前码发布 + 邀请关系绑定（绑定在调用方事务内完成）。"""

    def __init__(self, session_factory, *, codec: ReferralCodec, now_factory=None) -> None:
        self._session_factory = session_factory
        self._codec = codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def current_code(self, user_id: str) -> dict:
        """发布/刷新当前窗口码（读取即滚动更新发布表）。

        并发首读可能撞 user_id 主键：捕获后按"读-改"重试一次
        （同一用户两次 GET 竞争时兜底，避免 500）。
        """
        now = self._now_factory()
        code = self._codec.derive(user_id, now)
        code_hash = self._codec.code_hash(code)
        window_index = self._codec.window_index(now)
        with self._session_factory.begin() as session:
            current = session.scalar(
                select(ReferralInvite).where(ReferralInvite.user_id == user_id)
            )
            if current is None:
                session.add(
                    ReferralInvite(
                        user_id=user_id,
                        code_hash=code_hash,
                        window_index=window_index,
                        updated_at=now,
                    )
                )
                try:
                    session.flush()
                except IntegrityError:
                    raise AppError(
                        code="REFERRAL_CODE_BUSY",
                        message="邀请码生成繁忙，请重试",
                        status_code=503,
                    ) from None
            elif current.code_hash != code_hash or current.window_index != window_index:
                current.code_hash = code_hash
                current.window_index = window_index
                current.updated_at = now
        rotates_at = self._codec.rotates_at(now)
        return {
            "code": code,
            "rotates_at": rotates_at.isoformat(),
            "rotates_in_seconds": max(0, int((rotates_at - now).total_seconds())),
            "window_index": window_index,
        }

    def peek(self, code: str) -> bool:
        """公开校验：只回答有效/无效，不回显邀请人（独立短事务）。"""
        try:
            with self._session_factory() as session:
                self._resolve_in_session(session, code)
        except AppError:
            return False
        return True

    def bind_in_session(
        self, session, *, invited_user_id: str, referral_code: str, now: datetime
    ) -> ReferralBinding | None:
        """在调用方事务内绑定邀请关系；码无效/邀请人不可用时返回 None。

        抛出 ``REFERRAL_ALREADY_BOUND``：同一名新用户重复绑定（防御性，
        注册路径由唯一约束 + 幂等键双重保证）。
        """
        try:
            inviter_id = self._resolve_in_session(session, referral_code)
        except AppError:
            return None
        if inviter_id == invited_user_id:
            return None
        binding = ReferralBinding(
            id=str(uuid4()),
            inviter_user_id=inviter_id,
            invited_user_id=invited_user_id,
            code_hash=self._codec.code_hash(referral_code),
            code_window_index=self._codec.window_index(now),
            status="ACTIVE",
            reward_state="NOT_CONFIGURED",
            bound_at=now,
            created_at=now,
        )
        session.add(binding)
        try:
            session.flush()
        except IntegrityError as exc:
            raise AppError(
                code="REFERRAL_ALREADY_BOUND",
                message="该用户已绑定邀请人",
                status_code=409,
            ) from exc
        return binding

    def _resolve_in_session(self, session, code: str) -> str:
        code_clean = self._codec.normalize(code)
        if len(code_clean) != ReferralCodec.CODE_LENGTH:
            raise AppError(
                code="REFERRAL_INVALID",
                message="邀请码无效",
                status_code=400,
            )
        now = self._now_factory()
        window_index = self._codec.window_index(now)
        published = session.scalar(
            select(ReferralInvite).where(
                ReferralInvite.code_hash == self._codec.code_hash(code_clean)
            )
        )
        if published is None:
            raise AppError(
                code="REFERRAL_INVALID",
                message="邀请码无效",
                status_code=400,
            )
        if published.window_index != window_index:
            # 旧窗口码：随轮换立即失效（服务端时间戳校验）。
            raise AppError(
                code="REFERRAL_EXPIRED",
                message="邀请码已更新，请让对方提供最新邀请码",
                status_code=400,
            )
        inviter = session.get(User, published.user_id)
        if inviter is None or inviter.status != AccountStatus.ACTIVE:
            raise AppError(
                code="REFERRAL_INVALID",
                message="邀请码无效",
                status_code=400,
            )
        return inviter.id
