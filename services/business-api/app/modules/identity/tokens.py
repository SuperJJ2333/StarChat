from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import secrets
from uuid import uuid4

import jwt
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import Device, RefreshToken, RefreshTokenFamily, User


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
        refresh_lifetime: timedelta = timedelta(days=30),
    ) -> None:
        if len(jwt_secret) < 32:
            raise ValueError("JWT secret must be at least 32 characters")
        self._session_factory = session_factory
        self._jwt_secret = jwt_secret
        self._jwt_issuer = jwt_issuer
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._access_lifetime = access_lifetime
        self._refresh_lifetime = refresh_lifetime

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
            family = RefreshTokenFamily(
                id=str(uuid4()),
                user_id=user_id,
                device_id=device.id,
                created_at=now,
            )
            session.add(family)
            refresh_value = self._new_refresh_token()
            session.add(self._refresh_record(family.id, refresh_value, now))
            return self._pair(user_id, device.id, family.id, refresh_value, now)

    def rotate(self, refresh_token: str) -> TokenPair:
        now = self._now_factory()
        session = self._session_factory()
        try:
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
            if record.consumed_at is not None:
                family.revoked_at = now
                family.revoke_reason = "TOKEN_REUSE"
                session.commit()
                self._invalid("REFRESH_TOKEN_REUSED", "检测到刷新令牌重复使用", 401)
            record_expires_at = record.expires_at
            if record_expires_at.tzinfo is None:
                record_expires_at = record_expires_at.replace(tzinfo=timezone.utc)
            if family.revoked_at is not None or record_expires_at < now:
                self._invalid("REFRESH_TOKEN_INVALID", "刷新令牌无效", 401)
            device = session.get(Device, family.device_id)
            if device is None or device.revoked_at is not None:
                self._invalid("REFRESH_TOKEN_INVALID", "刷新令牌无效", 401)
            replacement_value = self._new_refresh_token()
            replacement = self._refresh_record(family.id, replacement_value, now)
            record.consumed_at = now
            record.replaced_by_id = replacement.id
            device.last_seen_at = now
            session.add(replacement)
            session.commit()
            return self._pair(
                family.user_id, device.id, family.id, replacement_value, now
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
            return claims
        except jwt.PyJWTError as exc:
            raise AppError(code="ACCESS_TOKEN_INVALID", message="访问令牌无效", status_code=401) from exc

    def _pair(
        self, user_id: str, device_id: str, family_id: str, refresh_value: str, now: datetime
    ) -> TokenPair:
        access = jwt.encode(
            {
                "sub": user_id,
                "device_id": device_id,
                "family_id": family_id,
                "iss": self._jwt_issuer,
                "iat": now,
                "exp": now + self._access_lifetime,
                "jti": str(uuid4()),
            },
            self._jwt_secret,
            algorithm="HS256",
        )
        return TokenPair(access, refresh_value, family_id, device_id)

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
