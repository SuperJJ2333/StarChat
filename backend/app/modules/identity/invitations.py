from datetime import datetime, timedelta, timezone
from hashlib import sha256
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.modules.identity.models import Invitation


def hash_opaque_token(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()


def normalize_invitation_reason(reason: str) -> str:
    allowed = {"OK", "INVALID", "EXPIRED", "EXHAUSTED"}
    return reason if reason in allowed else "INVALID"


class InvitationService:
    def __init__(self, session_factory, now_factory=None) -> None:
        self._session_factory = session_factory
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def issue(
        self,
        *,
        code: str,
        max_uses: int,
        expires_at: datetime,
        created_by: str,
    ) -> Invitation:
        if max_uses < 1:
            raise ValueError("max_uses must be positive")
        invitation = Invitation(
            id=str(uuid4()),
            code_hash=hash_opaque_token(code),
            max_uses=max_uses,
            use_count=0,
            expires_at=expires_at,
            created_by=created_by,
            created_at=self._now_factory(),
        )
        with self._session_factory.begin() as session:
            session.add(invitation)
        return invitation

    def validate(self, code: str) -> str:
        """校验邀请码，返回原因码：OK / INVALID / EXPIRED / EXHAUSTED。

        客户端据此区分"码无效 / 已过期 / 次数用尽"，替代单一布尔。
        """
        now = self._now_factory()
        with self._session_factory() as session:
            invitation = session.scalar(
                select(Invitation).where(
                    Invitation.code_hash == hash_opaque_token(code),
                    Invitation.revoked_at.is_(None),
                )
            )
            if invitation is None:
                return "INVALID"
            expires_at = invitation.expires_at
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            if expires_at < now:
                return "EXPIRED"
            if invitation.use_count >= invitation.max_uses:
                return "EXHAUSTED"
            return "OK"

    @staticmethod
    def consume_in_session(session, *, code: str, now: datetime) -> Invitation:
        code_clean = code.strip()
        if not code_clean:
            raise AppError(
                code="INVITATION_REQUIRED",
                message="请输入邀请码",
                status_code=422,
            )
        invitation = session.scalar(
            select(Invitation)
            .where(Invitation.code_hash == hash_opaque_token(code_clean))
            .with_for_update()
        )
        if invitation is None or invitation.revoked_at is not None:
            raise AppError(
                code="INVITATION_INVALID",
                message="邀请码无效",
                status_code=400,
            )
        expires_at = invitation.expires_at
        if expires_at.tzinfo is None and now.tzinfo is not None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < now:
            raise AppError(
                code="INVITATION_EXPIRED",
                message="邀请码已过期",
                status_code=400,
            )
        if invitation.use_count >= invitation.max_uses:
            raise AppError(
                code="INVITATION_EXHAUSTED",
                message="邀请码使用次数已耗尽",
                status_code=400,
            )
        consumed = session.execute(
            update(Invitation)
            .where(
                Invitation.id == invitation.id,
                Invitation.use_count < Invitation.max_uses,
            )
            .values(use_count=Invitation.use_count + 1)
            .execution_options(synchronize_session=False)
        )
        if consumed.rowcount != 1:
            session.refresh(invitation)
            raise AppError(
                code="INVITATION_EXHAUSTED",
                message="邀请码使用次数已耗尽",
                status_code=400,
            )
        session.refresh(invitation)
        return invitation

    def ensure_personal(
        self,
        *,
        user_id: str,
        codec,
        max_uses: int,
        expiry_days: int,
    ) -> dict:
        """发布/刷新当前用户的固定个人注册邀请码（统一邀请码体系）。

        码由 ``codec.derive_static(user_id)`` 确定性派生（永不轮换），
        首次读取时落 ``invitations`` 行（created_by=user），此后仅滚动
        续期 expires_at（次数不重置）。经既有 validate / consume 链路
        生效——哈希算法一致（sha256(去空格大写码)）。
        """
        if max_uses < 1:
            raise ValueError("max_uses must be positive")
        now = self._now_factory()
        code = codec.derive_static(user_id)
        code_hash = hash_opaque_token(code)
        expires_at = now + timedelta(days=expiry_days)
        result: dict = {}
        try:
            with self._session_factory.begin() as session:
                invitation = session.scalar(
                    select(Invitation).where(Invitation.code_hash == code_hash)
                )
                if invitation is None:
                    invitation = Invitation(
                        id=str(uuid4()),
                        code_hash=code_hash,
                        max_uses=max_uses,
                        use_count=0,
                        expires_at=expires_at,
                        created_by=user_id,
                        created_at=now,
                    )
                    session.add(invitation)
                else:
                    # 滚动续期保持个人码长期可用；max_uses/use_count 不动。
                    invitation.expires_at = expires_at
                session.flush()
                expires_iso = invitation.expires_at
                if expires_iso.tzinfo is None:
                    expires_iso = expires_iso.replace(tzinfo=timezone.utc)
                # 提交（块退出）前捕获快照，避免提交后访问过期属性。
                result = {
                    "code": code,
                    "max_uses": invitation.max_uses,
                    "use_count": invitation.use_count,
                    "expires_at": expires_iso.isoformat(),
                }
        except IntegrityError as exc:
            # 与既有码哈希碰撞（约 2^40 空间，极小概率）或并发首读冲突。
            raise AppError(
                code="INVITATION_CODE_BUSY",
                message="邀请码生成繁忙，请重试",
                status_code=503,
            ) from exc
        return result
