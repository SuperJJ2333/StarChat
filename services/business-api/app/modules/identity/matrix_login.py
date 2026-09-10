from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from secrets import token_urlsafe
from sqlalchemy import select, delete

from app.core.errors import AppError
from app.integrations.matrix_admin import MatrixAdminGateway
from app.modules.identity.enums import AccountStatus
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import (User, RefreshTokenFamily, AdminSession,
    MatrixLoginGrant, MatrixLoginGeneration, MobileMatrixSession)


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

    def issue(self, user_id: str, *, family_id: str | None = None) -> MatrixLoginToken:
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if family_id is not None:
                family = session.get(RefreshTokenFamily, family_id)
                if family is None or family.user_id != user_id or family.revoked_at is not None:
                    raise AppError(code='SESSION_REPLACED', message='账号已在其他设备登录，请重新登录', status_code=401)
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

            if family_id is None:
                # Trusted internal callers retain the native provisioning bridge.
                login_token = self._gateway.issue_login_token(matrix_user_id, self._expires_in)
            else:
                admin = session.get(AdminSession, user_id)
                if admin is not None and admin.family_id == family_id:
                    raise AppError(code='MATRIX_LOGIN_FORBIDDEN', message='需要移动端会话', status_code=403)
                login_token = token_urlsafe(48)
                # Keep the grant ledger bounded; generations are retained permanently.
                session.execute(delete(MatrixLoginGrant).where(MatrixLoginGrant.user_id == user_id,
                    MatrixLoginGrant.expires_at < datetime.now(timezone.utc) - timedelta(days=1)))
                session.add(MatrixLoginGrant(token_hash=sha256(login_token.encode()).hexdigest(),
                    user_id=user_id, family_id=family_id,
                    expires_at=datetime.now(timezone.utc) + timedelta(seconds=self._expires_in)))
        return MatrixLoginToken(
            login_token=login_token,
            homeserver=self._public_homeserver_url,
            expires_in=self._expires_in,
            matrix_user_id=matrix_user_id,
        )

    def consume(self, body: dict) -> dict:
        def invalid():
            return AppError(code='M_FORBIDDEN', message='登录授权已失效，请重试', status_code=403)

        token = body.get('token')
        device_id = body.get('device_id')
        if device_id is None:
            device_id = token_urlsafe(18)
        display_name = body.get('initial_device_display_name')
        if (body.get('type') != 'm.login.token' or not isinstance(token, str)
                or not 1 <= len(token) <= 8192 or not isinstance(device_id, str)
                or not 1 <= len(device_id) <= 255
                or (display_name is not None and (not isinstance(display_name, str) or len(display_name) > 255))):
            raise invalid()
        digest = sha256(token.encode()).hexdigest()
        # Commit the one-time intent before any request whose remote result can be unknown.
        with self._session_factory.begin() as session:
            owner = session.scalar(select(MatrixLoginGrant.user_id).where(MatrixLoginGrant.token_hash == digest))
            if owner is None:
                raise invalid()
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            grant = session.get(MatrixLoginGrant, digest)
            now = datetime.now(timezone.utc)
            if (grant is None or grant.consumed_at is not None
                    or grant.expires_at.replace(tzinfo=timezone.utc) <= now):
                raise invalid()
            family_id = grant.family_id
            deadline = grant.expires_at.replace(tzinfo=timezone.utc)
            self._check_current(session, user, family_id)
            grant.consumed_at = now
            row = session.get(MatrixLoginGeneration, owner)
            if row is None:
                row = MatrixLoginGeneration(user_id=owner, generation=1)
                session.add(row)
            else:
                row.generation += 1
            generation = row.generation
            AuditWriter(self._session_factory).record_in_session(session,
                actor_id=owner, subject_type='user', subject_id=owner,
                action='identity.matrix.login.consumed', result='PENDING',
                reason_code='MOBILE_SINGLE_DEVICE', trace_id=family_id)
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == owner).with_for_update())
            self._check_current(session, user, family_id)
            # A newer consumed intent wins even if this request reached this phase late.
            if (session.get(MatrixLoginGeneration, owner).generation != generation
                    or datetime.now(timezone.utc) >= deadline):
                raise invalid()
            result = self._gateway.complete_mobile_login(matrix_user_id=user.matrix_user_id,
                device_id=device_id, generation=generation, display_name=display_name)
            if (result.get('user_id') != user.matrix_user_id or result.get('device_id') != device_id
                    or not isinstance(result.get('access_token'), str) or not result['access_token']
                    or 'refresh_token' in result
                    or ('expires_in_ms' in result and (type(result['expires_in_ms']) is not int or result['expires_in_ms'] < 0))):
                raise AppError(code='MATRIX_LOGIN_PENDING', message='聊天登录尚未完成，请重试', status_code=503)
            current = session.get(MobileMatrixSession, owner)
            if current is None:
                current = MobileMatrixSession(user_id=owner, family_id=family_id,
                    matrix_device_id=device_id, updated_at=datetime.now(timezone.utc))
                session.add(current)
            else:
                current.family_id = family_id
                current.matrix_device_id = device_id
                current.updated_at = datetime.now(timezone.utc)
            AuditWriter(self._session_factory).record_in_session(session,
                actor_id=owner, subject_type='user', subject_id=owner,
                action='identity.matrix.login.completed', result='SUCCESS',
                reason_code='MOBILE_SINGLE_DEVICE', trace_id=family_id)
            response = {'user_id': result['user_id'], 'device_id': device_id, 'access_token': result['access_token']}
            if 'expires_in_ms' in result:
                response['expires_in_ms'] = result['expires_in_ms']
            return response

    @staticmethod
    def _check_current(session, user, family_id):
        family = session.get(RefreshTokenFamily, family_id)
        if (user is None or user.status != AccountStatus.ACTIVE or not user.matrix_user_id
                or family is None or family.user_id != user.id or family.revoked_at is not None):
            raise AppError(code='M_FORBIDDEN', message='登录授权已失效，请重试', status_code=403)
