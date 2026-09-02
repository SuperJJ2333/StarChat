from dataclasses import dataclass

from app.core.errors import AppError
from app.integrations.matrix_admin import MatrixAdminGateway
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User


@dataclass(frozen=True)
class MatrixLoginToken:
    login_token: str
    homeserver: str
    expires_in: int
    matrix_user_id: str


class MatrixLoginTokenService:
    def __init__(
        self,
        session_factory,
        *,
        gateway: MatrixAdminGateway,
        public_homeserver_url: str,
        expires_in: int,
    ) -> None:
        self._session_factory = session_factory
        self._gateway = gateway
        self._public_homeserver_url = public_homeserver_url.rstrip("/")
        self._expires_in = expires_in

    def issue(self, user_id: str) -> MatrixLoginToken:
        with self._session_factory() as session:
            user = session.get(User, user_id)
            if user is None or user.status != AccountStatus.ACTIVE:
                raise AppError(
                    code="MATRIX_ACCOUNT_NOT_ACTIVE",
                    message="Matrix 账号尚未激活",
                    status_code=409,
                )
            if not user.matrix_user_id:
                raise AppError(
                    code="MATRIX_IDENTITY_UNAVAILABLE",
                    message="Matrix 身份尚未就绪",
                    status_code=409,
                )
            matrix_user_id = user.matrix_user_id

        login_token = self._gateway.issue_login_token(
            matrix_user_id,
            self._expires_in,
        )
        return MatrixLoginToken(
            login_token=login_token,
            homeserver=self._public_homeserver_url,
            expires_in=self._expires_in,
            matrix_user_id=matrix_user_id,
        )
