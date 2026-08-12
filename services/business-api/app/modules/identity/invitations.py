from datetime import datetime, timezone
from hashlib import sha256
from uuid import uuid4

from sqlalchemy import select

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

    @staticmethod
    def consume_in_session(session, *, code: str, now: datetime) -> Invitation:
        invitation = session.scalar(
            select(Invitation)
            .where(
                Invitation.code_hash == hash_opaque_token(code),
                Invitation.revoked_at.is_(None),
                Invitation.expires_at >= now,
                Invitation.use_count < Invitation.max_uses,
            )
            .with_for_update()
        )
        if invitation is None:
            raise AppError(
                code="INVITATION_INVALID",
                message="邀请码无效或已过期",
                status_code=400,
            )
        invitation.use_count += 1
        return invitation
