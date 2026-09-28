"""Staff-only change of the shared business login password."""
from datetime import datetime, timezone

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import AdminSession, Device, RefreshToken, RefreshTokenFamily, User, UserRole
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.staff_activation import STAFF_ROLES, require_staff_admin_access


class StaffPasswordService:
    def __init__(self, session_factory, *, tokens, recovery, now_factory=None) -> None:
        self._session_factory = session_factory
        self._tokens = tokens
        self._recovery = recovery
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def change(self, *, access_token: str, refresh_cookie: str, current_password: str,
               new_password: str, trace_id: str, source_ip: str | None = None) -> None:
        claims = self._tokens.decode_access_token(access_token)
        if claims.get('session_scope') != 'admin':
            raise AppError(code='ADMIN_SESSION_REQUIRED', message='请登录管理后台', status_code=401)
        self._tokens.require_admin_cookie(access_token, refresh_cookie)
        now = self._now_factory()
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == claims['sub']).with_for_update())
            if user is None or user.status != AccountStatus.ACTIVE:
                raise AppError(code='ACCOUNT_NOT_ACTIVE', message='账号不可用', status_code=403)
            admin = session.get(AdminSession, user.id)
            family = session.get(RefreshTokenFamily, claims['family_id'])
            device = session.get(Device, claims['device_id'])
            cookie = session.scalar(select(RefreshToken).where(
                RefreshToken.token_hash == hash_opaque_token(refresh_cookie)))
            if (admin is None or admin.family_id != claims['family_id']
                    or self._utc(admin.expires_at) <= now or family is None
                    or family.user_id != user.id or family.device_id != claims['device_id']
                    or family.revoked_at is not None or device is None
                    or device.user_id != user.id or device.revoked_at is not None
                    or cookie is None or cookie.family_id != family.id
                    or cookie.consumed_at is not None or self._utc(cookie.expires_at) <= now):
                raise AppError(code='ADMIN_SESSION_REQUIRED', message='请登录管理后台', status_code=401)
            if admin.entry_mode != AdminSession.ENTRY_STAFF:
                raise AppError(code='ADMIN_SESSION_REPLACED',
                    message='管理入口已不适用，请重新登录', status_code=401)
            roles = set(session.scalars(select(UserRole.role_code).where(UserRole.user_id == user.id)).all())
            if RoleCode.SUPER_ADMIN in roles or not roles.intersection(STAFF_ROLES):
                raise AppError(code='PERMISSION_DENIED', message='无权执行此操作', status_code=403)
            require_staff_admin_access(session, user)
            if not PasswordHasher().verify(user.password_hash, current_password):
                raise AppError(code='CREDENTIALS_INVALID', message='当前密码错误', status_code=401)
            self._recovery.reset_in_session(session, user, new_password,
                trace_id=trace_id, source_ip=source_ip)

    @staticmethod
    def _utc(value: datetime) -> datetime:
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)
