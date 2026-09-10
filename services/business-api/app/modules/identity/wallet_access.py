"""Identity-owned wallet authorization within the caller's transaction.

This supplements authenticated session and one-time MFA verification. It never
accepts client role flags or commits another domain's transaction.
"""
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, HoldType
from app.modules.identity.models import AdminSession, Device, RefreshTokenFamily, SecurityHold, User, UserRole
from app.modules.identity.rbac import Permission, ROLE_PERMISSIONS


def require_wallet_actor(session, *, user_id, clock, administrator=False):
    if not callable(clock):
        raise ValueError('trusted server clock required')
    # Scalar columns bypass a caller's possibly stale ORM identity map without
    # discarding its unflushed objects. The database row remains locked.
    status = session.scalar(select(User.status).where(User.id == user_id).with_for_update()) if user_id else None
    if status != AccountStatus.ACTIVE:
        raise AppError(code='WALLET_ACCOUNT_UNAVAILABLE', message='账户当前不可进行钱包操作', status_code=403)
    # Password reset may have committed a hold while we waited for this lock.
    now = clock()
    if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
        raise ValueError('timezone-aware server clock required')
    now = now.astimezone(timezone.utc)
    held = session.scalar(select(SecurityHold.id).where(
        SecurityHold.user_id == user_id, SecurityHold.hold_type == HoldType.WITHDRAWAL,
        SecurityHold.starts_at <= now, SecurityHold.ends_at > now).limit(1))
    if held is not None:
        raise AppError(code='WALLET_RECOVERY_HOLD', message='账户恢复保护期内暂不可操作', status_code=403)
    if administrator:
        roles = session.scalars(select(UserRole.role_code).where(UserRole.user_id == user_id).with_for_update()).all()
        if not any(Permission.SYSTEM_ADMIN in ROLE_PERMISSIONS.get(role, ()) for role in roles):
            raise AppError(code='PERMISSION_DENIED', message='无权执行此操作', status_code=403)


def require_wallet_session(session, *, claims, clock, verified_at, require_recent=True, require_proof=True):
    """Recheck trusted decoded claims in the financial caller's transaction.

    Caller owns budget/control/user locks before this call. No second connection
    is opened, and device/family rows remain locked through the mutation.
    """
    device = session.execute(select(Device.user_id, Device.revoked_at).where(
        Device.id == claims['device_id']).with_for_update()).first()
    family = session.execute(select(RefreshTokenFamily.user_id, RefreshTokenFamily.device_id,
        RefreshTokenFamily.revoked_at, RefreshTokenFamily.created_at).where(
        RefreshTokenFamily.id == claims['family_id']).with_for_update()).first()
    if (device is None or device.user_id != claims['sub'] or device.revoked_at is not None
            or family is None or family.user_id != claims['sub']
            or family.device_id != claims['device_id'] or family.revoked_at is not None):
        raise AppError(code='ACCESS_TOKEN_INVALID', message='访问令牌无效', status_code=401)
    created_at = family.created_at
    admin_deadline = None
    if claims.get('session_scope') == 'admin':
        # The caller already holds the user lock, which also serializes login
        # and step-up. Read scalar columns to avoid stale ORM identity maps.
        admin = session.execute(select(AdminSession.family_id, AdminSession.authenticated_at,
            AdminSession.expires_at).where(AdminSession.user_id == claims['sub'])
            .with_for_update()).first()
        if admin is None or admin.family_id != claims['family_id']:
            raise AppError(code='ACCESS_TOKEN_INVALID', message='访问令牌无效', status_code=401)
        created_at = admin.authenticated_at
        admin_deadline = admin.expires_at
        if admin_deadline.tzinfo is None:
            admin_deadline = admin_deadline.replace(tzinfo=timezone.utc)
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    def fresh():
        # Called again after waiting for subsequent locks, without opening a
        # connection or acquiring locks in a different order.
        now = clock()
        if (not int(claims['iat']) <= now.timestamp() < int(claims['exp'])
                or admin_deadline is not None and now >= admin_deadline):
            raise AppError(code='ACCESS_TOKEN_INVALID', message='访问令牌无效', status_code=401)
        if require_recent and not timedelta(0) <= now-created_at <= timedelta(minutes=5):
            raise AppError(code='RECENT_LOGIN_REQUIRED', message='请重新登录后再执行此操作', status_code=403)
        if require_proof and (verified_at is None or not timedelta(0) <= now-verified_at <= timedelta(seconds=30)):
            raise AppError(code='TOTP_REQUIRED', message='需要重新验证动态验证码', status_code=403)
    fresh()
    return fresh
