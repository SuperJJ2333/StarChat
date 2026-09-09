from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import secrets
from uuid import uuid4

import jwt
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import AdminSession, Device, RefreshToken, RefreshTokenFamily, User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.rbac import RbacService


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    family_id: str
    device_id: str


class TokenService:
    def __init__(
        self,
        session_factory,
        *,
        jwt_secret: str,
        jwt_issuer: str,
        now_factory=None,
        access_lifetime: timedelta = timedelta(minutes=15),
        refresh_lifetime: timedelta = timedelta(days=60),
        require_session_claims: bool = True,
    ) -> None:
        if len(jwt_secret) < 32:
            raise ValueError("JWT secret must be at least 32 characters")
        self._session_factory = session_factory
        self._jwt_secret = jwt_secret
        self._jwt_issuer = jwt_issuer
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._access_lifetime = access_lifetime
        self._refresh_lifetime = refresh_lifetime
        self._require_session_claims = require_session_claims

    def issue_pair(self, *, user_id: str, device_key: str, display_name: str) -> TokenPair:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            user = session.get(User, user_id)
            if user is None or user.status.value != "ACTIVE":
                self._invalid("ACCOUNT_NOT_ACTIVE", "账号尚未激活", 403)
            device = session.scalar(
                select(Device).where(Device.user_id == user_id, Device.device_key == device_key)
            )
            if device is None:
                device = Device(
                    id=str(uuid4()),
                    user_id=user_id,
                    device_key=device_key,
                    display_name=display_name,
                    last_seen_at=now,
                    created_at=now,
                )
                session.add(device)
            else:
                device.display_name = display_name
                device.last_seen_at = now
                device.revoked_at = None
            session.flush()
            family = RefreshTokenFamily(
                id=str(uuid4()),
                user_id=user_id,
                device_id=device.id,
                created_at=now,
            )
            session.add(family)
            session.flush()
            refresh_value = self._new_refresh_token()
            session.add(self._refresh_record(family.id, refresh_value, now))
            return self._pair(user_id, device.id, family.id, refresh_value, now)

    def issue_admin_pair(self, *, user_id: str, display_name: str, password: str | None = None) -> TokenPair:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            # Stable existing user row serializes competing successful logins across workers.
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if user is None or user.status.value != 'ACTIVE':
                self._invalid('ACCOUNT_NOT_ACTIVE', '账号不可用', 403)
            if password is not None and not PasswordHasher().verify(user.password_hash, password):
                self._invalid('CREDENTIALS_INVALID', '账号或密码错误', 401)
            if not RbacService(self._session_factory).permissions_for(user_id):
                self._invalid('PERMISSION_DENIED', '无权访问管理后台', 403)
            current = session.get(AdminSession, user_id)
            if current is not None:
                old_family = session.get(RefreshTokenFamily, current.family_id)
                if old_family.revoked_at is None:
                    old_family.revoked_at = now
                    old_family.revoke_reason = 'ADMIN_SESSION_REPLACED'
            # Never reuse a supplied device key: mobile issue_pair can reactivate its device.
            device = Device(id=str(uuid4()), user_id=user_id, device_key=str(uuid4()),
                display_name=display_name, last_seen_at=now, created_at=now)
            session.add(device)
            session.flush()
            family = RefreshTokenFamily(id=str(uuid4()), user_id=user_id,
                device_id=device.id, created_at=now)
            session.add(family)
            session.flush()
            deadline = now + timedelta(hours=48)
            if current is None:
                current = AdminSession(user_id=user_id, family_id=family.id,
                    expires_at=deadline, authenticated_at=now, created_at=now)
                session.add(current)
            else:
                current.family_id = family.id
                current.expires_at = deadline
                current.authenticated_at = now
                current.created_at = now
            value = self._new_refresh_token()
            record = self._refresh_record(family.id, value, now)
            record.expires_at = deadline
            session.add(record)
            return self._pair(user_id, device.id, family.id, value, now,
                admin_deadline=deadline)

    def rotate_admin(self, refresh_token: str, *, expected_session_id: str | None = None) -> TokenPair:
        return self.rotate(refresh_token, _admin=True, _expected_session_id=expected_session_id)

    def rotate(self, refresh_token: str, *, _admin: bool = False, _expected_session_id: str | None = None) -> TokenPair:
        now = self._now_factory()
        session = self._session_factory()
        try:
            if _admin:
                owner = session.scalar(select(RefreshTokenFamily.user_id).join(
                    RefreshToken, RefreshToken.family_id == RefreshTokenFamily.id).where(
                    RefreshToken.token_hash == hash_opaque_token(refresh_token)))
                if owner is not None:
                    session.scalar(select(User).where(User.id == owner).with_for_update())
            record = session.scalar(
                select(RefreshToken)
                .where(RefreshToken.token_hash == hash_opaque_token(refresh_token))
                .with_for_update()
            )
            if record is None:
                self._invalid("REFRESH_TOKEN_INVALID", "刷新令牌无效", 401)
            family = session.scalar(
                select(RefreshTokenFamily)
                .where(RefreshTokenFamily.id == record.family_id)
                .with_for_update()
            )
            admin = session.get(AdminSession, family.user_id)
            is_admin = admin is not None and admin.family_id == family.id
            if _admin and _expected_session_id is not None and family.id != _expected_session_id:
                self._invalid('ADMIN_SESSION_REPLACED', '管理会话已切换，请重新加载页面', 401)
            if _admin and family.revoke_reason == 'ADMIN_SESSION_REPLACED':
                self._invalid('ADMIN_SESSION_REPLACED', '账号已在其他设备登录', 401)
            if is_admin != _admin:
                self._invalid('REFRESH_TOKEN_INVALID', '刷新令牌无效', 401)
            if is_admin and self._utc(admin.expires_at) <= now:
                family.revoked_at = now
                family.revoke_reason = 'ADMIN_SESSION_EXPIRED'
                session.commit()
                self._invalid('ADMIN_SESSION_EXPIRED', '管理会话已到期，请重新登录', 401)
            if record.consumed_at is not None:
                family.revoked_at = now
                family.revoke_reason = "TOKEN_REUSE"
                session.commit()
                self._invalid("REFRESH_TOKEN_REUSED", "检测到刷新令牌重复使用", 401)
            record_expires_at = record.expires_at
            if record_expires_at.tzinfo is None:
                record_expires_at = record_expires_at.replace(tzinfo=timezone.utc)
            if family.revoked_at is not None or record_expires_at <= now:
                self._invalid("REFRESH_TOKEN_INVALID", "刷新令牌无效", 401)
            device = session.get(Device, family.device_id)
            if device is None or device.revoked_at is not None:
                self._invalid("REFRESH_TOKEN_INVALID", "刷新令牌无效", 401)
            user = session.get(User, family.user_id)
            if user is None or user.status.value != "ACTIVE":
                self._invalid("ACCOUNT_NOT_ACTIVE", "账号不可用", 403)
            replacement_value = self._new_refresh_token()
            replacement = self._refresh_record(family.id, replacement_value, now)
            if is_admin:
                replacement.expires_at = admin.expires_at
            record.consumed_at = now
            record.replaced_by_id = replacement.id
            device.last_seen_at = now
            session.add(replacement)
            session.commit()
            return self._pair(
                family.user_id, device.id, family.id, replacement_value, now,
                admin_deadline=self._utc(admin.expires_at) if is_admin else None,
            )
        finally:
            session.close()

    def list_devices(self, user_id: str) -> list[Device]:
        with self._session_factory() as session:
            return list(
                session.scalars(
                    select(Device)
                    .where(Device.user_id == user_id, Device.revoked_at.is_(None))
                    .order_by(Device.created_at, Device.id)
                )
            )

    def revoke_device(self, *, user_id: str, device_id: str) -> None:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            device = session.scalar(
                select(Device)
                .where(Device.id == device_id, Device.user_id == user_id)
                .with_for_update()
            )
            if device is None:
                self._invalid("DEVICE_NOT_FOUND", "设备不存在", 404)
            device.revoked_at = now
            families = session.scalars(
                select(RefreshTokenFamily).where(
                    RefreshTokenFamily.device_id == device_id,
                    RefreshTokenFamily.revoked_at.is_(None),
                )
            )
            for family in families:
                family.revoked_at = now
                family.revoke_reason = "DEVICE_REVOKED"

    def revoke_by_refresh_token(self, refresh_token: str, reason: str = "LOGOUT") -> None:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            record = session.scalar(
                select(RefreshToken).where(
                    RefreshToken.token_hash == hash_opaque_token(refresh_token)
                )
            )
            if record is None:
                return
            family = session.get(RefreshTokenFamily, record.family_id)
            if family is not None and family.revoked_at is None:
                family.revoked_at = now
                family.revoke_reason = reason

    def decode_access_token(self, token: str) -> dict:
        try:
            claims = jwt.decode(
                token,
                self._jwt_secret,
                algorithms=["HS256"],
                issuer=self._jwt_issuer,
                options={
                    "require": ["exp", "iat", "iss", "sub"],
                    "verify_exp": False,
                    "verify_iat": False,
                },
            )
            now_timestamp = self._now_factory().timestamp()
            if int(claims["iat"]) > now_timestamp or int(claims["exp"]) <= now_timestamp:
                raise jwt.InvalidTokenError("access token is outside its validity window")
            if not claims.get("device_id") or not claims.get("family_id"):
                if not self._require_session_claims:
                    return claims
                raise jwt.InvalidTokenError("access token is missing session claims")
            with self._session_factory() as session:
                user = session.get(User, claims["sub"])
                device = session.get(Device, claims["device_id"])
                family = session.get(RefreshTokenFamily, claims["family_id"])
                admin = session.get(AdminSession, claims['sub'])
                is_admin = admin is not None and admin.family_id == claims['family_id']
                if claims.get('session_scope') == 'admin':
                    if not is_admin:
                        self._invalid('ADMIN_SESSION_REPLACED', '账号已在其他设备登录', 401)
                    if self._utc(admin.expires_at) <= self._now_factory():
                        self._invalid('ADMIN_SESSION_EXPIRED', '管理会话已到期，请重新登录', 401)
                elif is_admin:
                    raise jwt.InvalidTokenError('admin family requires management scope')
                if (
                    user is None
                    or user.status.value != "ACTIVE"
                    or device is None
                    or device.user_id != user.id
                    or device.revoked_at is not None
                    or family is None
                    or family.user_id != user.id
                    or family.device_id != device.id
                    or family.revoked_at is not None
                ):
                    raise jwt.InvalidTokenError("access token session has been revoked")
            return claims
        except jwt.PyJWTError as exc:
            raise AppError(code="ACCESS_TOKEN_INVALID", message="访问令牌无效", status_code=401) from exc

    def require_recent_login(self, token: str, *, max_age: timedelta = timedelta(minutes=5)) -> dict:
        """Require a recently created server session; refresh does not renew login age."""
        if max_age <= timedelta(0):
            raise ValueError("max_age must be positive")
        claims = self.decode_access_token(token)
        if not claims.get("family_id") or not claims.get("device_id"):
            self._invalid("RECENT_LOGIN_REQUIRED", "请重新登录后再执行此操作", 403)
        with self._session_factory() as session:
            family = session.get(RefreshTokenFamily, claims["family_id"])
            if (family is None or family.revoked_at is not None
                    or family.user_id != claims["sub"] or family.device_id != claims["device_id"]):
                self._invalid("RECENT_LOGIN_REQUIRED", "请重新登录后再执行此操作", 403)
            admin = session.get(AdminSession, claims['sub'])
            created_at = (admin.authenticated_at if admin is not None and
                admin.family_id == family.id else family.created_at)
            if created_at.tzinfo is None:
                created_at = created_at.replace(tzinfo=timezone.utc)
            if not timedelta(0) <= self._now_factory() - created_at <= max_age:
                self._invalid("RECENT_LOGIN_REQUIRED", "请重新登录后再执行此操作", 403)
        return claims

    def _pair(
        self, user_id: str, device_id: str, family_id: str, refresh_value: str, now: datetime,
        *, admin_deadline: datetime | None = None,
    ) -> TokenPair:
        access = jwt.encode(
            {
                "sub": user_id,
                "device_id": device_id,
                "family_id": family_id,
                "iss": self._jwt_issuer,
                "iat": now,
                "exp": min(now + self._access_lifetime, admin_deadline) if admin_deadline else now + self._access_lifetime,
                "jti": str(uuid4()),
                **({'session_scope': 'admin'} if admin_deadline else {}),
            },
            self._jwt_secret,
            algorithm="HS256",
        )
        return TokenPair(access, refresh_value, family_id, device_id)

    def admin_session(self, token: str) -> dict:
        claims = self.decode_access_token(token)
        if claims.get('session_scope') != 'admin':
            self._invalid('ADMIN_SESSION_REQUIRED', '请登录管理后台', 401)
        with self._session_factory() as session:
            admin = session.get(AdminSession, claims['sub'])
            if admin is None or admin.family_id != claims['family_id']:
                self._invalid('ADMIN_SESSION_REPLACED', '账号已在其他设备登录', 401)
            return {'session_expires_at': self._utc(admin.expires_at),
                'authenticated_at': self._utc(admin.authenticated_at),
                'user_id': claims['sub'], 'session_id': admin.family_id}

    def require_admin_cookie(self, token: str, cookie: str) -> None:
        claims = self.decode_access_token(token)
        self.admin_session(token)
        with self._session_factory() as session:
            record = session.scalar(select(RefreshToken).where(
                RefreshToken.token_hash == hash_opaque_token(cookie)))
            if record is None or record.family_id != claims['family_id'] or record.consumed_at is not None:
                self._invalid('ADMIN_SESSION_REQUIRED', '请登录管理后台', 401)

    def revoke_admin_refresh(self, cookie: str, *, expected_session_id: str | None = None) -> None:
        with self._session_factory.begin() as session:
            owner = session.scalar(select(RefreshTokenFamily.user_id).join(
                RefreshToken, RefreshToken.family_id == RefreshTokenFamily.id).where(
                RefreshToken.token_hash == hash_opaque_token(cookie)))
            if owner is None:
                return
            session.scalar(select(User).where(User.id == owner).with_for_update())
            record = session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_opaque_token(cookie)))
            admin = session.get(AdminSession, owner)
            if admin is None or record.family_id != admin.family_id:
                return
            if expected_session_id is not None and admin.family_id != expected_session_id:
                self._invalid('ADMIN_SESSION_REPLACED', '管理会话已切换，请重新加载页面', 401)
            family = session.get(RefreshTokenFamily, admin.family_id)
            if family.revoked_at is None:
                family.revoked_at = self._now_factory()
                family.revoke_reason = 'ADMIN_LOGOUT'

    def step_up_admin(self, token: str, password: str) -> dict:
        claims = self.decode_access_token(token)
        self.admin_session(token)
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == claims['sub']).with_for_update())
            admin = session.get(AdminSession, claims['sub'])
            family = session.get(RefreshTokenFamily, claims['family_id'])
            if (admin is None or admin.family_id != claims['family_id'] or
                family.revoked_at is not None or self._utc(admin.expires_at) <= self._now_factory()):
                self._invalid('ADMIN_SESSION_REQUIRED', '请登录管理后台', 401)
            if user.status.value != 'ACTIVE' or not PasswordHasher().verify(user.password_hash, password):
                self._invalid('CREDENTIALS_INVALID', '账号或密码错误', 401)
            admin.authenticated_at = self._now_factory()
        return self.admin_session(token)

    @staticmethod
    def _utc(value: datetime) -> datetime:
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value

    def _refresh_record(self, family_id: str, value: str, now: datetime) -> RefreshToken:
        return RefreshToken(
            id=str(uuid4()),
            family_id=family_id,
            token_hash=hash_opaque_token(value),
            expires_at=now + self._refresh_lifetime,
            created_at=now,
        )

    @staticmethod
    def _new_refresh_token() -> str:
        return secrets.token_urlsafe(48)

    @staticmethod
    def _invalid(code: str, message: str, status_code: int) -> None:
        raise AppError(code=code, message=message, status_code=status_code)
