"""Narrow financial identity policy for support orders, never owner repairs."""
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.staff_activation import require_staff_admin_access
from app.modules.identity.wallet_access import require_wallet_actor


def require_support_order_actor(session, *, claims, clock, owner_id):
    if claims.get('session_scope') != 'admin':
        raise AppError(code='PERMISSION_DENIED', message='需要客服管理会话', status_code=403)
    require_wallet_actor(session, user_id=claims['sub'], clock=clock)
    user = session.scalar(select(User).where(User.id == claims['sub']).with_for_update()
        .execution_options(populate_existing=True))
    require_staff_admin_access(session, user)
    roles = set(session.scalars(select(UserRole.role_code).where(UserRole.user_id == claims['sub']).with_for_update()))
    if RoleCode.FINANCE_SUPPORT not in roles and not (claims['sub'] == owner_id and RoleCode.SUPER_ADMIN in roles):
        raise AppError(code='PERMISSION_DENIED', message='需要财务客服权限', status_code=403)
