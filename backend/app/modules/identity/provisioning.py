from datetime import datetime, timezone

from sqlalchemy import select

from app.core.errors import AppError
from app.integrations.matrix_admin import MatrixAdminGateway, MatrixCredentialCodec
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User


class MatrixProvisionTask:
    def __init__(
        self,
        session_factory,
        *,
        gateway: MatrixAdminGateway,
        credential_codec: MatrixCredentialCodec,
        now_factory=None,
    ) -> None:
        self._session_factory = session_factory
        self._gateway = gateway
        self._credential_codec = credential_codec
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def __call__(self, message) -> None:
        if message.event_type != "identity.matrix.provision.requested":
            raise AppError(
                code="MATRIX_EVENT_UNSUPPORTED",
                message="unsupported Matrix provisioning event",
                status_code=400,
            )
        user_id = message.payload.get("user_id")
        if (
            not user_id
            or message.aggregate_type != "user"
            or message.aggregate_id != user_id
        ):
            raise AppError(
                code="MATRIX_EVENT_INVALID",
                message="Matrix provisioning event does not match its aggregate",
                status_code=400,
            )
        with self._session_factory() as session:
            user = session.get(User, user_id)
            if user is None:
                self._not_ready("MATRIX_USER_NOT_FOUND", "identity user not found")
            if user.status == AccountStatus.ACTIVE and user.matrix_user_id:
                return
            if user.status != AccountStatus.PENDING_MATRIX or user.email_verified_at is None:
                self._not_ready("MATRIX_USER_NOT_READY", "identity user is not ready")
            localpart = user.username_normalized

        matrix_user_id = self._gateway.ensure_user(
            localpart,
            self._credential_codec.password_for(user_id),
        )
        now = self._now_factory()
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if user.status == AccountStatus.ACTIVE and user.matrix_user_id == matrix_user_id:
                return
            if user.status != AccountStatus.PENDING_MATRIX:
                self._not_ready("MATRIX_USER_STATE_CONFLICT", "identity user state changed")
            user.matrix_user_id = matrix_user_id
            user.status = AccountStatus.ACTIVE
            user.updated_at = now

    @staticmethod
    def _not_ready(code: str, message: str) -> None:
        raise AppError(code=code, message=message, status_code=409)
