from datetime import datetime, timezone
from hashlib import sha256
from uuid import uuid4

from sqlalchemy import select, update

from app.core.errors import AppError
from app.modules.identity.models import Invitation


def hash_opaque_token(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()


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

    def validate(self, code: str) -> bool:
        now = self._now_factory()
        with self._session_factory() as session:
            invitation = session.scalar(
                select(Invitation).where(
                    Invitation.code_hash == hash_opaque_token(code),
                    Invitation.revoked_at.is_(None),
                    Invitation.expires_at >= now,
                    Invitation.use_count < Invitation.max_uses,
                )
            )
            return invitation is not None

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
